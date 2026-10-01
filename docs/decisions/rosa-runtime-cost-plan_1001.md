# ROSA 가동 기간 및 비용 최적화 결정 (2026-10-01)

## 1. 목적

ROSA HCP 본 구축 전 현재 AWS 리소스 상태를 확인하고, 연휴 및 학원 일정에 맞춰 불필요한 ROSA 유료 가동 시간을 줄이기 위한 운영 기준을 정리한다.

이번 결정의 핵심은 **강사 제공 OCP 환경을 ROSA 대체 환경으로 사용하지 않고, ROSA에 올릴 동일한 OpenShift 배포물을 사전 검증하는 Pre-flight 환경으로 활용**하는 것이다.

목표는 다음과 같다.

- OCP에서 애플리케이션/OpenShift 계층의 오류를 먼저 제거
- AWS/ROSA 종속 기능은 ROSA에서만 검증
- OCP용 구현과 ROSA용 구현을 따로 만들어 이중 작업하지 않음
- 10/9~10/11 학원 방문 불가 기간에는 ROSA를 아직 생성하지 않음
- ROSA 유료 운영 기간을 10/12 이후로 집중해 `$500` 예산을 안정적으로 관리

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
| S2S VPN | 유지 | 재생성 시 Outside IP / PSK 변경 가능. libreswan 재설정 및 터널 재연결 작업 방지 |
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

## 4. 비용 최적화 전략: OCP Pre-flight 후 ROSA 생성

### 결론

**강사 제공 OCP는 본 구축 환경이 아니라 ROSA 사전 검증 환경으로만 사용한다.**

기존처럼 10/6에 ROSA를 생성해 10/9~10/11까지 유휴 상태로 과금시키지 않고, 10/6~10/8에는 OCP에서 ROSA에 배포할 동일한 애플리케이션/매니페스트를 검증한다.

ROSA는 학원 작업이 재개되는 **10/12에 최초 생성**하는 것을 기본안으로 한다.

### 이 방식을 선택하는 이유

1. 10/9~10/11은 학원 방문이 불가능해 ROSA에서 적극적인 구축/장애 검증을 할 수 없다.
2. ROSA를 10/6에 생성하면 작업하지 못하는 3일도 계속 과금된다.
3. OpenShift 공통 영역의 문제를 OCP에서 먼저 제거하면 ROSA 생성 후 디버깅 시간을 줄일 수 있다.
4. 단, OCP 전용 구성을 따로 만들면 오히려 일정이 늘어나므로 **동일한 base manifest를 재사용**한다.

---

## 5. OCP에서 검증할 범위 / ROSA에서만 검증할 범위

### OCP에서 먼저 검증

| 영역 | OCP 검증 내용 | ROSA에서의 처리 |
|---|---|---|
| Deployment | Frontend/Backend Pod 기동, replica, resource 설정 | 동일 manifest 재사용 |
| Service | Service selector/port 연결 | 동일 manifest 재사용 |
| Route | OpenShift Route 동작, TLS/host 구조 확인 | ROSA 실제 host로 overlay 변경 |
| Probe | readiness/liveness 정상 동작 | 동일 설정 최종 확인 |
| SCC / SecurityContext | OpenShift 권한 및 rootless 실행 가능 여부 | 동일 설정 최종 확인 |
| ConfigMap/Secret 구조 | key 이름, mount/env 구조 검증 | 실제 값만 ROSA Secret으로 주입 |
| OpenShift GitOps | Argo CD Application/Sync 구조 | ROSA GitOps에 동일 구조 적용 |
| 배포 업데이트 | image tag 변경 후 rollout 확인 | ECR image로 최종 확인 |
| 장애 사전 연습 | Pod 삭제, readiness 실패 배포 | ROSA에서 공식 증적 재측정 |

### ROSA/AWS에서만 검증

다음 항목은 OCP 결과로 대체하지 않는다.

