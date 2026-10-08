# 운영 RDS · GTID · DR Ansible 전달본

이 전달본은 Terraform이 만든 **운영 RDS**를 대상으로 다음 순서를 자동화한다.

```text
최신 정상 논리 덤프 선택 → RDS Import → On-Prem → RDS GTID 동기화
→ 승인된 Cutover → RDS 정적 앱 계정 준비 → ROSA Backend → RDS 전환
→ RDS Primary → On-Prem DB 2대 Replica → 수동 DR 승격
```

Terraform은 RDS, DB Subnet Group, Parameter Group, Secrets Manager를 만든다. 이 Ansible은
DB 내용·복제 역할만 다룬다. VPC, VPN, Route Table, Security Group, MaxScale 설정은 변경하지 않는다.

## 안전 원칙

- 기본 실행은 읽기 전용 preflight다.
- Import·복제 구성 등 DB를 바꾸는 일반 실행은 `-e rds_operation_execute_mutations=true`가 필요하다.
- 초기 동기화는 `db-primary`의 NFS 백업에서 최신 정상 gzip·SHA-256 검증 파일을 선택하고,
  같은 덤프 헤더의 GTID를 자동 추출한다.
- RDS에 이미 Import된 DB가 있으면 덤프를 다시 Import하지 않는다. marker의 RDS·DB·On-Prem
  Source identity가 현재 대상과 일치할 때만 복제 구성부터 재개한다.
- 최초 동기화는 dump marker GTID를 사용한다. 이미 inbound replication이 있는 RDS를 명시적으로
  reset해 재개할 때는 RDS의 현재 적용 GTID부터 다시 연결한다.
- marker는 Controller의 임시 경로에 둔다. marker가 유실된 상태에서 DB가 남아 있으면 자동 재개하지
  않고 중단하므로, 상태를 수동 검증한 뒤 조치해야 한다.
- Cutover는 앱 쓰기 차단과 기술 검증을 마친 뒤
  `-e rds_operation_cutover_approved=true` 하나로 실행한다.
- Cutover가 끝난 뒤에만 RDS 정적 앱 계정 `ir_app`을 CRUD 권한으로 준비한다.
  ROSA Backend의 DB URL·Kubernetes Secret 전환은 GitOps의 별도 변경이다.
- DR 승격 대상은 `db-primary`로 고정하며, 실제 쓰기 전환은
  `rds_operation_dr_writes_fenced=true`, `rds_operation_dr_promotion_approved=true`가 필요하다.
- 비밀번호, AWS Access Key, RDS Secret 내용은 Git에 저장하지 않는다. 복제 비밀번호는
  Ansible Vault 또는 실행 시 `-e`로만 전달한다.

## 설치와 설정

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
cp inventory/rds-operation.ini.example inventory/rds-operation.ini
cp group_vars/rds_operation.yml.example group_vars/rds_operation.yml
chmod 600 group_vars/rds_operation.yml
```

`group_vars/rds_operation.yml`에는 RDS 식별자(`rds_operation_identifier`)만 넣는다.
Playbook은 실행 시 AWS API로 현재 RDS Endpoint·Port·Master Secret ARN을 자동 조회한다.
DevOps VM에는 `rds:DescribeDBInstances`, `secretsmanager:GetSecretValue` 권한을 가진 AWS 인증이 필요하다.

On-Prem `db-primary`의 백업 스크립트는 InnoDB 일관성 덤프를 위해
`mariadb-dump --single-transaction --master-data=2`로 생성되어야 한다.
`--master-data=2`는 dump 헤더에 주석 형태의 `gtid_slave_pos`를 기록하며, Ansible은
그 값을 실행하지 않고 RDS external replication 시작 위치로만 사용한다.
초기 동기화의 GTID parser는 현재 단일 MariaDB domain 형식(`1-1-2782`)만 지원한다.

## 실행 단계

```bash
# 0. 변경 없는 RDS 입력값·MariaDB GTID 전제 조건 점검
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-operation.yml --tags preflight

# 1. RDS를 향후 On-Prem Replica의 Source로 준비
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-operation.yml \
  -e rds_operation_run_mode=rds-source \
  -e rds_operation_execute_mutations=true \
  -e rds_operation_outbound_repl_password='<Ansible Vault 또는 CI Secret>'

