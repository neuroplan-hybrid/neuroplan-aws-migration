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

## Parameter Group과 버전 기준

기본 DB Parameter Group은 수정할 수 없으므로, 이 모듈은 RDS 인스턴스별 사용자 지정 Parameter Group을 생성한다. 기본값은 `mariadb11.8` family이며 아래 값을 적용한다.

- `binlog_format = ROW`
- `character_set_server = utf8mb4`
- `collation_server = utf8mb4_uca1400_ai_ci`
- `time_zone = Asia/Seoul`

`parameter_group_parameters` 입력값으로 Parameter Group 값을 바꿀 수 있으나, PoC와 컷오버 전에는 On-Prem 설정과 비교해야 한다. Parameter Group은 `name_prefix`와 `create_before_destroy`를 사용하므로 engine family 변경 시 새 그룹을 먼저 생성할 수 있다.

RDS가 Source가 되는 컷오버 이후에도 복제를 유지하려면 양쪽 MariaDB의 major.minor 버전이 일치해야 한다. 모듈은 `engine_version`과 `onprem_mariadb_version`의 major.minor가 다르면 생성 Plan을 중단한다. 패치 버전 차이는 AWS RDS 제공 버전과 On-Prem 패치 버전 차이를 고려해 허용한다.

## 모듈 경계

- 이 모듈은 VPC, Subnet, VPN, Route Table, Security Group을 만들지 않는다.
- 네트워크 관련 값은 `envs/prod`가 network 모듈의 Output을 입력값으로 전달한다.
- GTID 복제 계정 생성, Dump Import, RDS 외부 복제 시작은 Terraform 범위가 아니며 별도 Ansible Playbook 또는 DB Runbook에서 수행한다.
- `master_user_secret_arn`은 Secret 위치만 출력한다. Secret 값은 Terraform 출력이나 Git에 기록하지 않는다.
