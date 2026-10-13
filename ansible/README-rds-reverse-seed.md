# RDS -> On-Prem 역복제 GTID 기준점 점검 및 복구

이 절차는 Writer Cutover 이후 RDS domain 0과 기존 On-Prem domain 1을 함께
취급합니다. `1236`만 보고 RDS의 현재 GTID를 복사하거나 초기 Import/Cutover를
다시 실행하지 않습니다. Ansible Vault·RDS 관리자 Secret·기존 앱 계정은 유지합니다.

## 필수 조건

- RDS Writer 전환 완료, 양쪽 Backend Fence 유지, 배포·배치·DDL·관리자 데이터 쓰기 동결.
- 대상 On-Prem DB `read_only=1`, SQL 오류 없음, 복구 시 IO `No` (Connecting/Yes는 거부).
- 기존 Source가 정확히 RDS이면 RESET/비밀번호 변경 없이 복구합니다.
- 현재 운영 토폴로지는 RDS domain 0 + 기존 On-Prem domain 1만 지원합니다.
  알 수 없는 domain, server ID 변경, domain 1 불일치, 로그 기준점 삭제는 중단합니다.
- 관리망 Inventory / AWS_PROFILE / SSH·sudo·CLI 사용은 기존과 동일합니다.

## 1. 조회 모드 (DB 설정·GTID 변경 없음)

실행 위치: DevOps VM / junghyun. 대상은 우선 db-primary만 지정합니다.

```bash
cd ~/neuroplan-aws-migration/ansible
export AWS_PROFILE=junghyun

ansible-playbook \
  -i inventory/rds-operation.ini \
  playbooks/rds-operation.yml \
  --limit 'rds_controller:db-primary' \
  -e rds_operation_run_mode=check-reverse-seed \
  -e rds_operation_dr_writes_fenced=true \
  --ask-pass \
  --ask-become-pass
```

`dr_writes_fenced=true`는 운영자가 쓰기 동결 증적을 확인했다는 명시적 확인입니다.
Ansible이 플랫폼 Fence·외부 관리자 쓰기 중지를 자동 입증하지는 않습니다.

RDS A snapshot -> On-Prem snapshot -> RDS B snapshot 순으로 비교합니다.
모든 BASE TABLE의 목록·열 메타데이터·정확한 행 수·모든 열 값의 SHA-256을
비교합니다. NULL/빈 값/BLOB/UTF-8/중복 행/행 순서를 구분하며, InnoDB의 각
일관된 읽기 snapshot을 사용합니다. RDS A와 B의 데이터가 달라져도 거부합니다.
애플리케이션 데이터는 출력/파일로 남기지 않으며 비밀번호는 CLI argv에 넣지 않습니다.
공개 CA와 검사 코드는 임시 작업 폴더에서 실행 후 정리됩니다. PyMySQL 불필요.

두 서버 snapshot은 분산 원자적 snapshot이 아닙니다. 행 수만 같은 것은 통과
조건이 아니며, 조회 성공만으로 쓰기 재개를 승인하지 않습니다. 이 검사는
뷰/루틴/트리거/인덱스 정의 전체를 비교하는 DDL 감사나 백업이 아닙니다.
프로젝트 규모의 데이터용 메모리 내 해시 검사이며 대용량에 그대로 적용하지 않습니다.

## 2. 명시 승인한 기준점 복구 (첫 Source 구성에도 필요)

조회 PASS 후 DB/플랫폼 GO를 받고 실행합니다. 대상 IO가 No인지 다시 확인합니다.
SQL thread도 **복구 실행 내에서** 중지한 뒤 전체 테이블 비교를 다시 수행합니다.
이전 조회의 값/수동 GTID/오래된 marker는 사용하지 않습니다.

```bash
ansible-playbook \
  -i inventory/rds-operation.ini \
  playbooks/rds-operation.yml \
  --limit 'rds_controller:db-primary' \
  -e rds_operation_run_mode=configure-onprem-replica \
  -e rds_operation_execute_mutations=true \
  -e rds_operation_dr_writes_fenced=true \
  -e rds_operation_reverse_seed_recovery_approved=true \
  -e rds_operation_replication_use_ssl=true \
  -e @group_vars/rds_operation.vault.yml \
  --ask-vault-pass \
  --ask-pass \
  --ask-become-pass
```

- RDS A의 전체 GTID를 후보로 잡되 domain 1은 On-Prem 현재 GTID와 정확히 같아야 합니다.
- RDS A/B의 애플리케이션 데이터 동일, domain 1 고정, 기존 domain 역행/삭제 없음,
  최신 retained binlog 시작점에서 후보가 여전히 유효한지 검증합니다.
- 비교 실패 시 GTID/필터를 바꾸지 않고 중단합니다 (승인 복구에서 중지한 thread는
  자동 재시작하지 않음). 원본 데이터로 덮어쓰거나 skip counter로 건너뛰지 않습니다.
- 전체 데이터가 일치한 기준점만 `gtid_slave_pos`에 적용합니다. domain 1을 임의로
  올리지 않습니다. RDS domain 0의 과거 이력은 해당 시점까지 동등한 **앱 데이터**가
  있음을 확인하여 bootstrap하며, RDS 시스템 DB의 동등성은 주장하지 않습니다.
- `replicate_do_db=infraready`, `replicate_wild_do_table=infraready.%`를 런타임 및
  `/etc/my.cnf.d/neuroplan-rds-replication.cnf`에 설정합니다. MariaDB 재시작 없음.
  기존 상충 필터는 덮어쓰지 않고 거부합니다. 별도 기존 옵션 파일의 중복 필터는
  운영자가 점검해야 하며 재기동 후에도 SHOW SLAVE STATUS로 재확인해야 합니다.
- RDS 내부 heartbeat 및 시스템 DB는 DR 데이터 대상이 아닙니다. RDS 사용자/권한을
  그대로 온프렘으로 복제하는 기능은 제공하지 않습니다. 기존 온프렘 앱 계정은 유지하며
  DR 앱 계정·로그인·쓰기 검증은 별도 필수입니다. 서버 범위 DDL은 필터만으로 완전히
  격리됐다고 주장하지 않으며 작업 중 관리자 DDL도 동결합니다.
- Source가 바뀌는 db-replica는 기존 다른 Source 보호 Guard에서 별도로 중단합니다.
  토폴로지 확인/승인 없이 `allow_reset_replica=true`를 추가하지 않습니다.
- 정상 IO=Yes 복제에는 recovery 승인 사용 금지. 일반 재실행은 GTID를 다시 쓰지 않습니다.

## 3. 검증 (수정 없음)

```bash
ansible-playbook \
  -i inventory/rds-operation.ini \
  playbooks/rds-operation.yml \
  --limit 'rds_controller:db-primary' \
  -e rds_operation_run_mode=verify-onprem-replica \
  --ask-pass \
  --ask-become-pass
```

Source/Port, IO/SQL Yes, Lag 0, read_only=1, GTID slave_pos, TLS CA/호스트명 검증,
빈 오류 필드 및 애플리케이션 복제 필터를 함께 판정합니다. 복구 후 RDS의 승인된
테스트 쓰기가 온프렘에 반영되는 것도 별도로 검증해야 합니다. Backend Fence 해제,
GitOps #14 적용, Route 53 변경은 이 절차의 승인이 아닙니다.
