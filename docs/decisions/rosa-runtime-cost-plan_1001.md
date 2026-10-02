# ROSA 가동 기간 및 비용 최적화 결정 (2026-10-01)

## 1. 목적

ROSA HCP 본 구축 전 현재 AWS 리소스 상태를 확인하고, 연휴 및 학원 일정에 맞춰 불필요한 ROSA 유료 가동 시간을 줄이기 위한 운영 기준을 정리한다.

이번 결정의 핵심은 **강사 제공 OCP 환경을 ROSA 대체 환경으로 사용하지 않고, ROSA에 올릴 동일한 OpenShift 배포물을 사전 검증하는 Pre-flight 환경으로 활용**하는 것이다.

목표는 다음과 같다.

- OCP에서 애플리케이션/OpenShift 계층의 오류를 먼저 제거
- AWS/ROSA 종속 기능은 ROSA에서만 최종 검증
- OCP용 구현과 ROSA용 구현을 따로 만들어 이중 작업하지 않음
- 10/9~10/11 학원 방문 불가 기간에는 ROSA/RDS/NAT를 생성하지 않음
- ROSA 유료 운영 기간을 **10/12~10/16 5일**로 집중
- 10/16(금) 당일 destroy를 원칙으로 하고 주말 연장은 하지 않음
- 프로젝트 전체 예산 `$500`을 Cost Explorer 실측 기준으로 관리

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

비용보다 VPN/NLB 재생성에 따른 설정 변경 및 재검증 비용이 더 크므로 유지한다.

Infra VM이 OFF이면 아래 상태는 정상이다.

- VPN Tunnel: `DOWN`
- DR NLB Target: `unhealthy`

---

## 4. 비용 최적화 전략: OCP Pre-flight 후 ROSA 생성

### 결론

**강사 제공 OCP는 본 구축 환경이 아니라 ROSA 사전 검증 환경으로만 사용한다.**

10/6~10/8에는 OCP에서 ROSA에 배포할 동일한 애플리케이션/매니페스트를 검증하고, ROSA와 운영 RDS는 학원 작업이 재개되는 **10/12에 최초 생성**한다.

ROSA는 **10/12~10/16 5일 연속 운영**하며, 하루에 한 단계씩 `생성 → 통합 검증 → 전환 사전검증 → Cutover → DR/종료` 순서로 진행한다.

10/16(금) 당일 destroy를 원칙으로 하며, 주말 유휴 과금을 피하기 위해 10/17 이후로 연장하지 않는다.

### 선택 이유

1. 10/9~10/11은 학원 방문이 불가능해 적극적인 구축·Cutover·장애 검증을 할 수 없다.
2. ROSA를 10/6~10/8에 미리 생성하면 작업하지 못하는 3일도 계속 과금된다.
3. 10/12~10/16을 5일 연속으로 사용하면 생성·통합·전환·Cutover·DR을 하루씩 분리할 수 있다.
4. OpenShift 공통 영역의 문제를 OCP에서 먼저 제거하면 ROSA 생성 후 디버깅 시간을 줄일 수 있다.
5. OCP 전용 구성을 만들지 않고 동일한 base manifest를 사용하면 재작업을 최소화할 수 있다.

---

## 5. OCP 검증 범위 / ROSA·AWS 최종 검증 범위

### 5.1 OCP에서 먼저 검증

| 영역 | OCP 검증 내용 | ROSA에서의 처리 |
|---|---|---|
| Deployment | Frontend/Backend Pod 기동, replica, resource 설정 | 동일 manifest 재사용 |
| Service | selector/port 연결 | 동일 manifest 재사용 |
| Route | OpenShift Route 동작, TLS/host 구조 확인 | ROSA 실제 host로 overlay 변경 |
| Probe | readiness/liveness 정상 동작 | 동일 설정 최종 확인 |
| SCC / SecurityContext | OpenShift 권한 및 rootless 실행 가능 여부 | 동일 설정 최종 확인 |
| ConfigMap/Secret 구조 | key 이름, mount/env 구조 검증 | 실제 값은 ROSA에서 주입 |
| OpenShift GitOps | Argo CD Application/Sync 구조 | ROSA GitOps에 동일 구조 적용 |
| 배포 업데이트 | image tag 변경 후 rollout 확인 | ECR image로 최종 확인 |
| 장애 사전 연습 | Pod 삭제, readiness 실패 배포 | ROSA에서 공식 증적 재측정 |