- ROSA HCP 생성 및 MachinePool
- AWS IAM / STS / ROSA OIDC
- ECR 실제 Pull 인증
- RDS MariaDB Multi-AZ
- On-Prem ↔ RDS GTID 복제 및 Cutover
- Site-to-Site VPN 실제 경로
- ROSA Ingress/NLB
- Route 53 Weighted / Failover
- ROSA ↔ On-Prem MaxScale 연결
- RDS Failover / PITR
- ROSA 전체 진입 장애 → On-Prem DR 전환
- 실제 RTO/RPO 측정

즉, **OCP 성공 = ROSA 완료가 아니라 OpenShift 공통 계층의 사전 검증 완료**로만 본다.

---

## 6. 이중 작업 방지 원칙

가장 큰 리스크는 OCP에 맞춰 별도 구현한 뒤 다시 ROSA에 맞추는 것이다. 이를 방지하기 위해 아래 원칙을 적용한다.

### 6.1 동일한 Kubernetes/OpenShift base 사용

애플리케이션 저장소에서는 가능하면 다음 구조를 사용한다.

```text
k8s/
├── base/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── route.yaml
│   └── kustomization.yaml
└── overlays/
    ├── ocp-preflight/
    │   └── kustomization.yaml
    └── rosa/
        └── kustomization.yaml
```

`base`에는 공통 리소스를 두고 환경별 차이만 overlay에서 관리한다.

### 6.2 환경별 차이로 허용하는 항목

OCP와 ROSA 사이에서 달라도 되는 것은 최소화한다.

- Route hostname
- image registry/repository
- Secret 실제 값
- StorageClass가 필요한 경우 해당 이름
- 외부 DB endpoint
- 환경별 annotation/label

Deployment 구조, Service port, Probe, resource request/limit, replica 정책 등은 가능한 한 동일하게 유지한다.

### 6.3 금지 사항

- OCP 전용 Deployment를 새로 복제해서 관리하지 않음
- OCP에서만 동작하는 임시 YAML을 본 구축 기준으로 사용하지 않음
- OCP에서 AWS 네트워크/RDS/Route 53을 흉내 내기 위해 별도 복잡한 구조를 만들지 않음
- OCP 테스트 자체가 하루 이상 지연되면 기능 범위를 줄이고 ROSA 준비를 우선함

---

## 7. 10/6~10/8 OCP Pre-flight 구체 일정

### 10/6 — OpenShift 기본 호환성 제거

목표: ROSA에서 처음 만날 수 있는 애플리케이션/OpenShift 오류를 미리 제거한다.

작업:

- Namespace 생성
- Frontend/Backend Deployment 적용
- Service 연결 확인
- Route 생성 및 외부 접근 확인
- readiness/liveness probe 확인
- SCC / SecurityContext / rootless 실행 확인
- ConfigMap/Secret 주입 방식 확인
- Pod restart / reschedule 확인

완료 기준:

```text
Frontend Pod Ready
Backend Pod Ready
Route -> Service -> Pod 정상
/health/live = 200
/health/ready = 200
Pod 재생성 후 서비스 정상
```

### 10/7 — GitOps / CI-CD 배포 흐름 사전검증

목표: ROSA 생성 후에는 인프라 디버깅보다 AWS 연동 검증에 집중할 수 있도록 배포 계층을 확정한다.

작업:

- OpenShift GitOps/Argo CD Application 구조 검증
- Git 변경 → Sync → rollout 확인
- image tag 변경 반영 확인
- 잘못된 readiness 버전 배포 후 기존 Pod 유지/복구 흐름 확인
- ROSA overlay와 OCP overlay 차이 최소화
- 실제 ECR 인증이 필요한 부분은 ROSA TODO로 명확히 분리

완료 기준:

```text
Git commit
 -> Argo CD Sync
 -> Deployment rollout
 -> /health/ready 200
```

잘못된 배포 시 기존 정상 서비스가 유지되는 것까지 확인한다.

### 10/8 — ROSA 전환 리허설 및 Go/No-Go

목표: 10/12 ROSA 생성 시 사용할 산출물을 확정한다.

작업:

- ROSA용 Kustomize overlay 최종 검토
- Route host / Secret / ECR / DB endpoint placeholder 확인
- ROSA Terraform `plan` 재확인
- 필요한 Operator 목록 확정
- 장애 테스트 명령/스크립트 사전 연습
- 10/12 실행 순서 체크리스트 확정

#### 10/8 Go 조건

아래가 모두 만족되면 10/12 ROSA 생성으로 진행한다.

- 애플리케이션 Pod 정상
- Probe 정상
- OpenShift Route 정상
- GitOps sync 정상
- 배포 실패 복구 흐름 확인
- ROSA overlay 준비 완료
- Terraform plan에 의도하지 않은 destroy 없음
- ROSA에서만 필요한 AWS 작업 목록이 명확히 분리됨

위 조건을 만족하지 못하면 10/9~10/11 동안 코드/문서 수정 가능한 범위만 보완하고, **ROSA를 미리 켜서 문제를 해결하려 하지 않는다.**

---

## 8. 10/9~10/11 운영 원칙

학원 방문이 불가능하므로 ROSA는 아직 생성하지 않는다.

- OCP 실환경 변경 작업 없음
- AWS에서는 기존 S2S VPN / DR NLB / ECR / Route 53 / S3 state만 유지
- RDS / NAT / ROSA는 생성하지 않음
- Git, Terraform, Manifest, 런북 등 로컬에서 수정 가능한 작업만 수행 가능
- 10/12 작업 재개 시 Infra VM ON 후 VPN/NLB 상태부터 정상화

이 기간의 목적은 **ROSA 유휴 과금을 없애는 것**이다.

---

## 9. 10/12 이후 ROSA 집중 일정

### 기본안

| 날짜 | ROSA 실작업 Day | 주요 작업 | 완료 기준 |
|---|---:|---|---|
| **10/12** | Day 1 | Infra/VPN/NLB 복구 → `rosa-on` plan/apply → ROSA HCP → Operator → 앱/GitOps 배포 | Cluster Ready, App Ready, ECR Pull 정상 |
| **10/13** | Day 2 | RDS 구축/복제 확인 → ROSA→On-Prem DB → Cutover → Route 53 Failover | RDS Writer 전환, 서비스 정상 |
| **10/14** | Day 3 | Worker/배포/RDS/VPN/ROSA→DR 장애 테스트, RTO/RPO 측정 | 핵심 장애 시나리오 증적 확보 |
| **10/15** | Day 4 (예비) | 전체 리허설, 재촬영, 누락 증적 보완 | 완료 즉시 유료 리소스 destroy |

### 10/12 시작 전 체크 순서

```text
Infra VM ON
  -> libreswan 확인
  -> S2S VPN Tunnel UP 확인
  -> DR NLB Target healthy 확인
  -> AWS 잔존 리소스 확인
  -> terraform init/plan 확인
  -> rosa-on terraform apply
  -> ROSA Ready 확인
  -> Operator/GitOps/App 배포
```

---

## 10. 일정 리스크와 완화책

### 리스크 1. OCP와 ROSA 차이 때문에 다시 수정해야 할 수 있음

완화:

- OCP 검증 범위를 OpenShift 공통 계층으로 제한
- AWS 연동 기능은 OCP에서 억지로 재현하지 않음
- 공통 base + 환경별 overlay 사용

### 리스크 2. 10/12~10/15 4일이 너무 짧을 수 있음

완화:

- 10/6~10/8에 앱/GitOps/Probe/SCC 오류를 미리 제거
- 10/8에 Terraform plan과 ROSA 실행 체크리스트 확정
- 10/12에는 새로운 설계 결정을 하지 않고 준비한 순서대로 실행

### 리스크 3. OCP 사전검증 자체가 새로운 프로젝트가 될 수 있음

완화:

- OCP에서 새로운 아키텍처를 설계하지 않음
- OpenShift 호환성 검증이 끝나면 즉시 종료
- OCP 전용 기능/스토리지/네트워크 튜닝에 시간을 쓰지 않음

### 리스크 4. ROSA에서 예상 밖 AWS/IAM 문제가 발생

완화:

- ROSA Terraform plan, 권한, quota를 10/8 전에 검증
- ECR/STS/RHCS provider 관련 사전 점검 완료
- 10/15를 예비일로 남겨둠

---

## 11. 비용 비교

기존 운영 판단 기준인 ROSA ON 이후 전체 유료 리소스 비용을 약 **하루 $45~50**로 본다. 실제 금액은 Cost Explorer로 검증한다.

### 기존안: 10/6 ROSA 생성

| 운영 구간 | 달력 과금일 | ROSA ON 이후 운영비 추정 |
|---|---:|---:|
| 10/6~10/14 | 9일 | 약 `$405~450` |
| 10/6~10/15 | 10일 | 약 `$450~500` |

### 권장안: 10/12 ROSA 생성

| 운영 구간 | 달력 과금일 | ROSA ON 이후 운영비 추정 |
|---|---:|---:|
| **10/12~10/14** | **3일** | **약 `$135~150`** |
| **10/12~10/15** | **4일** | **약 `$180~200`** |

### 예상 절감 효과

- 10/14 종료 기준: 약 **$270~300 절감 가능**
- 10/15 종료 기준: 약 **$270~300 절감 가능**

이는 ROSA를 켜지 않는 10/6~10/11 구간의 비용을 줄이는 효과가 핵심이다.

> 위 금액은 `ROSA ON 이후 운영비` 추정치다. 9/29~10/1 PoC 비용, 10/2~10/5 연휴 유지비 약 `$8.5`, ECR/Route 53/S3 등 소액 비용은 프로젝트 전체 누적 비용 계산 시 별도로 더한다.

### 비용 확인 시점

- 10/12: ROSA 생성 직전 현재 누적 비용 캡처
- 10/13: ROSA 1일 실측 비용 확인
- 10/14: 누적 비용 + 완료 여부 확인, 가능하면 destroy
- 10/15: 예비일 사용 시 당일 destroy
- destroy 후: 잔존 유료 리소스 및 최종 비용 확인

---

## 12. ROSA 종료 기준

날짜보다 **완료 조건**을 우선한다.

아래 증적이 확보되면 ROSA를 계속 유지하지 않는다.

- ROSA HCP 정상 구축
- NeuroPlan Frontend/Backend 정상 서비스
- Jenkins/ECR/GitOps 배포 정상
- RDS Cutover 및 쓰기 정상
- Route 53 Failover 구성 정상
- Worker 장애 복구 증적
- 잘못된 배포 차단/복구 증적
- RDS Failover 증적
- VPN 단일 터널 장애 증적
- ROSA → On-Prem DR 전환 및 RTO/RPO 측정
- 필요한 로그/스크린샷/Cost Explorer 캡처 완료

완료되면 **당일 destroy**한다.

---

## 13. 최종 운영 원칙

1. 10/2~10/5에는 기존 VPN / DR NLB만 유지한다.
2. **10/6~10/8에는 강사 제공 OCP를 Pre-flight 용도로 활용하고 ROSA는 생성하지 않는다.**
3. OCP용 별도 구현을 만들지 않고 ROSA와 동일한 OpenShift base를 사용한다.
4. OCP에서는 앱/GitOps/Route/Probe/SCC 등 OpenShift 공통 계층만 검증한다.
5. AWS/RDS/VPN/Route 53/ROSA 자체 기능은 ROSA에서 최종 검증한다.
6. **10/9~10/11에는 ROSA OFF 상태를 유지한다.**
7. **10/12 ROSA 최초 생성**을 기본안으로 한다.
8. 10/14 완료를 1순위 목표, 10/15를 예비일로 사용한다.
9. 핵심 증적 확보 즉시 유료 리소스를 destroy한다.
10. OCP 검증이 일정 지체 요인이 되면 OCP 범위를 축소하고 ROSA 준비물을 우선한다.
11. 최종 발표에서는 `비용 절감을 위해 사전 OpenShift 환경에서 애플리케이션 호환성을 검증하고, AWS 종속 검증 시점에만 ROSA HCP를 프로비저닝했다`고 정리한다.
