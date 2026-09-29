# bootstrap/remote-state

Terraform Remote State용 S3 버킷. **지정 실행자(예린)만 생성·실행**하고, `terraform destroy` 대상에서 제외한다.

| 항목 | 값 |
|---|---|
| 버킷 | `neuroplan-tfstate-<계정ID>` (ap-northeast-2) |
| 보호 | 버전 관리, SSE(AES256), 퍼블릭 액세스 전체 차단, ACL 비활성화, TLS 외 요청 거부, `prevent_destroy`, `force_destroy = false` |
| 잠금 | `use_lockfile = true` → 같은 버킷의 `<key>.tflock` (DynamoDB 미사용) |
| 접근 | State 객체(`*.tfstate`, `*.tflock`, 과거 버전) 읽기·쓰기는 `state_access_principal_arns`만 허용 (지정 실행자 + 비상 관리자). **필수 입력·2개 이상**, IAM user/role/root ARN만 |
| 과거 버전 | 30일 후 만료 (PSK가 담긴 과거 state가 무기한 남지 않게) |

> 계정 ID·IAM ARN은 공개 레포에 쓰지 않는다 → `bootstrap.auto.tfvars`(.gitignore 대상)와 `-backend-config`로 넘긴다.

## 필요한 IAM 권한 (지정 실행자)

버킷 정책은 허용 목록 **외**를 Deny만 하고, 허용 대상에게 권한을 주지는 않는다. 지정 실행자 IAM user/role에 아래 권한이 따로 있어야 한다.

| 용도 | 권한 | 대상 |
|---|---|---|
| backend 사용 | `s3:ListBucket` | `arn:aws:s3:::neuroplan-tfstate-<계정ID>` |
| state 읽기·쓰기 | `s3:GetObject`, `s3:PutObject` | `.../*.tfstate` |
| lockfile | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` | `.../*.tflock` |
| bootstrap 최초 생성(1회) | `s3:CreateBucket`, `s3:PutBucket*`(Versioning, Encryption, PublicAccessBlock, OwnershipControls, Lifecycle, Policy), `s3:GetBucket*`, `sts:GetCallerIdentity` | 버킷 |

- 관리자 권한(`AdministratorAccess`)이 있으면 추가 설정 없이 충족
- 비상 관리자는 **계정 root ARN**(`arn:aws:iam::<계정ID>:root`) 권장: ARN을 잘못 넣어도 root로 정책을 고칠 수 있음

## 절차 (지정 실행자, ap-northeast-2)

```bash
# 0) 접근 허용 ARN — 필수, 2개 이상 (없으면 plan 실패). 커밋 금지: *.auto.tfvars는 .gitignore 대상
cd bootstrap/remote-state
cat > bootstrap.auto.tfvars <<'VARS'
state_access_principal_arns = [
  "arn:aws:iam::<계정ID>:user/<지정 실행자>",
  "arn:aws:iam::<계정ID>:root",
]
VARS

# 1) 최초 1회: local state로 생성 (예외 절차)
terraform init
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
terraform output backend_config_hint

# 2) versions.tf의 `# backend "s3" {}` 주석 해제 후 local state → S3 migrate
terraform init -migrate-state \
  -backend-config="bucket=<state_bucket_name>" \
  -backend-config="key=bootstrap/remote-state/terraform.tfstate" \
  -backend-config="region=ap-northeast-2" \
  -backend-config="use_lockfile=true" \
  -backend-config="encrypt=true"

# 3) 확인 후 로컬 state·plan 삭제 (PSK는 없지만 습관적으로)
terraform state list
rm -f terraform.tfstate terraform.tfstate.backup bootstrap.tfplan
```

- 2)에서 주석 해제한 `backend "s3" {}`는 후속 PR로 올린다 (코드와 실제 state 위치를 맞춤)
- `envs/prod`도 같은 버킷, key `envs/prod/terraform.tfstate`로 partial config 사용 (별도 PR)

## 주의

- ARN을 잘못 넣으면 지정 실행자도 state에 접근하지 못한다 → 비상 관리자(root 등)를 반드시 함께 넣는다
- 정책 해제가 필요하면 비상 관리자가 버킷 정책을 수정한다
- 프로젝트 종료 시: `prevent_destroy` 제거 → 모든 객체 **버전까지** 삭제 → 버킷 삭제 (IaC 가이드 5.1)