# 2. 최신 정상 NFS backup → RDS Import → 같은 dump GTID부터 On-Prem → RDS catch-up
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-initial-sync.yml \
  -e rds_operation_execute_mutations=true \
  -e rds_operation_inbound_repl_password='<Ansible Vault 또는 CI Secret>'

# 기존 RDS inbound replica를 명시적으로 재설정해 initial-sync를 재개할 때만 추가
# -e rds_operation_allow_reset_replica=true

# 3. Cutover: 앱 쓰기 차단·RDS catch-up을 확인한 뒤 단일 승인 플래그로 실행
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-cutover.yml \
  -e rds_operation_cutover_approved=true

# 4. Cutover 뒤 ROSA Backend 전환 전에 RDS 정적 앱 계정(ir_app)을 준비·검증
# Endpoint·Master Secret ARN은 AWS API로 자동 조회한다.
# 비밀번호는 Git에 저장하지 않고 실행 시 전달한다.
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-app-account.yml \
  -e rds_operation_execute_mutations=true \
  -e rds_operation_app_password='<Ansible Vault 또는 CI Secret>'

ansible-playbook -i inventory/rds-operation.ini playbooks/rds-app-account.yml \
  -e rds_operation_run_mode=verify-rds-app-account \
  -e rds_operation_app_password='<Ansible Vault 또는 CI Secret>'

# 검증이 끝나면 GitOps에서 ROSA Backend의 DB_URL과 DB_USERNAME/DB_PASSWORD Secret을
# RDS Endpoint와 ir_app 계정으로 바꾼 뒤 rollout 및 로그인·조회·쓰기를 확인한다.

정적 앱 계정 Playbook은 각 `rds_operation_app_hosts`에 대해 기존 직접 권한과
`GRANT OPTION`을 먼저 제거한 뒤 `infraready.*`의
`SELECT, INSERT, UPDATE, DELETE`만 다시 부여한다.
따라서 재실행해도 `ir_app`의 권한 범위가 CRUD-only로 수렴한다.

`verify-rds-app-account` 모드는 Master 계정으로 `SHOW GRANTS`를 확인해
`USAGE ON *.*`와 위 CRUD 권한 외의 추가 권한이 있으면 실패한다.
그 뒤 `ir_app`으로 실제 인증·읽기 접속을 확인한다. 실제 애플리케이션 쓰기 동작은
ROSA Backend rollout 후 로그인·조회·저장 smoke test에서 확인한다.

# 5. 운영 토폴로지: RDS → db-primary, db-replica
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-operation.yml \
  -e rds_operation_run_mode=configure-onprem-replica \
  -e rds_operation_execute_mutations=true \
  -e rds_operation_outbound_repl_password='<Ansible Vault 또는 CI Secret>'

ansible-playbook -i inventory/rds-operation.ini playbooks/rds-operation.yml \
  -e rds_operation_run_mode=verify-onprem-replica

# 6. T6 DR Drill: db-primary만 수동 승격한다. MaxScale/Route는 이 Playbook이 바꾸지 않는다.
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-dr-promote.yml \
  -e rds_operation_execute_mutations=true \
  -e rds_operation_dr_writes_fenced=true \
  -e rds_operation_dr_promotion_approved=true
```

## 반드시 사람이 확인할 것

1. Network 담당자가 운영 RDS Security Group Inbound에 `192.168.44.51/32`,
   `192.168.44.52/32`의 3306 접근을 허용했는지
2. RDS 자동 백업과 `binlog_format=ROW`가 켜졌는지
3. Cutover 직전 RDS의 inbound replication lag가 0인지
4. DR 승격 전에 정상 ROSA/RDS 쓰기가 완전히 차단됐는지
5. DR 승격 후 DR App → MaxScale → 승격 DB로 실제 쓰기하는지

`RDS → On-Prem`은 표준 MariaDB external replica 구성이다. 기존 Primary였던 `db-primary`를
Replica로 바꾸는 단계에는 MariaDB 11.8의 `MASTER_DEMOTE_TO_SLAVE=1`을 함께 사용해 기존 Primary의
GTID 위치를 안전하게 Replica 위치로 넘긴다.
코드는 이 구성을 준비하지만, 운영 전용 RDS에서 첫 1회는 반드시 `SHOW SLAVE STATUS\G` 결과로
`Slave_IO_Running: Yes`, `Slave_SQL_Running: Yes`를 확인한 뒤 운영 완료로 선언한다.