### 5.2 ROSA/AWS에서만 최종 검증

다음 항목은 OCP 결과로 대체하지 않는다.

- ROSA HCP 생성 및 MachinePool
- AWS IAM / STS / ROSA OIDC
- ECR 실제 Pull 인증
- 운영 RDS MariaDB
  - **기본: Single-AZ (`rds_multi_az=false`)**
  - **T6 RDS Failover 시연이 필요한 경우에만 팀 승인 후 Multi-AZ 전환**
- On-Prem → RDS GTID 복제 및 Cutover
- Cutover 후 RDS → On-Prem `db-primary` / `db-replica` 역방향 GTID 복제
- Site-to-Site VPN 실제 경로
- ROSA Ingress/NLB
- Route 53 **Weighted 기반 active-passive**
  - 전환 검증: `10/90 → 50/50`
  - 운영: `ROSA 1 / On-Prem 0`
  - 양쪽 레코드에 Health Check 연결
  - Failover Routing Policy로 전환하지 않음
- ROSA ↔ On-Prem MaxScale 연결
- RDS PITR 및 백업 검증
- T6 승인 시 RDS Multi-AZ Failover 검증
- ROSA 전체 진입 장애 → On-Prem DR 전환
- 실제 RTO/RPO 측정

즉, **OCP 성공 = ROSA 완료가 아니라 OpenShift 공통 계층의 사전 검증 완료**로만 본다.

---

## 6. 이중 작업 방지 원칙

### 6.1 동일한 Kubernetes/OpenShift base 사용

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

- Route hostname
- image registry/repository
- Secret 실제 값
- StorageClass 이름
- 외부 DB endpoint
- 환경별 annotation/label

Deployment 구조, Service port, Probe, resource request/limit, replica 정책 등은 가능한 한 동일하게 유지한다.

### 6.3 금지 사항

- OCP 전용 Deployment를 복제해서 별도 관리하지 않음
- OCP에서만 동작하는 임시 YAML을 본 구축 기준으로 사용하지 않음
- OCP에서 AWS 네트워크/RDS/Route 53을 억지로 재현하지 않음
- OCP 테스트가 일정 지체 요인이 되면 범위를 축소하고 ROSA 준비물을 우선함

---

## 7. 10/6~10/8 OCP Pre-flight 일정

### 7.0 공용 OCP 사용 전제 확인

10/6 작업 시작 전 아래 항목을 먼저 확인한다.

- 현재 계정의 권한 범위 확인
  - `cluster-admin` 여부
  - Operator 설치 권한 여부
- OpenShift GitOps Operator를 신규 설치할 수 있는지 확인
  - 설치 권한이 없으면 기존 GitOps 사용 가능 여부 확인
  - 둘 다 불가능하면 GitOps Operator 설치 자체를 Pre-flight 완료 조건에서 제외하고 manifest/rollout 검증으로 축소
- OCP 버전 확인 및 ROSA 예정 OpenShift 버전과 차이 기록
- 이미지 공급 방식 결정
  - 기존 Harbor 사용 가능 여부
  - ECR 사용 시 인증 토큰 갱신/접근 방식 확인
- 공용 클러스터이므로 실제 AWS/DB Secret을 저장하지 않음
  - OCP에서는 dummy/test Secret만 사용
  - 실제 Secret은 ROSA에서만 주입

**중단 기준:** 권한/이미지 접근 문제 해결에 장시간을 사용하지 않는다. OCP가 ROSA 준비를 지연시키면 검증 범위를 즉시 축소한다.

### 10/6 — OpenShift 기본 호환성 검증

작업:

- Namespace 생성
- Frontend/Backend Deployment 적용
- Service 연결 확인
- Route 생성 및 외부 접근 확인
- readiness/liveness probe 확인
- SCC / SecurityContext / rootless 실행 확인
- ConfigMap/Secret 구조 확인
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

작업:

- OpenShift GitOps/Argo CD Application 구조 검증
- Git 변경 → Sync → rollout 확인
- image tag 변경 반영 확인
- readiness 실패 버전 배포 후 기존 Pod 유지/복구 흐름 확인
- ROSA overlay와 OCP overlay 차이 최소화
- ECR 인증이 필요한 부분은 ROSA TODO로 분리

