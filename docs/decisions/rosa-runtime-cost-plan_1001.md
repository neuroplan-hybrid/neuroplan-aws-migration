# ROSA 가동 기간 및 비용 최적화 결정 (2026-10-01)

## 1. 목적

ROSA HCP 본 구축 전 현재 AWS 리소스 상태를 확인하고, 연휴 기간 불필요한 재구성 없이 비용을 최소화하며, ROSA 유료 가동 기간을 기존 최대 12일보다 짧게 운영하기 위한 기준을 정리한다.

---

## 2. 10/1 현재 AWS 리소스 상태

리전: `ap-northeast-2`

`poc-cleanup.tfvars` 기준으로 아래 리소스는 현재 생성되어 있지 않다.

- RDS: 없음
- NAT Gateway: 없음
- Elastic IP: 없음

설정 기준:

- `enable_rds = false`
- `enable_nat = false`

PoC RDS는 9/30에 삭제 완료했다.

확인 명령:

```bash
# 실행 위치: Infra VM 또는 DevOps VM (AWS CLI)
# 리전: ap-northeast-2

aws rds describe-db-instances \
  --region ap-northeast-2 \
  --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]' \
  --output text

aws ec2 describe-nat-gateways \
  --region ap-northeast-2 \
  --filter Name=state,Values=available,pending \
  --query 'NatGateways[].NatGatewayId' \
  --output text

aws ec2 describe-addresses \
  --region ap-northeast-2 \
  --query 'Addresses[].[PublicIp,AllocationId,AssociationId]' \
  --output text
```

10/1 확인 시 세 명령 모두 결과 없음.

---

## 3. 10/2~10/5 연휴 리소스 운영 결정

연휴 중에는 현재 남아 있는 리소스를 유지한다.

| 리소스 | 결정 | 사유 |
|---|---|---|
| S2S VPN | 유지 | 재생성 시 Outside IP / PSK 변경 가능. 10/6 libreswan 재설정 및 터널 재연결 작업 방지 |
| DR NLB | 유지 | 재생성 시 DNS 이름 변경. 관련 PR 및 Terraform apply 재작업 방지 |
| DR NLB Public IPv4 3개 | 유지 | NLB 유지에 따라 함께 유지 |
| ECR | 유지 | 저장 비용 소액 |
| Route 53 | 유지 | DNS 구성 보존 |
| S3 Terraform State | 유지 | Remote state 보존 |
| RDS | 없음 | `poc-cleanup` 단계에서 비활성화 |
| NAT Gateway | 없음 | `poc-cleanup` 단계에서 비활성화 |
| EIP | 없음 | 현재 할당 없음 |

### 예상 연휴 비용

4일 기준 약 **$8.5** 수준으로 예상한다.

- S2S VPN: 약 `$5`
- DR NLB + Public IPv4 3개: 약 `$3.6`
- ECR / Route 53 / S3 state: 소액

비용보다 VPN/NLB 재생성에 따른 설정 변경 및 재검증 비용이 더 크므로 유지하는 것으로 결정한다.

### 연휴 중 예상 상태

Infra VM이 OFF이므로 다음 상태는 정상이다.

- VPN Tunnel: `DOWN`
- DR NLB Target: `unhealthy`

이는 AWS 리소스 자체 장애가 아니라 온프렘 경로가 내려가 있기 때문에 발생하는 예상 상태이다.

---

## 4. 10/6 ROSA 시작 전 복구 순서

```text
Infra VM ON
  -> libreswan 확인
  -> S2S VPN Tunnel UP 확인
  -> DR NLB Target healthy 확인
  -> AWS 리소스 상태 확인
  -> rosa-on terraform plan
  -> 검토 후 apply
```

ROSA apply 전에 기존 DR/VPN 경로가 정상 복구된 것을 먼저 확인한다.

---

## 5. ROSA 유료 가동 기간 재검토

기존 계획은 ROSA를 최대 12일 운영하는 Window로 잡았지만, 12일 전체가 실제 구축 기간은 아니다.

기존 단계:

- Day 1~3: ROSA / Operator / RDS / AWS 구성 구축
- Day 4~6: 하이브리드 운영 및 트래픽 전환
- Day 7~8: DB Cutover
- Day 8~10: 장애 검증 / 리허설 / 최종 녹화
- Day 11~12: 예비일 / 재촬영 / 백업 / destroy 준비

