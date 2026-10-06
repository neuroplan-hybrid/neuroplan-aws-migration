# bootstrap/dns

기존 Route 53 Public Hosted Zone `neuroplan.cloud`을 Terraform state에 import하여 관리한다.

이 bootstrap 리소스는 운영 리소스와 분리하며, 프로젝트 운영 중 `terraform destroy` 대상에서 제외한다.

## 대상

- Domain: `neuroplan.cloud`
- Hosted Zone ID: `Z021384539IIHK7FGMEMN`
- State backend key: `bootstrap/dns/terraform.tfstate`
- Region: `ap-northeast-2`

## Import 절차

지정 실행자만 수행한다.

```bash
cd ~/neuroplan-aws-migration/bootstrap/dns

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

terraform init -reconfigure \
  -backend-config="bucket=neuroplan-tfstate-${ACCOUNT_ID}" \
  -backend-config="key=bootstrap/dns/terraform.tfstate" \
  -backend-config="region=ap-northeast-2" \
  -backend-config="use_lockfile=true" \
  -backend-config="encrypt=true"

terraform import \
  aws_route53_zone.main \
  Z021384539IIHK7FGMEMN

terraform plan
```

## 완료 기준

Import 후 아래 조건을 모두 확인한다.

- `terraform plan`: **0 add / 0 change / 0 destroy**
- `terraform state list`에 `aws_route53_zone.main` 존재
- `terraform output hosted_zone_id` 결과가 `Z021384539IIHK7FGMEMN`
- `terraform output name_servers`가 기존 Route 53 Hosted Zone NS와 일치

확인 명령:

```bash
terraform state list
terraform output hosted_zone_id
terraform output name_servers
```

## 주의

- Import 전에 Hosted Zone을 새로 생성하지 않는다.
- `terraform apply`는 Import 확인 과정에서 필요하지 않다.
- `aws_route53_zone.main`에는 `prevent_destroy = true`가 설정되어 있다.
- 기존 Hosted Zone의 comment/tag는 Import 직후 Terraform이 덮어쓰지 않도록 ignore한다.
- 계정 ID, IAM ARN, 자격 증명, 인증서 및 키는 저장소에 커밋하지 않는다.
- 최초 `terraform init` 후 생성되는 `.terraform.lock.hcl`은 다른 Root와 provider 버전을 확인한 뒤 별도 커밋한다.