완료 기준:

```text
Git commit
 -> Argo CD Sync
 -> Deployment rollout
 -> /health/ready 200
```

GitOps Operator 설치 권한이 없는 경우 해당 제약을 기록하고, Application YAML 및 Kustomize 렌더링 검증까지 수행한다.

### 10/8 — ROSA 실행 준비 및 Go/No-Go

작업:

- ROSA용 Kustomize overlay 최종 검토
- Route host / Secret / ECR / DB endpoint placeholder 확인
- ROSA Terraform `plan` 재확인
- 필요한 Operator 목록 확정
- DB Import/GTID/Cutover Runbook 확정
- Route 53 Weighted 전환 측정 절차 준비
  - `10/90`
  - `50/50`
  - 운영 `1/0`
- `primary-health` / `dr-health` endpoint, Hosted Zone, 도메인, 인증서 준비 상태 확인
- 장애 테스트 명령/스크립트 사전 검토
- 10/12 실행 순서 체크리스트 확정

#### 10/8 Go 조건

- 애플리케이션 Pod 정상
- Probe 정상
- OpenShift Route 정상
- GitOps sync 정상 또는 권한 제약이 명확히 기록됨
- 배포 실패 복구 흐름 확인
- ROSA overlay 준비 완료
- Terraform plan에 의도하지 않은 destroy 없음
- DB Import/GTID/Cutover Runbook 준비 완료
- Route 53 Weighted 전환 선행조건 준비 여부 확인
- ROSA에서만 필요한 AWS 작업 목록이 명확히 분리됨

위 조건을 만족하지 못하면 10/9~10/11 동안 가능한 문서/코드 보완만 진행하고, ROSA를 미리 생성해서 문제를 해결하지 않는다.

---

## 8. 10/9~10/11 운영 원칙

학원 방문이 불가능하므로 ROSA/RDS/NAT는 아직 생성하지 않는다.

- OCP 실환경 변경 작업 없음
- AWS에서는 기존 S2S VPN / DR NLB / ECR / Route 53 / S3 state만 유지
- RDS / NAT / ROSA는 생성하지 않음
- 10/12 작업 재개 시 Infra VM ON 후 VPN/NLB 상태부터 정상화

따라서 이 기간에는 ROSA 앱 → On-Prem DB 연결 또는 On-Prem → 운영 RDS 복제가 존재하지 않으며, 해당 연결의 3일 중단 문제도 발생하지 않는다.

---

## 9. 10/12~10/16 ROSA 5일 집중 일정

### 9.1 확정 일정

| 날짜 | 실작업 Day | 주요 작업 | 완료 기준 |
|---|---:|---|---|
| **10/12 (월)** | Day 1 생성 | Infra/VPN/NLB 점검 → `rosa-on` plan/apply → ROSA HCP + Worker + 운영 RDS + NAT 생성 → IAM/STS/OIDC 확인 → Operator/GitOps/첫 배포 → NFS 논리백업 Import·초기 GTID 복제 착수 | Cluster/Worker Ready, RDS Available, Endpoint·Master Secret ARN 확인, 첫 App 배포 및 ECR Pull 정상, Import/초기 복제 착수 |
| **10/13 (화)** | Day 2 통합 검증 | ECR Pull, 실제 NeuroPlan App, Route/Probe/Secret, RDS 연결, VPN 경로 검증 → ROSA Ingress LB 확인 → Route 53 tfvars PR/apply → 초기 On-Prem 100 / ROSA 0 및 양쪽 Health Check 정상 확인 | 앱/RDS/VPN 정상, Route 53 초기 상태와 Health Check 2개 정상 |
| **10/14 (수)** | Day 3 전환 사전검증 | Import 마무리 → On-Prem→RDS GTID catch-up·Lag 확인 → Route 53 Weighted `10/90 → 50/50` 전환 검증 및 측정 | GTID/Lag 정상, 10/90·50/50 측정 결과 및 Health Check 정상 |
| **10/15 (목)** | Day 4 Cutover | 점검 모드 → DB Cutover → RDS Writer → 앱 RDS Endpoint/Write 검증 → RDS→On-Prem `db-primary`·`db-replica` 역복제 → IO/SQL Running·Lag 확인 → 운영 `ROSA 1 / On-Prem 0` 적용 | RDS Writer/앱 Write 정상, 두 역복제 정상, 운영 1/0 및 Health Check 정상 |
| **10/16 (금)** | Day 5 DR·종료 | DR 선행조건 확인 → Worker/배포/VPN/DR 장애 테스트 → RTO/RPO 측정 → 녹화·스크린샷·GTID·복제·Cost Explorer 증적 저장 → **18:00 Terraform destroy** | 필수 증적 저장, 유료 리소스 destroy, 잔존 리소스 확인 |

