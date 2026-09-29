# data module

RDS for MariaDB를 생성하는 정현 담당 모듈이다. 네트워크 리소스를 생성하거나 수정하지 않고, `envs/prod`에서 전달한 DB Subnet Group과 Security Group만 사용한다.

## RDS GTID PoC 기준

| 항목 | 값 |
| --- | --- |
| 엔진 | MariaDB 11.8.8 |
| 인스턴스 | `db.t4g.micro` |
| 가용성 | Single-AZ |
| 스토리지 | gp3 20GiB |
| Public access | 비활성화 |
| 자동 백업 | 1일 |
| Master 비밀번호 | RDS가 Secrets Manager에 자동 생성 |

## 모듈 경계

- 이 모듈은 VPC, Subnet, VPN, Route Table, Security Group을 만들지 않는다.
- 네트워크 관련 값은 `envs/prod`가 network 모듈의 Output을 입력값으로 전달한다.
- GTID 복제 계정 생성, Dump Import, RDS 외부 복제 시작은 Terraform 범위가 아니며 별도 Ansible Playbook 또는 DB Runbook에서 수행한다.
- `master_user_secret_arn`은 Secret 위치만 출력한다. Secret 값은 Terraform 출력이나 Git에 기록하지 않는다.
