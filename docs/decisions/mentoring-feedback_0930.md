# 0930 멘토링 피드백 반영 결정안

> - 상태: **결정 반영** (0930 PR #22 리뷰: 정현 Request changes, 예린 코멘트 → 반영) — 재승인 후 **Merge = 팀 확정**
> - 대상: 2차 전체 구성도(0928)에 대한 멘토링 피드백 (0930)
> - 기준 코드: main `dbadcef`
> - 작성: 희재 / 의견: 희재·예린·정현
> - 목표: **10/1 Go/No-Go 전 Merge** (P0 확정). P1은 ROSA 기간 중 여유를 보고 판단
> - 담당 경계가 걸린 항목은 해당 담당자가 동의한 뒤에 `결정`을 적는다

---

## 1. 피드백 요약

| # | 피드백 (요약) | 뜻 |
|---|---|---|
| F1 | ROSA는 워커만 우리 계정에 배포되는 상품인데, 구성도에서 ROSA 구조를 이해한 게 안 보인다. 억지로 쓴 것처럼 보인다 | 구성도에 HCP 구조(Red Hat 관리 Control Plane, 기본 Ingress)를 드러내야 함 |
| F2 | 기본 Ingress Controller가 내장돼 있는데 인증서는 어떻게 넣나. Ingress를 타고 Ingress를 한 번 더 타는 구조냐 | 진입 경로와 TLS 종료 지점을 명확히 |
| F3 | GSLB를 봐라. DR 테스트는 GSLB로 다 커버된다. 비싸지 않다 | AWS에서는 Route 53이 GSLB 역할 → DR 테스트의 중심으로 |
| F4 | 가중치 5:5로 두면 실제로 반반 들어가는지. 트래픽에 따라 가중치를 줄 수도 있다 | 가중치 분배를 측정으로 검증 |
| F5 | 테스트 도구는 뭘 쓰나. 서버에서 `curl localhost`는 부족하다. 실제 트래픽은 제대로 된 도구로 (k6, JMeter 등) | 부하 도구로 실제 트래픽을 만든 상태에서 검증 |
| F6 | 무중단 failover가 목적인데 무중단으로 넘길 서비스가 뭐냐. 앱을 배포해 보고 무중단으로 넘어가는 게 핵심 | 대상 서비스와 기준을 정의. 배포 중 무중단도 증명 |
| F7 | PDB, PriorityClass를 생각해 봐라. 각각 깊게 팔 수 있는 걸 찾아라 | 기술 개수보다 깊이 |
| F8 | DB 계정과 시크릿을 Vault로. 동적 DB 계정(예: 15분 후 삭제)이 Vault의 장점. 눈에 보이는 게 중요 | Vault 동적 자격증명 시연 |
| F9 | 가장 중요한 건 비용 최적화. $500이면 충분, 안 쓸 때 자동으로 끄면 된다. 운영이 아니면 껐다 켜도 파드에 문제 없다 | 비용 절감을 하나의 영역으로 |
| F10 | DB 클러스터가 오히려 비용이 많이 나올 수 있다. DB까지 가는 트래픽을 고려해라 | DB·전송 비용을 비용표에 반영 |
| F11 | 웹 애플리케이션(Java)은 시간 나면 뜯어봐라. 일괄배포가 중요 | 두 사이트에 같은 버전 배포, 여유 있으면 앱 개선 |

## 2. 공통 방향 (희재·예린 의견 일치)

- 주제: **ROSA HCP 기반 하이브리드 DR — Route 53(GSLB)으로 무중단 전환을 실제 트래픽으로 검증하고, 보안·비용까지 최적화**
- 기존 설계 방향(단계적 하이브리드 → ROSA Primary → 온프렘 Warm Standby DR)은 유지. 피드백은 **보여주는 방식과 검증 방법**을 보강하라는 것
- 기술을 늘리지 않고 아래 6개 축을 깊게 판다

| 축 | 내용 | 관련 피드백 |
|---|---|---|
| A. ROSA HCP 구조 | Hosted Control Plane / Worker Machine Pool / 기본 Ingress Controller / Route | F1, F2 |
| B. GSLB | Route 53 Weighted + 헬스체크 (이관: 비율 조정 → 운영: ROSA 1 / 온프렘 0 active-passive) | F3, F4 |
| C. 부하 기반 DR 검증 | k6 트래픽을 건 상태에서 장애 → RTO·에러율 측정 | F5, F6 |
| D. 앱 고가용성 | Replica / Probe / RollingUpdate / PDB / PriorityClass / Topology Spread | F6, F7, F11 |
| E. 시크릿 관리 | HashiCorp Vault + 동적 DB 자격증명 | F8 |
| F. 비용 최적화 | DB·전송 비용 반영, 실측, 생성·삭제 자동화 (워커 축소는 후보) | F9, F10 |

---

## 3. 항목별 결정

### A. ROSA HCP 구조와 구성도 (F1)

**사실 정리**
- Control Plane(API Server, etcd, OAuth 등)은 **Red Hat 소유 AWS 계정**에서 운영. 우리 VPC에는 **워커만** 배포되고, 워커와 Control Plane은 PrivateLink로 통신
- HCP는 별도 Infra 노드가 없음 → **기본 Ingress Controller(Router), 내부 Registry, 플랫폼 Monitoring도 워커에서 실행**
- 기본 Ingress Controller의 LB는 **ROSA가 생성·관리** (우리가 Terraform으로 만들지 않음)

**현재 구성도(0928)의 문제**
- NLB가 두 번 그려짐 (가운데 "ROSA Ingress NLB" + Public Subnet 안 "NLB (ROSA Ingress)") → Ingress를 두 번 타는 것처럼 보임
- Router(기본 Ingress Controller)와 Red Hat 관리 Control Plane이 없음

| | 내용 |
|---|---|
| 희재안 | 구성도 수정: LB 1개 + "ROSA 관리" 표기, Router 박스 추가, VPC 밖에 "Red Hat 관리 Control Plane (PrivateLink)" 추가, 워커 안에 Router·Monitoring·앱 Pod 표시 |
| 예린안 | 동일 (Red Hat 관리 영역 → PrivateLink → 우리 VPC Worker Machine Pool → Ingress Controller → App Pods) |
| 정현 의견 | 이견 없음 (PR #22 리뷰) |
| **결정** | **희재안 확정** — LB 1개("ROSA 관리"), Router 박스, Red Hat 관리 Control Plane(PrivateLink) 표시 |
| 담당 / 기한 | 희재 / 10/1 Go/No-Go 전 |

진입 경로 (ROSA 쪽, 별도 Ingress 추가 없음):
```
사용자 → Route 53 → ROSA 관리 LB → 기본 Ingress Controller(Router) → Route → Service → Pod
```

### A-2. 인증서 (F2)

- ROSA 관리 LB는 우리가 수정하지 않음 → **ACM 인증서를 LB에 붙이지 않고, TLS는 Router에서 종료**
- 온프렘 DR 경로는 NLB·HAProxy 모두 TCP 패스스루 → **온프렘 NGF가 TLS 종료** → 같은 인증서를 두 곳에 둠 (시나리오 4.9 유지)

| | 내용 |
|---|---|
| 희재안 | **Route 단위 TLS** (`edge` 종료, `app.<도메인>` Route에 Let's Encrypt 인증서). 기본 IngressController는 건드리지 않음. 자동 갱신(cert-manager Operator + Route 53 DNS-01)은 P2 |
| 예린안 | `openshift-ingress`의 TLS Secret을 `IngressController.spec.defaultCertificate`로 기본 인증서 교체, 또는 Route 단위 TLS |
| **쟁점** | 기본 IngressController의 도메인은 `*.apps.<클러스터>.openshiftapps.com` → 우리 도메인 인증서로 기본 인증서를 바꾸면 콘솔·OAuth 등 기본 Route의 인증서가 맞지 않을 수 있음. ROSA에서 기본 IngressController 수정 범위가 제한될 수 있음 → **확인 필요 (5장)** |
| 예린 리뷰 | `defaultCertificate` 교체보다 **앱 Route 단위 TLS**에 동의. 기본 IngressController는 유지 |
| 정현 의견 | 이견 없음 |
| **결정** | **Route 단위 TLS** — 기본 IngressController는 유지하고, 사용자 도메인 Route(`app.<도메인>`)에만 인증서 적용 |
| 담당 | 인증서 발급 희재 → Route 적용 예린 |

발표 답변 문구 (합의 후 확정):
> "ROSA에 내장된 기본 Ingress Controller를 사용하고 별도 Ingress Controller는 추가하지 않았습니다. 사용자 도메인 인증서는 TLS Secret으로 등록해 Route 단위로 적용했습니다."

### B. GSLB = Route 53 (F3, F4)

- AWS에 "GSLB"라는 이름의 단일 상품은 없음. **Route 53**(DNS 방식: Weighted / Failover / Latency / Geolocation + 헬스체크)이 GSLB 역할. 비교 대상으로 Global Accelerator(Anycast IP)가 있음
- 우리 설계의 Route 53 Weighted(이관 비율 조정 → 운영 active-passive) + 헬스체크가 이미 GSLB → **발표와 구성도에 "Route 53 = GSLB"를 명시**

| Route 53 정책 | 우리 구조 적용 |
|---|---|
| Weighted + 헬스체크 | ✅ 전환 검증 (온프렘 100 → 90 → 50, **5:5 검증**) + ✅ **운영 단계 핵심 (T6)**: ROSA 1 / 온프렘 0 Weighted 기반 active-passive |
| Failover + 헬스체크 | ❌ 사용 안 함 (1001 변경, 아래) |
| Latency / Geolocation | ❌ 서울 리전 하나 + 국내 사용자라 의미 없음 |

**운영 단계 정책 변경: Failover → Weighted 기반 active-passive (1001, #28 리뷰 · 예린 제안, 정현·희재 동의)**
- 단계: 초기 Routing `off` → 전환 검증 Weighted 10 / 90 등 단계적 조정 → 운영 기본 ROSA 1 / 온프렘 0
- ROSA·온프렘 레코드 모두 개별 헬스체크(`primary-health`, `dr-health`) 연결
- 동작: 평소 ROSA만 응답. 가중치 0보다 큰 레코드(ROSA)가 모두 unhealthy면 Route 53이 가중치 0 레코드(온프렘)로 응답 → T6 장애 전환 목적 충족 ([AWS 문서](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-failover-types.html))
- 이유: 같은 이름에 Weighted와 Failover 레코드를 함께 둘 수 없음 → Failover로 바꾸려면 `none`을 거친 apply 2회, 그 사이 `app` 레코드 공백과 NXDOMAIN 음수 캐시(최대 900초) 위험
- 반영: `modules/edge` README·변수 설명, envs/prod `route53_routing_mode` 주석(#30), 시나리오 4.8

**5:5 검증 방법 (희재·예린 의견 일치)**
- Route 53 가중치는 **DNS 응답 비율**이지 요청 한 건 단위 L7 분배가 아님 → Resolver 캐시와 TTL(ELB Alias 60초) 영향 → 정확히 500:500을 기대하지 않음
- 검증 대상: 충분한 표본에서 **설정 가중치에 근접하는지**
- 방법: 응답에 어느 사이트인지 표시(`X-Site: rosa|onprem` 헤더 또는 `/actuator/health/routing` 응답 필드) → k6가 사이트별 요청 수 집계. k6 DNS 캐시(`dns.ttl`)를 짧게 두고 VU 여러 개로 측정
- 사이트 표시 방법(Route·NGF 헤더 설정 / 앱 환경변수)은 담당 합의 필요

| | 내용 |
|---|---|
| 희재안 | Route 53 중심 유지. **Global Accelerator는 제외** — 같은 리전 안 Active-Passive에 안 맞음(가중치 0 엔드포인트는 fail-open일 때만 트래픽을 받음). 비용은 $0.025/h(현재 5일 일정이면 약 $3) + 전송 추가 요금으로 크지 않지만 효과가 작음 |
| 예린안 | On-Prem ↔ ROSA에는 Route 53이 자연스러움. GA는 AWS 멀티리전에 강함 |
| 정현 의견 | 이견 없음 |
| **결정** | **Route 53 = GSLB로 명시, Global Accelerator 제외**. 사이트 표시(`X-Site`) 방법은 정현·예린이 앱 구현과 함께 결정 |
| 담당 | 희재 (`modules/edge`: DR NLB, Route 53 레코드·헬스체크) |

### B-2. DR 시연 방향

| | 내용 |
|---|---|
| 희재안 | **P0 핵심 = ROSA 장애 → 온프렘 DR (T6)**. 최종 구조가 ROSA Primary + 온프렘 DR이므로 이 방향이 주제와 일치 |
| 예린안 | k6 트래픽 5:5 상태에서 **On-Prem Ingress 장애 → ROSA로 전환**을 Grafana로 보여줌 |
| **쟁점·보완** | 예린안은 **이관 단계(가중치) 시연으로 채택 가능**. 단 이관 단계의 DB Writer는 온프렘 하나(ROSA 앱도 VPN으로 MaxScale 사용) → 장애 범위를 **온프렘 진입 경로(HAProxy/NGF)로 한정**해야 함. 온프렘 전체가 죽으면 ROSA 앱도 DB를 잃음 |
| 제안 | ① 이관 단계: 5:5 + 온프렘 진입 장애 → ROSA 흡수 (보조 시연) ② 운영 단계: ROSA 장애 → 온프렘 DR (T6, 핵심) |
| 정현 의견 | 핵심 T6 = 운영 전환 후 ROSA Primary 장애 → 온프렘 DR. 전제는 RDS → 온프렘 db-primary·db-replica 복제와 GTID 동기화 정상. 이관 단계는 Writer가 온프렘 MaxScale이라 온프렘 전체 장애 시 ROSA Backend도 DB 연결을 잃음 |
| **결정** | **핵심 T6 = ROSA Primary 장애 → 온프렘 DR** (전제: RDS → 온프렘 복제·GTID 정상). **이관 단계 보조 시연은 온프렘 진입 경로(NGF/HAProxy 또는 DR NLB 경로) 장애 → ROSA 흡수로만 한정** |

온프렘 쪽 경로는 반드시 DR NLB를 거침 (온프렘은 공인 IP 없음):
```
Route 53 → DR NLB → S2S VPN → Infra VM → VIP 192.168.24.100:443 → NGF → 온프렘 App
```

### C. 부하 도구와 측정 (F5)

| 도구 | 만든 곳 | 비고 |
|---|---|---|
| **k6** | Grafana Labs (오픈소스) | JS 시나리오, VU·RPS·threshold, Grafana 연동. 피드백에서 말한 "Grafana에서 만든 무료 도구" |
| Locust | 독립 오픈소스 (Python) | 웹 UI |
| JMeter | Apache | GUI 기반 |

| | 내용 |
|---|---|
| 희재안 | **k6로 통일**. `probe.sh`(1초 curl 루프)는 주 증거에서 빼고, **권한 DNS 전환 시각(Control RTO) 기록용 보조**로만 유지 |
| 예린안 | k6 추천. `curl localhost`·`oc get pods` 수준의 증적은 버림 |
| 정현 의견 | k6 대상 트랜잭션 3종 확정 (D 참고) |
| **결정** | **k6로 통일**, `probe.sh`는 Control RTO 기록 보조 |
| 담당 | 시나리오·실행 희재, 대상 API 정의 정현 |

**k6 실행 조건**
- 실행 위치: **학원망 밖** (노트북 핫스팟 등) → 사용자 관점, 권한 DNS가 아닌 일반 Resolver 경유
- 시나리오: 로그인 → 조회 → 쓰기 반복 (6장 D의 대상 API)
- 결과: 초 단위 RPS·에러율·p95를 Grafana 또는 k6 웹 대시보드·CSV로 → 보고서 그래프

**측정 지표 (희재안 + 예린안 병합)**

| 지표 | 정의 |
|---|---|
| T0 | 장애 주입 시각 |
| T1 | Route 53 헬스체크 실패 판정 (CloudWatch `HealthCheckStatus`) |
| T2 | 권한 DNS 응답이 대상 사이트로 바뀐 시각 → **Control RTO = T2 − T0** |
| T3 | k6 에러율이 0으로 돌아온 시각 → **User RTO = T3 − T0** |
| 요청 | 전체 / 실패 / **에러율** (장애 구간) |
| 지연 | p95 / p99 (정상 구간 vs 장애 구간) |
| 쓰기 | 실패한 쓰기 트랜잭션 수, **RPO** (마지막 쓰기 ID 비교) |
| 세션 | 전환 후 로그인 유지 여부 (JWT 서명 키 공유) |

### D. 무중단 대상 서비스와 앱 고가용성 (F6, F7, F11)

**무중단 대상 (희재·예린 의견 일치)**
- 정적 페이지가 아니라 **Frontend → Backend API(Java) → DB 읽기·쓰기**까지 실제 트랜잭션
- k6 대상 트랜잭션 (정현 확정): **① 로그인 ② 문제·계획 등 핵심 데이터 조회 ③ 풀이·계획 저장 등 DB 쓰기**. 정확한 HTTP Endpoint와 요청 형식은 Backend 인수인계 코드 확인 후 확정 (정현)
- 기준 (정현 확정)
  - **롤링 배포: k6 실패 요청 0**
  - **장애 전환: 실패 요청 수·에러율·p95/p99·User RTO·마지막 쓰기 ID를 측정해 기록**. DNS 기반 Route 53 전환이므로 장애 구간 오류 0을 사전 보장하지 않고, 실제 측정값을 증적으로 사용

**배포 무중단 (F6 "배포 한 번 해보고 무중단으로 넘어가는 것")**
- k6 트래픽을 건 상태에서 새 버전 롤링 배포 → 에러 0 증명
- 설정: `replicas ≥ 2`, readiness/liveness + **startupProbe**(Java 기동 지연), `maxUnavailable: 0` / `maxSurge: 1`, preStop + graceful shutdown
- 일괄배포: GitOps로 **ROSA·온프렘 DR에 같은 이미지 태그** 반영 (Warm Standby 버전 불일치 방지) — 기존 설계 유지, 증거만 남김

**PDB / PriorityClass / 분산 배치**

| 기능 | 쓰임 | 시연 |
|---|---|---|
| PDB (`minAvailable: 1`) | drain·업그레이드 같은 **자발적 중단**에서 최소 Pod 수 보장. 노드가 갑자기 죽는 경우는 막지 못함 | T1 워커 drain 중 k6 에러 0 |
| PriorityClass | 자원이 부족할 때 backend > frontend > 부가 기능 순으로 유지 | 낮은 우선순위 부하 Pod로 노드 자원을 채운 뒤 backend가 선점(preemption)으로 유지되는지 확인 (워커 축소는 F에서 제외됨) |
| Topology Spread / Anti-Affinity | Pod를 AZ·노드에 분산 | 워커 1대 장애 시 영향 범위 축소 |

| | 내용 |
|---|---|
| 희재안 | P0: PDB·PriorityClass·Probe·RollingUpdate |
| 예린안 | 위 7가지를 "고가용성을 고려한 OpenShift 앱 설계" 하나의 주제로 묶음 |
| 정현 의견 | 대상 트랜잭션 3종·기준 확정 (위) |
| **결정** | **대상 3종 + 기준(롤링 배포 실패 0 / 장애 전환은 측정값 증적)**, PDB·PriorityClass·Probe·RollingUpdate·Topology Spread는 P0 |
| 담당 | 매니페스트 예린, 앱 설정·대상 API 정현 |

### E. Vault (F8)

- Vault Database Secrets Engine(MySQL/MariaDB) → 요청할 때마다 **임시 DB 계정 발급**, lease 만료(예: 15분) 시 계정 삭제
- 시연: Vault UI의 lease → `mysql.user`에 `v-...` 계정 생성 → 만료 후 삭제 확인 → 새 자격증명으로 앱 정상

| | 내용 |
|---|---|
| 희재안 | 채택하되 **P1**, 범위를 좁힘 |
| 예린안 | 채택 추천. Kubernetes Secret의 고정 DB 계정 → Vault 동적 자격증명. 리뷰: P1 유지 동의, **Vault 설치·연동은 예린**, DB role·권한과 CREATE/DROP USER 복제 검증은 정현과 분담 |
| 정현 의견 | **P1 별도 PoC**, W2/W3의 RDS 전환·DR 핵심 경로를 막지 않는 조건 |
| **결정** | **P1 목표: Cutover 후 ROSA Backend → RDS 운영 경로에 HashiCorp Vault 동적 자격증명을 실제 적용** (W2/W3의 RDS 전환·DR 핵심 경로를 막지 않는 조건). 아래 1~5 적용 |
| 정현 추가 리뷰 | P1 목표를 "적용 검토"가 아니라 **운영 경로 실제 적용**으로 명시. TTL 15분 검증 role과 Backend 기본 계정 정책을 구분 |
| 담당 | Vault 설치·연동 **예린** / DB role·권한, 동적 계정 DDL 복제 검증 **정현** |

**적용 조건 (희재 제기 → 정현·예린 리뷰로 확정)**
1. **DR 의존성**: Vault를 ROSA에 두면 ROSA 장애(T6) 때 Vault도 같이 멈춤 → **온프렘 DR 앱은 정적 계정 유지** (Ansible Vault로 관리). 발표 근거: "DR 경로는 의존성을 줄이기 위해 동적 자격증명을 쓰지 않음"
2. **적용 범위**: 이관 단계 Writer는 온프렘, Cutover 후 RDS → **Cutover 후 RDS에 연결하는 ROSA Backend 앱 DB 계정에 실제 적용** (다른 경로는 적용하지 않음)
3. **복제 영향**: RDS에서 생성·삭제한 동적 계정 DDL(CREATE/DROP USER)의 온프렘 Replica 전파 여부 → **P1 검증 항목** (정현)
4. **role 구분**
   - **검증용 role (TTL 15분)**: 동적 계정 생성·만료(계정 삭제)를 확인하는 별도 role. 시연용
   - **Backend 기본 role**: 자격증명 갱신과 Connection Pool 재연결(Vault Secrets Operator `rolloutRestartTargets` 등)을 검증한 뒤 **더 긴 TTL 또는 자동 갱신 정책**으로 적용
5. **Secrets Manager 역할**: RDS Master Secret은 기존대로 Secrets Manager(`manage_master_user_password`). Vault는 그 위에서 앱 계정만 발급

### F. 비용 최적화 (F9, F10)

**전제 (희재·예린 의견 일치)**
- ROSA HCP는 **클러스터 요금 $0.25/h를 멈출 수 없음**. 워커 EC2를 콘솔에서 직접 끄는 방식은 쓰지 않음
- 워커 수 조정은 머신풀 replicas로만 가능. 단, 현재 Terraform의 기본 머신풀은 **3AZ 구성**
- "껐다 켜도 문제없다"는 **워커·Pod 수준에서 맞음**. 클러스터 삭제·재생성은 여전히 위험 → 프로젝트 제약 문구를 이 기준으로 구분

**워커 스케줄 축소 — 초안(3 → 2대, 약 $90 절감)은 철회**
- 초안: 야간·연휴에 3 → 2대로 줄여 약 $90 절감 (1대당 약 $0.41/h × 216h 추정)
- 철회 이유 (리뷰): ① 기본 머신풀이 3AZ라 단순 3 → 2 축소는 AZ 분산을 깸 ② 워커 replicas를 Terraform이 관리 → 스케줄 조정 시 **state 드리프트** ③ PDB·부하·분산 배치 검증이 먼저

| | 내용 |
|---|---|
| 희재안 (초안) | P0. 야간·연휴 3 → 2대, 시연일은 3대 → **리뷰 반영해 철회** |
| 예린안 | Terraform 생성·삭제, 워커 최소화, RDS·NAT·LB 정리, Budgets·Cost Explorer. 리뷰: **기본 3AZ Worker 3대 유지**, Scheduled Scaling이 필요하면 **별도 Machine Pool/Autoscaling 구조로 검토**, **Spot Machine Pool 제외** |
| 정현 의견 | 워커 축소는 P0가 아니라 **P1 또는 비용 절감 후보**. 실제 ROSA 가동 기간인 10/12~10/16은 3대 유지, 부하·PDB·분산 배치 검증 후 여유가 있을 때만 별도 Plan·승인으로 결정 |
| **결정** | **기본 3AZ 워커 3대 유지** (10/12~10/16). Worker 타입은 **m5.xlarge × 3**으로 확정(#42). 스케줄 축소는 **P1 후보** — 필요하면 별도 Machine Pool/Autoscaling 구조로 검토하고 별도 Plan·승인. **Spot 제외** |
| 담당 | 예린 (지정 실행자 규칙과 함께) |

**비용 최적화 P0 (워커 축소 대신)**
- Worker 타입·대수 확정: **m5.xlarge × 3** (4 vCPU / 16 GiB, 총 12 vCPU, #42)
- ROSA 핵심 고정비 기준: EC2 Worker 약 **$16.992/day** + ROSA Worker 서비스료 **$12.312/day** + HCP cluster fee **$6.000/day** = **약 $35.304/day**
- Worker EBS, NAT Gateway, Site-to-Site VPN, RDS, DR/Ingress NLB, Route 53, 데이터 처리·전송까지 포함한 프로젝트 운영비는 **$45~50/day 보수적 추정치 유지**
- 실제 ROSA 가동: **10/12~10/16 5일** → ROSA 핵심비용 약 **$176.52**, 전체 운영비 약 **$225~250**
- ROSA 이전 누적 약 **$13~15** 포함 프로젝트 누적 예상: **약 $238~265**
- Cost Explorer: **10/13 첫날 비용 실측**, **10/15 저녁 진행 여부 판단**, **10/16 destroy 전 캡처**, destroy 다음 날 이후 최종 비용 재확인
- 종료 시 **10/16 Terraform destroy** + 잔존 리소스 확인. VPN·DR NLB를 포함한 유료 리소스도 함께 정리
- 비용 중단 기준: 10/12 Apply 전 누적 **$230 이하**, 10/15 저녁 누적 **$430 이하**, 누적/예상 총액 **$480 이상 Hard Stop**
- 발표: 이미 반영한 설계 결정(NAT 1개, S3 Gateway Endpoint, Resolver 제외, RDS 평소 Single-AZ, GA 제외)을 **비용 근거와 실측값**으로 정리

**DB·전송 비용 (F10)** — 비용표에 추가
| 항목 | 내용 |
|---|---|
| RDS Multi-AZ | 인스턴스 비용 약 2배 → 현재 결정대로 **평소 Single-AZ, T6 직전에만 Multi-AZ** |
| AZ 간 전송 | 워커 3AZ ↔ RDS 1AZ, 양방향 과금 |
| VPN 전송 | 이관 단계 ROSA 앱 → VPN → 온프렘 DB, DR 경로 응답 → AWS 밖으로 나가는 전송 요금 |
| 부하 테스트 | k6 트래픽량 × 단가로 **사전 계산**, 테스트 시간을 정해 두고 실행 |

**넣지 않는 것**: Global Accelerator, 추가 Ingress Controller·ALB, Aurora·DB 클러스터, Route 53 Resolver, WAF(기존 결정 유지)

---

## 4. 결정 요약 (Merge 시 확정)

| # | 항목 | 우선순위 | 담당 | 기한 | 결정 |
|---|---|---|---|---|---|
| A | 구성도 수정 (HCP 구조, LB 1개, Router) | P0 | 희재 | 10/1 | ✅ 확정 |
| A-2 | 인증서: Route 단위 TLS, 기본 IngressController 유지 | P0 | 희재 → 예린 | 도메인 확정 후 | ✅ 확정 |
| B | Route 53 = GSLB 명시, 5:5 검증 설계, GA 제외 | P0 | 희재 | 10/6~8 | ✅ 확정 |
| B-2 | DR 시연: 핵심 T6 + 이관 단계는 진입 경로 장애만 | P0 | 희재·정현 | 10/12~14 | ✅ 확정 |
| C | k6 도입, probe.sh는 보조 | P0 | 희재 (Endpoint 정현) | 10/6 전 초안 | ✅ 확정 |
| D | 대상 3종·기준, 배포 무중단, PDB·PriorityClass | P0 | 예린·정현 | 10/6 전 | ✅ 확정 |
| E | Vault 동적 자격증명을 Cutover 후 ROSA Backend → RDS 운영 경로에 실제 적용 (검증용 TTL 15분 role 별도, DR은 정적 계정) | P1 | 설치·연동 예린 / DB role·복제 검증 정현 | ROSA 기간 | ✅ 확정 |
| F | m5.xlarge × 3 비용 기준, DB·전송 비용 반영, Cost Explorer 실측, 10/16 destroy | P0 | 비용표 예린·희재 | 10/12~10/16 | ✅ 확정 |
| F-2 | 워커 스케줄 축소 (별도 Machine Pool/Autoscaling) | P1 후보 | 예린 | 검증 후 | 3대 유지, 별도 Plan·승인 |
| — | cert-manager 자동 갱신 | P2 | 예린 | — | |

## 5. 확인 필요 (사실 확인)

| # | 확인할 것 | 담당 | 상태 (0930 리뷰) |
|---|---|---|---|
| 1 | ROSA HCP 기본 IngressController의 LB 종류, 기본 인증서 교체 가능 범위 | 예린 | Route 단위 TLS로 결정 → LB 종류만 확인 |
| 2 | 3AZ 머신풀에서 한 AZ를 0대로 줄일 수 있는지 (HCP 최소 워커 2대) | 예린 | 3 → 2 축소 미적용으로 결정 |
| 3 | HCP Spot 머신풀 지원 여부 | 예린 | Spot 제외로 결정 |
| 4 | 머신풀 수동 조정 시 Terraform 드리프트 처리 방식 | 예린 | F-2 검토 시 별도 구조로 |
| 5 | Vault 동적 계정의 CREATE/DROP USER가 온프렘 Replica로 복제되는지 | 정현 | P1 검증 항목 |
| 6 | 응답에 사이트 표시(`X-Site`) 방법 — Route·NGF 헤더 설정 또는 앱 | 정현·예린 | 앱 구현 방식과 함께 결정 |
| 7 | VPN·AZ 간 전송 단가 (서울) → 비용표 | 희재 | |

## 6. 계획서 기준(시나리오 v2.4) vs 변경안

| 항목 | 기존 (v2.4) | 변경안 (이 문서 Merge 시) |
|---|---|---|
| 측정 주 증거 | `probe.sh` 1초 curl 루프 | **k6 부하 트래픽** + probe.sh(Control RTO 보조) |
| 시연 대상 | `/health/ready` + 조회 API | **로그인·조회·쓰기 트랜잭션** + 배포 중 무중단 |
| GSLB | Route 53 (명칭 없음) | **Route 53 = GSLB** 명시, 5:5 분배 검증 추가 |
| DR 시연 | T6 (ROSA → 온프렘) | T6 유지 + **이관 단계 온프렘 진입 장애 → ROSA** 보조 |
| 인증서 | Router·NGF에 같은 인증서 | 동일 + **Route 단위 TLS** 명시, 별도 Ingress 없음 |
| 시크릿 | Secrets Manager | Secrets Manager(Master) + **Vault 동적 자격증명(P1, Cutover 후 ROSA Backend → RDS 실제 적용)** + 온프렘 DR 정적 계정(Ansible Vault) |
| 앱 HA | HPA/PDB | + **PriorityClass, startupProbe, Topology Spread** |
| 비용 | ROSA 12일 상시 3대 | **10/12~10/16 5일, m5.xlarge × 3 유지**. ROSA 핵심 약 **$35.304/day**, 전체 보수적 **$45~50/day**, 프로젝트 누적 예상 **$238~265**. Cost Explorer 실측 + 10/16 destroy, 스케줄 축소는 P1 후보(별도 Machine Pool/Autoscaling) |
| ROSA 제약 해석 | "껐다 켜면 문제" | **클러스터 재생성은 금지**. 워커 수 조정은 별도 구조·Plan·승인이 있을 때만 |

## 7. 참고

- [ROSA architecture (AWS)](https://docs.aws.amazon.com/rosa/latest/userguide/rosa-architecture-models.html)
- [Route 53 routing policies](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy.html)
- [Global Accelerator — failover for unhealthy endpoints](https://docs.aws.amazon.com/global-accelerator/latest/dg/about-endpoints-endpoint-weights.unhealthy-endpoints.html)
- [Global Accelerator pricing](https://aws.amazon.com/global-accelerator/pricing)
- [ROSA Scheduled Cluster Scaling (Red Hat)](https://cloud.redhat.com/experts/rosa/schedule-scaling/)
- [cert-manager Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift)
- [Vault MySQL/MariaDB database secrets engine](https://developer.hashicorp.com/vault/docs/secrets/databases/mysql-maria)
- [Grafana k6](https://grafana.com/docs/k6/latest/)