**10/16은 종료일이다. 주말 연장은 하지 않는다.** 미완료 항목이 있으면 10/15 저녁에 우선순위를 정하고, 10/16에는 필수 증적을 우선 확보한 뒤 destroy한다.

### 9.2 10/12 `rosa-on` 완료 조건

현재 `rosa-on.tfvars`는 ROSA뿐 아니라 운영 RDS도 함께 활성화한다. 따라서 10/12 완료 기준은 아래와 같다.

```text
ROSA HCP Ready
ROSA Worker Ready
운영 RDS Available
RDS Endpoint 확인
RDS Master Secret ARN 확인
IAM / STS / OIDC 확인
Operator / GitOps 준비
Frontend / Backend 첫 배포
ECR Pull 정상
DB Import 또는 Initial Replication 착수
```

운영 RDS 기본값은 **Single-AZ, db.t4g.micro**이며, `rds_multi_az=false`를 유지한다.

Multi-AZ는 T6 RDS Failover 시연이 실제로 필요하고 팀이 비용 증가를 승인한 경우에만 별도 변경한다.

### 9.3 10/13 Route 53 완료 조건

ROSA Ingress가 확인되는 즉시 Route 53 초기 상태를 구성한다.

```text
1. ROSA Ingress LB 종류 확인
2. ROSA LB DNS 확인
3. NLB가 아니면 primary_lb_zone_id 입력
4. Route 53 tfvars PR 작성 / 리뷰 / Merge
5. 지정 실행자 plan / apply
6. Weighted On-Prem 100 / ROSA 0 확인
7. primary-health / dr-health Health Check 정상 확인
8. app.neuroplan.cloud 응답이 초기 On-Prem 경로인지 확인
```

이 단계는 **10/14 Weighted 10/90 → 50/50 전환 전 완료**한다.

### 9.4 10/14 전환 사전검증 순서

```text
1. Import 완료 확인
2. On-Prem -> RDS GTID Replica 정상 확인
3. Replication catch-up / Lag 확인
4. Route 53 Weighted 10/90 전환 검증
5. 측정 스크립트 연속 실행
6. Route 53 Weighted 50/50 전환 검증
7. Health Check 및 측정 결과 정리
```

### 9.5 10/15 Cutover 순서

```text
1. 점검 모드 진입
2. DB Cutover -> RDS Writer 전환
3. 애플리케이션 RDS Endpoint 적용
4. 애플리케이션 Write 검증
5. RDS -> On-Prem db-primary GTID Replica 구성
6. RDS -> On-Prem db-replica GTID Replica 구성
7. 두 Replica IO/SQL Running 및 Lag 확인
8. Route 53 운영 가중치 ROSA 1 / On-Prem 0 적용
9. 양쪽 Health Check 정상 확인
10. 10/16 DR 선행조건 충족 여부 확인
```

**10/16 DR 테스트는 5~9번 완료 전에는 시작하지 않는다.**

### 9.6 10/12 시작 전 체크 순서

```text
Infra VM ON
  -> libreswan 확인
  -> S2S VPN Tunnel UP 확인
  -> DR NLB Target healthy 확인
  -> AWS 잔존 리소스 확인
  -> Cost Explorer 현재 누적액 확인
  -> terraform init/plan 확인
  -> rosa-on terraform apply
  -> ROSA / RDS Ready 확인
```

---

## 10. 일정 리스크와 완화책

### 리스크 1. OCP와 ROSA 차이