현재 W1에서 VPN PoC, DR NLB PoC, Terraform, ECR, OpenShift manifest 준비 등을 ROSA OFF 상태에서 선행하고 있으므로 ROSA ON 이후 기간을 압축할 수 있다.

### 결정

- **목표: 6일**
- **권장 최대: 7일**
- 5일: 가능하지만 매우 공격적
- 8일 이상: 장애 수정이 필요한 경우에만 사용
- 12일: 최대 유료 Window이며 기본 운영 목표로 사용하지 않음

---

## 6. 압축 일정안

| Day | 주요 작업 | 완료 기준 |
|---|---|---|
| Day 1 | ROSA HCP Terraform apply, Operator, RDS/AWS 구성 확인 | Cluster Ready, 필수 Operator 정상 |
| Day 2 | NeuroPlan 배포, GitOps, ECR, CI/CD, ROSA -> On-Prem DB 연결 | 앱 정상, CI/CD 전 구간 검증 |
| Day 3 | On-Prem -> RDS GTID 복제, Route 53 10% -> 50%, Monitoring | Replication 정상, 가중치 전환 성공 |
| Day 4 | RDS Cutover, ROSA DB Endpoint 변경, Route 53 Failover 전환 | RDS Writer 전환 및 서비스 정상 |
| Day 5 | Worker / 배포 / RDS / VPN / ROSA->DR 장애 테스트 | 핵심 장애 시나리오 증적 확보 |
| Day 6 | 전체 장애 리허설, RTO/RPO 측정, 문제 수정 | 최종 시연 가능한 상태 |
| Day 7 | 최종 녹화 및 증적, 필요 시 보완 후 destroy | 보고서 증적 확보 및 유료 리소스 종료 |

### 일정 판단

- **5일**: 모든 Terraform/Manifest/DB Cutover가 한 번에 성공해야 하므로 일정 계획 기준으로는 사용하지 않는다.
- **6일**: 정상 진행 시 실현 가능한 목표.
- **7일**: 문제 해결 1일 여유를 포함한 가장 현실적인 상한.

---

## 7. 비용 운영 기준

현재 예산은 `$500` 상한을 기준으로 관리한다.

ROSA ON 이후 전체 유료 리소스의 운영비는 초기 계획상 대략 **하루 $45~50 수준**을 운영 예산 기준으로 사용한다. 실제 비용은 EC2, ROSA 서비스 요금, EBS, RDS Multi-AZ, NLB, NAT, VPN, Public IPv4, 데이터 처리량 등에 따라 변동될 수 있다.

| ROSA ON 기간 | 운영비 추정 |
|---|---:|
| 5일 | 약 `$225~250` |
| 6일 | 약 `$270~300` |
| 7일 | 약 `$315~350` |
| 10일 | 약 `$450~500` |
| 12일 | 약 `$540~600` |

따라서 `$500` 예산을 안정적으로 지키려면 **6~7일 내 핵심 구축/검증/녹화를 완료하고 가능한 즉시 destroy**하는 방향이 적합하다.

> 위 금액은 프로젝트 운영 판단용 추정치이며 실제 과금액은 Cost Explorer로 확인한다.

### 비용 확인 시점

- ROSA 생성 다음 날: 하루치 Cost Explorer 확인
- Cutover 전: 누적 비용 확인
- 최종 녹화 완료 직후: destroy 여부 결정
- destroy 후: 최종 비용 및 잔존 리소스 확인

---

## 8. 최종 운영 원칙

1. 연휴에는 VPN / DR NLB를 유지하고 재구성 리스크를 만들지 않는다.
2. 10/6 ROSA apply 전에 Infra -> VPN -> NLB 경로를 먼저 정상화한다.
3. ROSA 가동 기간은 **목표 6일, 최대 7일**로 운영한다.
4. Day 6에 핵심 검증이 완료되면 Day 7은 증적/녹화 후 즉시 destroy한다.
5. 일정 지연 시에도 비용은 Cost Explorer 실측 기준으로 관리하며 불필요한 ROSA 상시 가동을 피한다.
6. 최종 발표 및 보고서에는 기존 `12일 계획`이 아니라 **12일은 최대 Window, 실제 운영은 비용 최적화를 위해 조기 종료**한 것으로 기록한다.
