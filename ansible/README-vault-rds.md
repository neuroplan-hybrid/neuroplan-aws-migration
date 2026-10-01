# Vault RDS 동적 DB 계정 검증 Ansible 초안

## 범위

이 디렉터리는 **ROSA Backend → AWS RDS MariaDB** 경로에서 HashiCorp Vault Database Secrets Engine이 발급한 동적 DB 계정을 준비하고 검증하기 위한 DB 담당 Ansible 초안이다.

- 포함: RDS 관리 계정 최소 권한 생성, 발급된 계정의 접속·조회 검증, 만료·회수 검증, RDS → On-Prem 복제 전파 확인
- 제외: Vault 서버·Vault Secrets Operator 설치, Kubernetes Auth·Policy·Secret 주입, ROSA Namespace·GitOps, 네트워크·VPN·Security Group 변경
- 온프렘 DR 애플리케이션은 Vault를 사용하지 않고 기존 정적 계정을 유지한다.

Vault 설치 담당자는 아래 값을 Vault 설정에 연결한다.

| 항목 | 이 초안의 기본값 | Vault 측 연결 값 |
| --- | --- | --- |
| Database config 이름 | `rds-mariadb` | `database/config/rds-mariadb` |
| Backend 쓰기 역할 | `neuroplan-app-rw` | `database/roles/neuroplan-app-rw` |
| 읽기 전용 역할 | `neuroplan-app-ro` | `database/roles/neuroplan-app-ro` |
| TTL PoC 역할 | `neuroplan-poc-ttl-15m` | `database/roles/neuroplan-poc-ttl-15m` |
| 대상 DB | `infraready` | 생성·권한 SQL의 대상 |

Vault Database Secrets Engine role에는 아래 원칙의 SQL을 사용한다. 실제 `{{name}}`, `{{password}}` 템플릿 문법은 Vault 설치 담당자가 사용하는 설정 방식에 맞춰 넣는다.

```sql
CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}';
GRANT SELECT, INSERT, UPDATE, DELETE ON infraready.* TO '{{name}}'@'%';
```

회수 SQL은 다음과 같다.

```sql
DROP USER IF EXISTS '{{name}}'@'%';
```

## 실행 전 준비

1. 운영 RDS가 `available` 상태이고 Terraform Output의 Endpoint와 Master Secret ARN을 확보한다.
2. `inventory/vault-rds.ini.example`과 `group_vars/vault_rds.yml.example`을 확장자 `.example` 없이 복사한다. 실제 파일은 Git에 올리지 않는다.
3. Vault 관리 계정 비밀번호와 Vault가 발급한 동적 계정 비밀번호는 Ansible Vault 또는 CI Secret으로만 제공한다.
4. Vault 설치 담당자가 Database Secrets Engine의 `rds-mariadb` config와 role을 연결한다.

## 실행 순서

### 1. 변경 없는 사전 점검

```bash
ansible-playbook -i inventory/vault-rds.ini playbooks/vault-rds-management.yml
```

### 2. Vault용 RDS 관리 계정 생성

이 단계는 RDS Master Secret으로 `vault_rds_manager`를 만들고, `infraready`의 CRUD 권한을 다른 사용자에게 부여할 수 있게 한다. 실제 실행은 승인 후에만 가능하다.

```bash
ansible-playbook -i inventory/vault-rds.ini playbooks/vault-rds-management.yml \
  -e vault_rds_run_mode=provision-manager \
  -e vault_rds_execute_mutations=true \
  -e vault_rds_provision_approved=true
```

생성된 관리 계정 비밀번호는 Vault 담당자에게 안전한 채널로만 전달한다. Git·tfvars·Ansible inventory에 기록하지 않는다.

### 3. Vault가 발급한 동적 계정 접속·조회 검증

Vault Secrets Operator 또는 Vault CLI로 발급한 username/password를 실행 시에만 전달한다. 이 플레이북은 계정을 만들거나 Vault lease를 갱신하지 않는다.

```bash
ansible-playbook -i inventory/vault-rds.ini playbooks/vault-rds-issued-credential.yml \
  -e vault_rds_dynamic_username='v-...'
```

비밀번호는 `vault_rds_dynamic_password`를 Ansible Vault 또는 CI Secret으로 제공한다.

### 4. TTL 만료·회수 확인

Vault 역할의 TTL이 지난 뒤 동일한 계정 정보로 아래를 실행한다. 접속 실패가 정상이다.

```bash
ansible-playbook -i inventory/vault-rds.ini playbooks/vault-rds-issued-credential.yml \
  -e vault_rds_run_mode=verify-revoked \
  -e vault_rds_dynamic_username='v-...'
```

### 5. RDS → On-Prem 복제 전파 확인

Cutover 후 On-Prem replica가 RDS를 정상 복제하는 상태에서, 발급된 동적 계정명이 On-Prem에도 보이는지 읽기 전용으로 확인한다.

```bash
ansible-playbook -i inventory/vault-rds.ini playbooks/vault-rds-replication.yml \
  -e vault_rds_dynamic_username='v-...'
```

## 보안·운영 원칙

- `vault_rds_manager`는 Vault만 사용하는 RDS 관리 계정이다. 애플리케이션 계정으로 사용하지 않는다.
- Backend 동적 계정에는 `infraready.*` CRUD만 부여한다. 이 Ansible은 운영 데이터를 바꾸지 않기 위해 접속·`SELECT 1`까지만 검증한다. DDL·사용자 관리·전역 권한은 부여하지 않는다.
- 실제 TTL 회수는 Vault가 수행한다. 이 Ansible은 발급 전제·접속·회수 결과·복제 전파만 검증한다.
- RDS Master Secret은 AWS Secrets Manager에 계속 유지한다.