- OCP 검증 범위를 OpenShift 공통 계층으로 제한
- AWS 연동 기능은 OCP에서 억지로 재현하지 않음
- 공통 base + 환경별 overlay 사용
- OCP/ROSA OpenShift 버전 차이를 기록

### 리스크 2. 5일 일정 지연

- 10/6~10/8에 앱/GitOps/Probe/SCC 오류를 미리 제거
- 10/8에 Terraform plan, Route 53 절차, DB Runbook 확정
- 하루 한 단계 원칙으로 생성·통합·전환·Cutover·DR을 분리
- 10/15 저녁에 진척과 비용을 함께 판단하고 10/16 필수 증적 우선순위를 확정
- 10/16 당일 destroy, 주말 연장 없음

### 리스크 3. OCP 권한 부족

- cluster-admin / Operator 설치 가능 여부를 첫 단계에서 확인
- 권한이 없으면 Operator 설치에 시간을 소모하지 않고 manifest/rollout 검증으로 범위 축소
- 공용 OCP에는 실제 AWS/DB Secret을 넣지 않음

### 리스크 4. 10/12 초기 구축 지연

- HCP/RDS 생성 후 바로 Operator/GitOps/첫 배포와 DB Import를 시작
- 10/13에는 통합 검증과 Route 53 초기 상태 구성에 집중
- 10/14 전환 검증 전에 앱/RDS/VPN/Health Check 문제를 먼저 제거

### 리스크 5. ROSA/AWS IAM 문제

- Terraform plan, quota, RHCS provider, STS/ECR 사전 점검
- 10/12 Day 1에 IAM/STS/OIDC를 최우선 확인

---

## 11. 비용 기준 및 누적 예산 관리

### 11.1 일일 비용 가정

기존 `$45~50/day`는 **운영 판단용 보수적 추정치**이며 확정 단가가 아니다.

현재 코드 기준:

- ROSA Worker 수: **3대**
- `compute_machine_type`: 현재 `null` — ROSA 생성 전 실제 타입 확정 필요
- 기존 프로젝트 비용표의 기준 타입: **m5.xlarge × 3 가정**
- 운영 RDS: **db.t4g.micro / Single-AZ 기본**
- NAT Gateway: ROSA ON 시 활성화
- S2S VPN / DR NLB / ECR / Route 53 / S3 포함

따라서 Worker 타입이 확정되면 즉시 단가를 재계산하고, 최종 판단은 Cost Explorer 실측으로 한다.

### 11.2 ROSA 전 기존 사용분

9/28~10/5 PoC, VPN, DR NLB 및 연휴 유지비를 합친 **ROSA 이전 누적 예상은 약 `$13~15`**로 관리한다.

이 값은 추정치이며 **10/12 ROSA Apply 직전 Cost Explorer 실제 누적액으로 대체**한다.

### 11.3 5일 운영 추정

| 운영 구간 | ROSA ON 기간 | ROSA ON 이후 추정 | ROSA 이전 `$13~15` 포함 누적 추정 |
|---|---:|---:|---:|
| **10/12~10/16** | **5일** | **`$225~250`** | **`$238~265`** |

> 실제 비용은 Worker 타입, ROSA 서비스 요금, EBS, 데이터 처리량, NAT, NLB, VPN, RDS 사용 시간에 따라 달라진다.

### 11.4 예산 중단 기준

예산 상한은 `$500`이며, 최소 `$20`의 안전 여유를 둔다.

- **10/12 ROSA Apply 전**
  - Cost Explorer 프로젝트 누적액 확인
  - 누적액이 **`$230 이하`**이면 5일 운영 가능
  - 근거: 5일 최대 추정 `$250` + 안전 여유 `$20`
  - `$230 초과`이면 Apply 전 팀 재판단

- **10/15 저녁**
  - 누적액이 **`$430 이하`**이면 10/16 Day 5 진행
  - 근거: 1일 최대 추정 `$50` + 안전 여유 `$20`
  - 미완료 항목이 있으면 10/16에 필요한 증적의 우선순위를 정함

- **Hard Stop**
  - Cost Explorer 누적 또는 예상 총액이 **`$480 이상`**이면 추가 작업을 중단하고 필수 증적 확보 후 destroy 우선

- **주말 연장 금지**
  - 10/16(금) destroy가 원칙
  - 10/17~10/18 ROSA/RDS/NAT 유휴 과금이 발생하지 않도록 한다.

