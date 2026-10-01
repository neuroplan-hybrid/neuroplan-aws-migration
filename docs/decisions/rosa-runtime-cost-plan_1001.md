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

Infra VM이 OFF이면 다음 상태는 정상이다.

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

또한 실제 학원 작업 가능일은 다음과 같이 끊겨 있다.

- **10/6~10/8: 학원 작업 가능**
- **10/9~10/11: 학원 방문 불가 — 적극적인 구축/변경 작업일에서 제외**
- **10/12 이후: 학원 작업 재개**

따라서 ROSA 운영 기간은 단순한 연속 `Day 1~7`이 아니라 **실제 작업일(Active Workday)** 과 **과금되는 달력일(Calendar Billing Day)** 을 구분해서 관리한다.

### 운영 기준

- 목표: **실작업 6일**
- 권장 최대: **실작업 7일**
- 10/9~10/11은 실작업일에서 제외
- ROSA를 10/6에 생성한 뒤 유지한다면 10/9~10/11에도 과금은 계속됨
- ROSA를 중간에 destroy/recreate 하는 방식은 클러스터/Operator/GitOps/Ingress 재구성 리스크가 있으므로 기본안으로 사용하지 않음
- 실제 Cost Explorer 비용과 진행 상황을 보고 10/12 이후 조기 destroy 여부 판단

---

## 6. 현실적인 압축 일정안

### A안 — 10/6에 ROSA 시작 후 10/9~10/11 유지

| 날짜 | 실작업 Day | 주요 작업 | 완료 기준 |
|---|---:|---|---|
| **10/6** | Day 1 | Infra/VPN/NLB 복구 확인, ROSA HCP Terraform apply, 필수 Operator 설치 | Cluster Ready, 기본 Operator 정상 |
| **10/7** | Day 2 | NeuroPlan 배포, GitOps, ECR, CI/CD, ROSA -> On-Prem DB 연결 | 앱 정상, CI/CD 전 구간 검증 |
| **10/8** | Day 3 | On-Prem -> RDS GTID 복제, Route 53 가중치 테스트, Monitoring | Replication 정상, 10%/50% 전환 검증 |
| **10/9~10/11** | 제외 | 학원 방문 불가. 적극적인 변경 작업 없음 | 필요 시 상태 확인만 수행 |
| **10/12** | Day 4 | RDS Cutover, ROSA DB Endpoint 변경, Route 53 Failover 전환 | RDS Writer 전환 및 서비스 정상 |
| **10/13** | Day 5 | Worker / 배포 / RDS / VPN / ROSA->DR 장애 테스트 | 핵심 장애 시나리오 증적 확보 |
| **10/14** | Day 6 | 전체 장애 리허설, RTO/RPO 측정, 최종 녹화·증적 | 완료 시 당일 destroy 가능 |
| **10/15** | Day 7 (예비) | 문제 수정 / 재촬영 / 누락 증적 보완 | 필요할 때만 사용 후 destroy |

### 일정 해석

- **가장 빠른 종료 목표:** 10/14 저녁
- **예비일까지 사용:** 10/15 저녁
- 실작업 기준으로는 6~7일이지만, 10/9~10/11 공백 때문에 실제 ROSA 과금 기간은 더 길어진다.

---

## 7. 과금일 기준 비용 재산정

초기 운영 예산 기준은 ROSA ON 이후 전체 유료 리소스 약 **하루 $45~50 수준**으로 본다.

10/6에 ROSA를 생성하고 중간에 destroy하지 않는 경우:

| 운영 구간 | 달력 과금일 | 운영비 추정 |
|---|---:|---:|
| 10/6~10/8 | 3일 | 약 `$135~150` |
| 10/6~10/12 | 7일 | 약 `$315~350` |
| **10/6~10/14** | **9일** | **약 `$405~450`** |
| **10/6~10/15** | **10일** | **약 `$450~500`** |
| 10/6~10/17 | 12일 | 약 `$540~600` |

따라서 현재 일정에서는 단순히 `실작업 6일 = 6일 과금`으로 계산하면 안 된다.

### 비용 목표

- **1순위:** 10/14까지 핵심 작업·증적 완료 후 destroy
  - 예상: 약 `$405~450`
- **2순위:** 문제가 있으면 10/15 예비일 사용 후 destroy
  - 예상: 약 `$450~500`
- 10/16 이후까지 ROSA를 유지하는 것은 `$500` 상한 초과 위험이 있으므로 예외 상황으로 취급

> 위 금액은 프로젝트 운영 판단용 추정치이며 실제 과금액은 Cost Explorer로 확인한다.

### 비용 확인 시점

- 10/7: ROSA 생성 후 첫 하루 Cost Explorer 확인
- 10/8: 연휴 전 누적 비용 및 리소스 상태 확인
- 10/12: 작업 재개 직후 누적 비용 확인
- 10/14: 완료 가능 여부 판단 및 destroy 결정
- 10/15: 예비일 사용 시 반드시 최종 destroy 판단
- destroy 후: 최종 비용 및 잔존 리소스 확인

---

## 8. 10/9~10/11 운영 원칙

학원 방문이 불가능하므로 이 3일은 **구축 일정에서 제외**한다.

다만 ROSA를 10/6에 생성하고 유지하는 경우에는 비용이 계속 발생한다.

- 적극적인 Terraform apply / DB Cutover / 장애 주입 작업은 하지 않음
- 가능하면 10/8 퇴실 전 ROSA, RDS, VPN, NLB, Route 53 상태를 정상화하고 변경을 멈춤
- Infra VM을 켜둘 수 있는 경우 VPN/NLB/복제 상태를 원격 확인
- Infra VM을 끄는 경우 VPN Tunnel DOWN / DR NLB Target unhealthy는 예상 상태로 취급
- 10/12 작업 재개 전 VPN / NLB / DB replication / ROSA 상태를 다시 점검

---

## 9. 최종 운영 원칙

1. 10/2~10/5 연휴에는 VPN / DR NLB를 유지한다.
2. 10/6 ROSA apply 전에 Infra -> VPN -> NLB 경로를 먼저 정상화한다.
3. ROSA 실작업 목표는 **6일**, 예비 포함 최대 **7일**로 관리한다.
4. **10/9~10/11은 학원 방문 불가로 실작업일에서 제외**한다.
5. 10/6 시작 시 비용 기준 종료 목표는 **10/14**, 최대 **10/15**로 잡는다.
6. 10/14에 핵심 검증·녹화가 완료되면 즉시 유료 리소스를 destroy한다.
7. 10/15 예비일까지 사용하면 `$500` 상한에 근접하므로 이후 연장은 원칙적으로 하지 않는다.
8. 최종 발표 및 보고서에는 `12일`을 최대 유료 Window로 기록하고, 실제 운영은 학원 일정과 비용 최적화를 반영해 조기 종료한 것으로 정리한다.
