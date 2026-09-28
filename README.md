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
| enable_route53_routing | false | false | false | true |

리소스 ON/OFF는 `main.tf` 수정이 아니라 **tfvars 전환**으로 한다.

## Git 규칙

- 브랜치: `feature/<module>-xxx`, **`main` 직접 Push 금지** → PR
- PR 전: `terraform fmt -recursive`, `terraform validate`
- 남의 Module은 직접 고치지 않고 요청 또는 PR
- **올림**: `*.tf`, 단계별 tfvars, `.terraform.lock.hcl`(실행 Root마다), Ansible Role, README
- **안 올림**: `*.tfstate*`, `.terraform/`, `*.auto.tfvars`, `secrets*.tfvars`, `*.tfplan`, `*.pem`, 토큰·키·PSK·비밀번호

## Apply

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