### 11.5 비용 확인 시점

- 10/12: ROSA 생성 직전 기존 누적 비용 캡처
- 10/13: ROSA 첫 1일 실측 확인 및 일일 추정치 보정
- 10/14: 전환 검증 후 누적 비용 확인
- 10/15: Cutover 후 누적 비용 및 10/16 진행 조건 확인
- 10/16: DR/증적 완료 후 Cost Explorer 캡처 → 당일 destroy
- destroy 다음 날 이후: 잔존 유료 리소스 및 최종 비용 재확인

Cost Explorer는 최대 하루 늦게 반영될 수 있으므로 화면 값에 당일 사용분 약 `$45~50`을 더해 판단한다.

---

## 12. ROSA 종료 기준

아래 증적을 10/16까지 우선 확보한다.

- ROSA HCP 정상 구축
- NeuroPlan Frontend/Backend 정상 서비스
- Jenkins/ECR/GitOps 배포 정상
- 운영 RDS Cutover 및 Write 정상
- RDS → On-Prem `db-primary` / `db-replica` 역방향 GTID 정상
- Route 53 **Weighted 기반 active-passive** 정상
  - 전환 검증 `10/90 → 50/50`
  - 운영 `ROSA 1 / On-Prem 0`
  - 양쪽 Health Check 정상
- Worker 장애 복구 증적
- 잘못된 배포 차단/복구 증적
- VPN 장애 증적
- ROSA → On-Prem DR 전환 및 RTO/RPO 측정
- RDS PITR/백업 증적
- T6 Multi-AZ 시연을 승인한 경우에만 RDS Failover 증적
- 필요한 로그/스크린샷/Cost Explorer 캡처 완료

**10/16은 종료일이다.** 미완료 증적이 있어도 필수 항목을 우선 확보하고 당일 Terraform destroy를 진행한다. 주말 연장은 하지 않는다.

---

## 13. 최종 운영 원칙

1. 10/2~10/5에는 기존 VPN / DR NLB를 유지한다.
2. **10/6~10/8에는 강사 제공 OCP를 Pre-flight 용도로 활용하고 ROSA/RDS/NAT는 생성하지 않는다.**
3. OCP용 별도 구현을 만들지 않고 ROSA와 동일한 OpenShift base를 사용한다.
4. 공용 OCP 사용 전 권한, GitOps Operator, 이미지 소스, 버전 차이, Secret 사용 원칙을 먼저 확인한다.
5. OCP에서는 앱/GitOps/Route/Probe/SCC 등 OpenShift 공통 계층만 검증한다.
6. **10/9~10/11에는 ROSA/RDS/NAT OFF 상태를 유지한다.**
7. **10/12 `rosa-on` Apply에서 ROSA HCP와 운영 RDS를 함께 생성**하고 첫 배포와 DB Import/초기 복제까지 착수한다.
8. 운영 RDS는 **Single-AZ 기본**이며 Multi-AZ는 T6 시연 승인 시에만 전환한다.
9. **10/13에는 통합 검증과 Route 53 초기 On-Prem 100 / ROSA 0 상태, 양쪽 Health Check 정상까지 완료**한다.
10. **10/14에는 GTID catch-up 후 Weighted 10/90 → 50/50 전환 검증과 측정을 완료**한다.
11. **10/15에는 DB Cutover, RDS → On-Prem 역방향 GTID 복제, 운영 ROSA 1 / On-Prem 0 적용을 완료**한다.
12. **10/16에는 DR/RTO/RPO/녹화·증적을 확보하고 당일 Terraform destroy**한다.
13. 10/16 이후 주말 연장은 하지 않는다.
14. 비용 기준은 10/12 Apply 전 `$230 이하`, 10/15 저녁 `$430 이하`, `$480` Hard Stop으로 관리한다.
15. Route 53 운영 정책은 **Weighted 기반 active-passive**로 통일하며 Failover Routing Policy로 전환하지 않는다.
16. 최종 발표에서는 `비용 절감을 위해 사전 OpenShift 환경에서 애플리케이션 호환성을 검증하고, AWS 종속 검증 시점에만 ROSA HCP를 프로비저닝했다`고 정리한다.
