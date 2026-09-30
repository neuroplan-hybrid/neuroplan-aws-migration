# 운영 RDS · GTID · DR Ansible 전달본

이 전달본은 Terraform이 만든 **운영 RDS**를 대상으로 다음 순서를 자동화한다.

```text
초기 논리 덤프 → On-Prem → RDS GTID 동기화 → 승인된 Cutover
→ RDS Primary → On-Prem DB 2대 Replica → 수동 DR 승격
```

Terraform은 RDS, DB Subnet Group, Parameter Group, Secrets Manager를 만든다. 이 Ansible은
DB 내용·복제 역할만 다룬다. VPC, VPN, Route Table, Security Group, MaxScale 설정은 변경하지 않는다.

## 안전 원칙

- 기본 실행은 읽기 전용 preflight다.
- DB를 바꾸는 태그는 모두 `-e rds_operation_execute_mutations=true`가 필요하다.
- Cutover는 추가로 `rds_operation_application_writes_fenced=true`와
  `rds_operation_cutover_approved=true`가 필요하다.
- DR 승격은 추가로 `rds_operation_dr_writes_fenced=true`와
  `rds_operation_dr_promotion_approved=true`가 필요하다.
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

`group_vars/rds_operation.yml`에 Terraform Output의 RDS Endpoint와 Master Secret ARN을 넣는다.
DevOps VM에서 `aws secretsmanager get-secret-value`를 실행할 AWS 인증도 별도로 준비한다.

## 실행 단계

```bash
# 0. 변경 없는 연결·MariaDB 전제 조건 점검
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-operation.yml --tags preflight

# 1. RDS에 복제 계정·binlog 보존 설정, 논리 덤프 Import
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-operation.yml \
  -e rds_operation_run_mode=rds-source \
  -e rds_operation_execute_mutations=true \
  -e rds_operation_outbound_repl_password='<Vault 또는 CI Secret>'

ansible-playbook -i inventory/rds-operation.ini playbooks/rds-operation.yml \
  -e rds_operation_run_mode=seed \
  -e rds_operation_execute_mutations=true

# 2. 검증된 기존 방향: On-Prem primary → RDS GTID 동기화
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-operation.yml \
  -e rds_operation_run_mode=prepare-inbound-source \
  -e rds_operation_execute_mutations=true \
  -e rds_operation_inbound_gtid_position='1-1-0000' \
  -e rds_operation_inbound_repl_password='<Vault 또는 CI Secret>'

ansible-playbook -i inventory/rds-operation.ini playbooks/rds-operation.yml \
  -e rds_operation_run_mode=configure-rds-inbound \
  -e rds_operation_execute_mutations=true \
  -e rds_operation_inbound_gtid_position='1-1-0000' \
  -e rds_operation_inbound_repl_password='<Vault 또는 CI Secret>'

ansible-playbook -i inventory/rds-operation.ini playbooks/rds-operation.yml \
  -e rds_operation_run_mode=verify-rds-inbound

# 3. Cutover: 앱 쓰기 차단·RDS catch-up을 사람이 확인한 뒤 실행
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-cutover.yml \
  -e rds_operation_execute_mutations=true \
  -e rds_operation_application_writes_fenced=true \
  -e rds_operation_cutover_approved=true

# 4. 운영 토폴로지: RDS → db-primary, db-replica
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-operation.yml \
  -e rds_operation_run_mode=configure-onprem-replica \
  -e rds_operation_execute_mutations=true \
  -e rds_operation_outbound_repl_password='<Vault 또는 CI Secret>'

ansible-playbook -i inventory/rds-operation.ini playbooks/rds-operation.yml \
  -e rds_operation_run_mode=verify-onprem-replica

# 5. T6 DR Drill: 지정 노드만 수동 승격한다. MaxScale/Route는 이 Playbook이 바꾸지 않는다.
ansible-playbook -i inventory/rds-operation.ini playbooks/rds-dr-promote.yml \
  -e rds_operation_execute_mutations=true \
  -e rds_operation_dr_writes_fenced=true \
  -e rds_operation_dr_promotion_approved=true \
  -e rds_operation_dr_promoted_inventory_hostname=db-primary
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
코드는 이 구성을 준비하지만, 운영 전용 RDS에서 첫 1회는 반드시 `SHOW SLAVE STATUS\\G` 결과로
`Slave_IO_Running: Yes`, `Slave_SQL_Running: Yes`를 확인한 뒤 운영 완료로 선언한다.
