# neuroplan-aws-migration

NeuroPlan 2차: 온프렘 Kubernetes → AWS/ROSA 단계적 하이브리드 마이그레이션 (Terraform, Ansible)

- 최종 형태: **ROSA Primary + On-Prem Warm Standby DR**
- 자동화 경계: **AWS = Terraform / 온프렘 = Ansible / OpenShift 내부 = GitOps**
- 리전: `ap-northeast-2`

## 구조

```
.
├── bootstrap/
│   ├── remote-state/   # S3 State Bucket (지정 실행자, destroy 제외)
│   └── dns/            # Route 53 Hosted Zone (지정 실행자, destroy 제외)
├── modules/
│   ├── network/        # 희재: VPC, 3AZ Subnet, NAT, RT, SG
│   ├── hybrid/         # 희재: S2S VPN, CGW/VGW
│   ├── edge/           # 희재: DR NLB, Route 53 Routing/HC
│   ├── rosa/           # 예린: ROSA HCP, IAM/STS, Machine Pool
│   └── data/           # 정현: RDS, Secrets Manager, 백업
├── envs/prod/          # 공통 조립 + 단계별 tfvars (PR 리뷰 필수)
└── ansible/            # 희재 작성 / 예린 리뷰 (온프렘)
```

## 단계별 tfvars (`envs/prod/`)

| 변수 | poc | poc-cleanup | rosa-on | operation |
|---|---|---|---|---|
| enable_rosa | false | false | true | true |
| enable_vpn | true | true | true | true |
| enable_rds | true | false | true | true |
| rds_mode | poc | — | operation | operation |
| enable_nat | false | false | true | true |
| enable_dr_nlb | true | true | true | true |
| route53_routing_mode | off | off | off | off |

- `route53_routing_mode` (off / weighted / failover): Route 53 헬스체크·`app` 레코드 스위치. primary-health·dr-health 호스트(`/health/ready`), 인증서, 라우팅 정책이 준비될 때까지 모든 단계 `off` (PR #28 리뷰). 켤 때는 도메인·Hosted Zone·ROSA LB 입력과 함께 별도 tfvars PR

리소스 ON/OFF는 `main.tf` 수정이 아니라 **tfvars 전환**으로 한다.

## Git 규칙

- 브랜치: `feature/<module>-xxx`, **`main` 직접 Push 금지** → PR
- PR 전: `terraform fmt -recursive`, `terraform validate`
- 남의 Module은 직접 고치지 않고 요청 또는 PR
- **올림**: `*.tf`, 단계별 tfvars, `.terraform.lock.hcl`(실행 Root마다, 아래 참고), Ansible Role, README
- **안 올림**: `*.tfstate*`, `.terraform/`, `*.auto.tfvars`, `secrets*.tfvars`, `*.tfplan`, `*.pem`, 토큰·키·PSK·비밀번호

## Lock 파일 (`.terraform.lock.hcl`)

- 대상 Root: `bootstrap/remote-state`, `bootstrap/dns`, `envs/prod`
- 현재는 provider 버전 미확정 scaffold 단계라 **아직 커밋하지 않음**
- provider 버전을 `versions.tf`에 고정한 뒤, 해당 Root 첫 구현 PR에서 생성해 함께 커밋
- 팀원 OS가 달라도 해시가 맞도록 여러 플랫폼으로 생성

```bash
# 로컬, 각 Root 디렉터리에서
terraform init -backend=false
terraform providers lock -platform=windows_amd64 -platform=linux_amd64 -platform=darwin_arm64
```

## Apply

> ⚠️ 현재는 **초기 구조(scaffold) 단계**라 `envs/prod/main.tf`에 Module 호출이 없습니다.
> 아래 절차는 **각 Module 구현 및 `envs/prod` 공통 조립 완료 후** 실행합니다.

```
PR → 리뷰 → Merge → envs/prod plan → 팀 승인 → 지정 1명 apply
```

```bash
# 지정 실행자 로컬 PC, ap-northeast-2
cd envs/prod
terraform plan -var-file=poc.tfvars -out=poc.tfplan
terraform apply poc.tfplan
```

- `-auto-approve` 금지
- Apply 순서: Network/Hybrid/Data/ROSA → ROSA Ingress LB 확인 → Edge
- Destroy 순서: Edge → ROSA → 잔여 ROSA 리소스 확인 → Data/Hybrid/Network → 잔존 ENI/SG/LB 확인 (bootstrap 제외)
