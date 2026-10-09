# ROSA 가동 일정·10/12 P0 구축 및 Jenkins CI/CD 실행 체크리스트

> **#33 최신화 제안본 (2026-10-09)** — [AWS Migration Issue #33](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/issues/33)의 일정·담당·비용 기준을 유지하면서, [Issue #76의 ROSA P0 DB·VPN·TLS 협의 결과](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/issues/76)와 GitOps #12 리뷰에서 합의된 단계적 배포를 반영한 버전 관리용 문서이다.
> **PR Merge가 Issue #33 본문을 자동 수정하지는 않는다.** 리뷰·병합 후 #33 본문에서 본 문서로 연결하거나 최신 핵심 체크리스트를 반영한다.
> 이 문서는 **실행 계획과 사전 검증 증적**이다. 10/9 Jenkins → ECR → GitOps → On-Prem CI/CD는 검증 완료했지만, 10/12 ROSA/Terraform Apply, ROSA Secret 전송·실제 배포, Route 53 전환, DB Cutover, T5·T7 리허설은 별도 승인·실행·검증이 필요하다.

## 개요
PR #32(ROSA 가동·비용 최적화 결정)에 따른 ROSA 가동 일정과 담당별 체크리스트입니다.
**10/8 Go/No-Go 결정 및 10/9 후속 합의 반영본**입니다. 기존 #33 일정·비용 결정은 유지하고 10/12 실제 배포 게이트를 구체화합니다.

## 핵심 결정 (3명 합의)
- ROSA는 **10/12에 1회 생성 → 10/16까지 5일 연속 가동**, 10/16 당일 destroy (주말 연장 없음)
- **10/9 Jenkins CI/CD 사전 검증 완료**(Frontend/Backend SCM Polling 단독 자동 배포, ECR, GitOps, On-Prem). 10/12는 **GitOps `main`의 최신 Frontend·Backend 이미지로 ROSA 최초 배포 → Smoke Test**를 진행한다. 같은 Jenkins 테스트 재실행은 필수 단계가 아니며, 이후 통합·전환 사전 검증 → Cutover → DR 검증·종료 순서를 유지한다.

## 일정
| 날짜 | 단계 | 내용 |
|---|---|---|
| 10/2~10/5 | OFF | VPN·DR NLB만 유지 |
| 10/6~10/7 | 준비 | 담당별 사전 준비 (아래 체크리스트) |
| **10/8** | **Go/No-Go** | 이 문서 기준 판정, 10/12 실행 순서 확정 |
| 10/9~10/11 | 학원 불가 | 문서·코드 작업만 |
| 10/12 | Day 1 | ROSA·운영 RDS·NAT 생성, GitOps `main` 기준 Frontend `48d7e15`·Backend `e5d288f` 최초 배포·Smoke Test, ROSA/On-Prem 이미지 확인, 데이터 초기 Import·GTID 복제 착수(RDS Available 이후) |
| 10/13 | Day 2 | ROSA 연동/TLS·Route 53 레코드·Health Check(조건 충족 시), **T5 Fence 사전검증(별도 승인; 전체 DR 전환과 구분)** |
| 10/14 | Day 3 | Cutover 사전 검증, 가중치 10/90 → 50/50 |
| 10/15 | Day 4 | DB Cutover·역복제, 저녁 진행·비용 점검 |
| 10/16 | Day 5 | **Worker/Pod → Deployment Safety → PITR → VPN → ROSA→On-Prem DR 검증, Failback 절차 설명**, 녹화 → 18:00 destroy 시작 |
| 10/17~10/18 | 주말 | 리소스 없음 |
| 10/20 | 구축 마감 | 잔존 리소스·최종 비용 확인, 최종 스냅샷 삭제 |

## 10/6 ~ 10/9 사전 준비 및 후속 확정 (ROSA 없이)

### 희재 (네트워크)
- [x] 인증서 DNS-01 발급 (SAN: app, primary-health, dr-health) + 예비 CA(ZeroSSL) Warm Standby (#59, #60, #62) — 온프렘 Secret 배포 완료, ROSA Secret은 10/12
- [x] 온프렘 dr-health 호스트 (NGF HTTPRoute, `/actuator/health/routing` 외부 200)
- [x] ROSA 서브넷 → MaxScale 4006 firewalld 스크립트 (#48, 적용은 10/12, 10/14 Weighted 단계용)
- [x] 측정 스크립트: Control RTO probe (#50) + User RTO·연속성 k6 (#56)
- [x] 10/12 아침 점검 스크립트 (Infra, VPN, DR NLB) (#47, 10/7 리허설 FAIL 0)
- [x] Route 53 wiring/validation PR (#49, ROSA LB DNS 입력·weighted 전환은 10/13)
- [x] 10/12 ImagePullBackOff 대응 A 실행 순서 반영 (실행시트)
- [x] On-Prem DR Backend·Frontend `imagePullPolicy: IfNotPresent` GitOps 반영 (B, gitops #6 Merged 10/8)
- [x] 10/9 On-Prem `app.neuroplan.cloud` HTTPS 사전 경로 검증 PASS: Gateway Listener, GitOps #11/HTTPRoute, cp1 NGF NodePort, Infra VM VIP(`/` 200·비인증 `/api/learning/state` 401·TLS 검증 0). **희재님 공유 결과 및 GitOps #11 댓글 기준이며 실제 T5/T7 시연 완료는 아님**. 원본 로그 보관·cp1 전체 스크립트 SHA/적용 승인 기록은 별도 증적 추적.

### 예린 (플랫폼)
- [x] rosa-on 사전 Plan 재확인 (**2026-10-08 실행 가이드 기준 39 생성 / 0 변경 / 0 삭제**). **10/12 승인된 State에서 최신 Plan 재확인 필수**
- [x] ROSA overlay, Operator 목록, primary-health Route
- [x] Hosted Zone `bootstrap/dns` import
- [x] [docs: 0930 멘토링 피드백 반영 결정안 추가 #22] 비용 행 수정 PR
- [x] 워커 인스턴스 타입 확정 → 하루 비용 재계산 (m5.xlarge × 3)
- [ ] (선택) 실제 앱 이미지로 OCP 확인
- [x] Application #6 Write Fence 코드 Merge, GitOps #10 `DEMO_WRITE_FENCE: "false"` 기본값 Merge (ROSA 전용; 쓰기 차단 미활성)
- [x] 10/9 Jenkins IAM `ecr:DescribeImages` 오류 복구 및 Terraform Apply 완료([AWS Migration PR #85](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/85), **현재 Draft/미병합**; 리뷰·Merge 필요)
- [x] Jenkins 재실행 시 Backend `a4d120f` 이미지 재사용·GitOps 자동 Push·On-Prem 배포 확인. 이후 SCM 자동 감지로 Frontend `48d7e15` 단독, Backend `e5d288f` 단독 Build/Push·GitOps Push·On-Prem 배포 확인(각각 `2/2 Ready`)
- [x] ECR 최신 이미지 확인: Frontend `48d7e15` (`sha256:a8eca0d334537dcdcbcaf67712cc60018fe8d3290fe21c3eb77c140c6bbe1971`), Backend `e5d288f` (`sha256:5a379cde7eb6906296864cac2ae1b6174ed3f952a4382019731dc87e4460afe0`)
- [x] GitOps `main` [commit `9bbe350`](https://github.com/neuroplan-hybrid/neuroplan-gitops/commit/9bbe35025a9639c054cb9cd63f08fc7103f5df17): ROSA·On-Prem DR Overlay에 위 최신 태그 반영; On-Prem Argo CD `Synced/Healthy` 확인
- [x] GitOps [PR #12](https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/12)는 기존 ROSA Backend `b7deb4a → a4d120f` 변경 목적의 **Open/미병합** PR. 현재 `main`은 더 최신인 `e5d288f`이므로 그대로 Merge하지 않고 담당자 검토 후 별도 정리
- [ ] **10/12 ROSA 신규 환경** 이미지 Pull·Pod Ready·MaxScale 연결·TLS·로그인/조회/저장·Fence `false` 검증 및 실측 SHA 확보 (**아직 미실행**)

### 정현 (데이터)
- [x] NFS 논리백업본 경로·대상 DB(infraready)·Import 검증 명령 확정 (SHA-256·`gzip -t`, dump GTID 기준)
- [x] 운영 RDS Endpoint / Master Secret ARN → Ansible이 RDS 식별자로 AWS에서 조회
- [x] On-Prem → RDS GTID 복제, RDS → db-primary·db-replica 역복제 Runbook/Ansible 실행 순서 확인 (#57, #58)
- [x] Cutover 전·후 확인 기준 정리 (GTID, IO/SQL Running, Lag, Row Count, 쓰기 후 재조회)
- [x] Health Endpoint 확인: `/actuator/health/liveness`, `/actuator/health/readiness`, `/actuator/health/routing`

## ROSA 5일 시간표
| 날짜 | 단계 | 내용 |
|---|---|---|
| 10/12 | 구축·첫 검증 | ROSA·RDS·NAT 생성, 최신 GitOps `main` 이미지(Frontend `48d7e15`, Backend `e5d288f`)로 최초 배포·Smoke Test, ROSA/On-Prem 이미지·Secret/TLS 확인; NFS Import/GTID 착수는 RDS Available 이후 데이터 담당 병행 |
| 10/13 | 통합 | 10/12 결과 재확인, ROSA TLS preflight, Route 53 tfvars apply(조건 충족 시), 헬스체크, **Fence=true 503 범위 사전검증(별도 승인 및 원복, 전체 T5 DR 전환 아님)** |
| 10/14 | 전환 사전검증 | GTID catch-up, Weighted 10/90 → 50/50 |
| 10/15 | Cutover | DB Cutover, 역복제, 저녁 진척·비용 판단 |
| 10/16 | DR·종료 | 장애 시연 T1~T6, RTO/RPO, 18:00 destroy 시작 |

## 10/9 CI/CD 사전 실증 및 10/12 ROSA P0 최초 배포 게이트

**변경된 실행 순서:** 10/9에 Jenkins IAM 권한 문제를 해결하고 **SCM Polling → 변경 컴포넌트 Test/Build → ECR Push·조회 → GitOps `main` Push → On-Prem Argo CD 배포**를 검증했다. 따라서 **10/12 ROSA 최초 배포 때 이전 태그 `b7deb4a`/`bcc6857`로 먼저 배포하거나 Jenkins를 다시 실행해 태그를 통일할 필요가 없다.** ROSA는 최신 GitOps `main` 태그를 사용하며, ROSA 자체의 실제 배포 검증은 아직 남아 있다.

### 10/9 완료: Jenkins·ECR·GitOps·On-Prem 증적 (ROSA 실증과 구분)

- [x] AWS Migration [PR #85](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/85)의 Jenkins `ecr:DescribeImages` 권한 Terraform Apply 완료. 기존 실패 Job 수동 재실행 PASS(Backend `a4d120f` ECR 재사용, Maven 8/8 테스트, GitOps `eee3f3b`, On-Prem Argo CD `Synced/Healthy`). **PR #85는 여전히 Draft/미병합이므로 코드 리뷰 및 Merge 필요.**
- [x] Frontend만 Dockerfile 주석 변경([Application `48d7e15`](https://github.com/neuroplan-hybrid/neuroplan-application/commit/48d7e159f5a9f05f63e5209f2550741ac23bb2db)): Jenkins `Started by an SCM change`, `Frontend changed=true`/`Backend changed=false`, Frontend만 Build/ECR Push, GitOps [`ee462cc`](https://github.com/neuroplan-hybrid/neuroplan-gitops/commit/ee462cc14acb7ac71a95768a774b0bdb167cf0c1) Push, On-Prem Frontend `2/2 Ready`, ECR Digest 일치.
- [x] Backend만 Dockerfile 주석 변경([Application `e5d288f`](https://github.com/neuroplan-hybrid/neuroplan-application/commit/e5d288fa58148551c7ce7dfa923c7b5d6e90464d)): Jenkins `Started by an SCM change`, `Frontend changed=false`/`Backend changed=true`, Maven 8/8, Backend만 Build/ECR Push, GitOps [`9bbe350`](https://github.com/neuroplan-hybrid/neuroplan-gitops/commit/9bbe35025a9639c054cb9cd63f08fc7103f5df17) Push, On-Prem Backend 신규 ReplicaSet `2/2 Ready`, ECR Digest 일치.
- [x] On-Prem Argo CD `Synced / Healthy` revision `9bbe350` 및 Frontend `48d7e15`·Backend `e5d288f` 최신 태그 확인. 테스트용 Dockerfile 주석은 검증 이력으로 보존한다.
- [x] Infra VM에서 HTTPS `/` 200, 비인증 `/api/learning/state` 401, TLS 검증 0 및 사용자 로그인→조회→저장 확인(앞선 Backend `a4d120f` 배포 회차). **최종 `e5d288f` 배포 이후 동일 사용자 기능 재검증과 `dr-health` 200 재확인은 별도 증적 필요.**
- **실증 범위:** SCM 스케줄 `H/2 * * * *`에 따른 자동 실행 확인(실제 Push→시작 소요 초 단위 미측정). On-Prem Pod 롤아웃 완료는 확인했지만 배포 중 요청 연속성·무중단은 미측정. **ROSA Pod·서비스는 아직 검증하지 않았다.**

### 0. 최초 배포 이전 필수 게이트 (예린·희재·정현)

- [ ] 승인된 Terraform **최신 Plan/State/AWS 계정·비용** 확인 후 별도 승인에 따라 Apply; ROSA Worker 3개 Ready, RDS Available 여부 기록(실제 변경 작업 승인 없이 실행 금지)
- [ ] ROSA GitOps Operator/Argo CD 설치 시 `rosa_gitops_application_enabled: false`로 시작; Secret/TLS·네트워크 준비 후에만 Application 활성화(`overlays/rosa`)
- [ ] 최초 ROSA Backend DB는 **On-Prem MaxScale `192.168.44.21:4006/infraready`**, 기존 `ir_app` 재사용(#76). ROSA 전용 On-Prem Grant 신규 생성 없음; RDS 서비스 Writer 전환은 **10/15 별도 승인된 Cutover**에서 수행
- [ ] On-Prem `application/neuroplan-auth-secrets`의 DB 키·`JWT_SECRET_BASE64` 및 `neuroplan-gemini-secrets`를 ROSA `neuroplan`에 **보호된 방식으로 이전**. JWT는 기존 값 유지, Secret 값 노출 금지
- [ ] 희재: ROSA → MaxScale TCP 4006 방화벽 `allow --apply`·`verify`와 TLS Secret `neuroplan-cloud-rosa-tls` 실제 등록/Route `externalCertificate`·Router RBAC·HTTPS 사전검증. **10/7 dry-run·인증서 발급은 실제 ROSA 적용 완료 증거가 아님**
- [ ] `route53_routing_mode=off` 유지. Route 53 전환은 별도 TLS/Health/Plan 게이트와 승인 뒤 진행

### 5-1. 10/12 최신 GitOps 이미지로 ROSA 최초 Smoke Test (예린)

- [ ] 실행 직전 `neuroplan-gitops/main`의 `overlays/rosa/kustomization.yaml` 최신 Revision 확인. **2026-10-09 확인 기준** Frontend `48d7e15` / Backend `e5d288f`, GitOps `9bbe350`. 그 사이 자동 배포로 태그가 바뀌었다면 팀 공유·ECR Digest 재검증·승인을 거쳐 **실제 최신값**으로 계획 업데이트
- [ ] ECR에 두 이미지 존재 확인. 기준 Digest — Frontend `sha256:a8eca0d334537dcdcbcaf67712cc60018fe8d3290fe21c3eb77c140c6bbe1971`, Backend `sha256:5a379cde7eb6906296864cac2ae1b6174ed3f952a4382019731dc87e4460afe0`
- [ ] ROSA 최초 배포에 `overlays/rosa` 적용; `DEMO_WRITE_FENCE=false` 기본 상태 유지(쓰기 차단 미활성)
- [ ] ECR Pull, Frontend·Backend Deployment/Pod Ready, Argo CD `Synced/Healthy`, Route·Service·TLS 확인. 실제 ROSA Pod `imageID` Digest와 ECR 일치
- [ ] **ROSA Pod 관점** MaxScale `192.168.44.21:4006` TCP 연결 및 기존 `ir_app` 인증·조회 성공; 사용자 **로그인 → 조회 → 저장** 정상 및 `DEMO_WRITE_FENCE=false` 쓰기 허용 검증
- [ ] MaxScale에 기록된 **실제** ROSA Source IP를 희재님과 공유(예상 IP를 실측값으로 기록하지 않음)
- [ ] Smoke Test PASS 시각, GitOps/Application SHA, Pod 태그·Digest 및 TLS/DB/서비스 증적 저장. **실패 시 Jenkins를 무조건 재실행하거나 GitOps #12를 수동 Merge하지 말고** Pull/Secret/Router/DB/권한 등 원인을 먼저 분석

### 5-2. 10/12 ROSA 실측·On-Prem 교차 검증 및 변경 발생 시 CI/CD 관리

- [ ] **ROSA 예린:** 최초 ROSA 배포와 Argo CD Sync·Pod Ready, 로그인/조회/저장·Fence `false` 확인 뒤 #33/실행시트에 결과와 SHA 기록
- [ ] **On-Prem 희재:** 최신 이미지 버전·Argo CD `Synced/Healthy` 상태 확인. `ecr-pull-secret` 갱신 게이트 준수 및 `dr-health` 200, Infra VM VIP HTTPS `/` 200, 비인증 `/api/learning/state` 401, TLS `ssl_verify_result=0`·기능 Smoke Test 재검증
- [ ] **양쪽 실제 배포 버전**을 비교. ROSA에서 정상 이미지 Pull·Pod Ready가 검증된 이후에만 'ROSA/On-Prem 동일 버전'으로 기록. k6 기준선·T1/T2도 ROSA 실측 후 수행
- [ ] Jenkins 사전 CI/CD 실증은 10/9 완료했으므로 **10/12 검증을 위해 기능 영향 없는 테스트 커밋이나 Build Now 재실행을 강제하지 않음**. 10/12 이후 실제 코드 변경이 생기면 SCM Polling이 `main`을 감지하여 GitOps `main` Push와 On-Prem 자동 롤아웃까지 유발할 수 있으므로 **팀에 변경 영향·작업 시각·복구 계획 사전 공유 후 승인** 필요
- [ ] 장애가 나면 Jenkins 콘솔(변경 감지/빌드/ECR 권한/이미지 존재 판단/GitOps Push) 및 ROSA·On-Prem Argo CD·Secret·Pod 이벤트를 구분 진단. 기존 ECR Immutable 태그를 덮어쓰거나 GitOps를 Force Push하지 않으며, 변경 필요 시 별도 코드/설정 PR 리뷰 후 재검증
- [ ] Jenkins 빌드 번호, Application/GitOps SHA, ECR 태그·Digest, 두 환경 실측 결과를 연결해 증적을 보관. **On-Prem 성공만으로 ROSA 성공 또는 무중단 배포를 주장하지 않음**

**기존 GitOps PR #12 처리**

- [ ] [GitOps #12](https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/12)는 이전 최초 배포용 Backend `b7deb4a → a4d120f` 변경 PR. **GitOps `main`에는 이미 더 최신인 `e5d288f`가 반영됐으므로 그대로 Merge하지 않는다.** 팀 검토 후 중복·구버전 PR을 Merge 없이 Close할지 별도 승인받아 결정한다. PR 생성/유지만으로 ROSA 배포 완료로 판단하지 않음
- [ ] GitOps #12 정리는 Jenkins 사전 실증 완료 이력과 구분하고, **10/12 ROSA 최초 배포의 승인·Smoke Test 조건을 대체하지 않음**
- [ ] 늦어도 **10/13 T5 Fence 사전 리허설 전** ROSA Fence 포함 최신 Backend의 `false` 쓰기 정상 검증 목표. 미충족이면 리허설 보류·일정 재협의. 검증 없는 DR·DB 승격은 수행하지 않음

### 10/13 T5 사전검증 범위 주의

- `DEMO_WRITE_FENCE=true` 전환은 **실제 DR 시연과 별개 승인·전체 Backend 롤아웃**이 필요하다. 상태 변경 API/로그인 및 내부 쓰기 GET 요청의 503, 순수 조회/Health 유지 여부를 검증하고 안전하게 원복한다.
- **10/13 Fence 리허설 = 전체 T5 ROSA→On-Prem DR 전환 완료가 아니다.** 실제 DB 복제 catch-up·Writer 승격·DNS/Health 전환·RTO/RPO·정합성 검증은 이후 런북의 승인 게이트에 따른다.

## 데이터 전환 흐름 (정현)
`On-Prem → RDS 초기 Import·GTID 복제 → catch-up·Lag 확인 → Cutover 승인 → RDS Writer 전환 → RDS → db-primary·db-replica 역복제`
- 실제 Import·GTID 실행은 **10/12 운영 RDS Available 이후**

## Health Endpoint·RTO 측정 기준
| 구분 | 기준 |
|---|---|
| Liveness | `/actuator/health/liveness` |
| Readiness | `/actuator/health/readiness` |
| Route 53 Health Check | `/actuator/health/routing` |
| Control RTO | `probe_1006.sh` (#50) — 장애 주입 **`T_inject` → 권한 DNS 응답 변경 확인 `T_dns`** (T5 주 지표) |
| User RTO·연속성 | k6 (#56) — 장애 주입 **`T_inject` → 로그인→조회→저장 30초 연속 성공 구간 시작 `T_user`** (T5 주 지표); 연속성 실패 요청 수는 별도 기록 |

## 10/12 ImagePullBackOff 대응 (A+B 확정)
**A — 필수 실행 순서**
1. VM 부팅
2. `ecr-pull-secret` 갱신 Job 실행 및 성공 확인
3. Secret·Backend·Frontend Pod 상태 확인
4. GitOps Sync 또는 필요한 Pod 재생성
5. ECR 이미지 / `Pulled` 이벤트 / Pod Running / `/actuator/health/routing` 200 확인
- 1~3 통과 전에는 온프렘 Sync·재배포하지 않음
- 이미 `ImagePullBackOff`가 발생한 Pod는 Secret 갱신 후 해당 Pod만 삭제해 재생성

**B — GitOps** (gitops #6 Merged)
- On-Prem DR Backend·Frontend만 `imagePullPolicy: IfNotPresent`, base·ROSA 유지
- 커밋 SHA 기반 불변 태그(ECR `IMMUTABLE`) → 캐시 재사용 목적
- 새 Worker·새 Pod는 캐시가 없어 ECR 인증 필요 → **B는 A를 대체하지 않음**

## 10/13 Route 53 완료 조건
아래를 모두 통과하기 전까지 **`route53_routing_mode = "off"` 유지**
- [ ] ROSA Ingress LB 종류 확인 (NLB가 아니면 `primary_lb_zone_id`도 입력, [feat: edge 모듈 추가 (DR NLB, Route 53 Weighted/Failover 레코드·헬스체크) #28] (가))
- [ ] `dr-health`·`primary-health`의 `/actuator/health/routing` 200
- [ ] ROSA TLS preflight 통과: OpenShift 4.20.40 · Route `externalCertificate` · Router 최소 RBAC · 외부 HTTPS SAN/Issuer
- [ ] ROSA LB DNS 확인 → tfvars PR 작성 (희재)
- [ ] 최종 Terraform Plan 확인 → 리뷰·Merge
- [ ] 지정 실행자(예린) plan / apply
- [ ] Weighted 온프렘 100 / ROSA 0 상태 확인
- [ ] primary-health / dr-health 헬스체크 2개 정상
- [ ] `dig +short app.neuroplan.cloud @8.8.8.8` 결과가 DR NLB IP(`dig +short <DR NLB DNS>`)와 같은지 확인

## 10/16 장애 시연 (발표 기준, #55 대체)
| # | 시나리오 | 담당 |
|---|---|---|
| T1 | Worker/Pod 연속성 | 예린 |
| T2 | Deployment Safety | 예린 |
| T3 | RDS PITR (P1) | 정현 |
| T4 | VPN 단일 터널 장애 | 희재 |
| T5 | ROSA → On-Prem DR 전환 | 희재 + 정현 |
| T6 | Failback 절차 설명 (런북, 실제 시연 제외) | 정현 + 희재 |
| T7 | **인증서 CA 전환 무중단 검증** (On-Prem TLS, 별도 승인·A/B 범위, 실제 리허설 미실시) | 희재, 시연 범위·일정 별도 확정 |

> #55 본문의 과거 T1~T8(RDS Multi-AZ 포함)은 사용하지 않음. **기존 DR 중 온프렘 LB/keepalived 전환은 T7이 아니라 별도 Appendix/P2**로 관리. T7 현재 런북은 `docs/runbooks/cert_ca_switch_continuity_1008.md`(AWS Migration PR #78).

## 10/16 destroy
- [ ] 선행 조건 (모두 체크 후 시작)
  - [ ] 시연 녹화본 저장
  - [ ] RTO/RPO 측정 결과 저장
  - [ ] GTID·복제 상태 증적 저장
  - [ ] Cost Explorer 캡처
  - [ ] RDS 최종 스냅샷 이름 확인 (현재 `skip_final_snapshot=false`, 이름 `neuroplan-rds-operation-final-20261020` 고정 → 같은 이름 스냅샷이 이미 있으면 destroy 실패)
- [ ] Terraform으로만 destroy (rosa CLI·콘솔로 지우지 않음 → state 불일치 방지)
- [ ] destroy 후 잔존 리소스 확인 (DR NLB·TG·SG·퍼블릭 IPv4·NAT)
- [ ] 최종 비용은 destroy 다음 날 이후 Cost Explorer로 다시 확인 (반영 지연), 최종 스냅샷은 10/20에 삭제

## 비용 기준
- ROSA Worker **m5.xlarge × 3** 확정 → 현재 추정치와 Cost Explorer 실측으로 판단
- Cost Explorer 누적 상한 **$500**

| 시점 | 진행 조건 |
|---|---|
| 10/12 apply 전 | 누적 ≤ **$230** |
| 10/15 저녁 | 누적 ≤ **$430** |
| 누적 ≥ $480 | 즉시 중단, 필수 증적만 확보 후 destroy |

## P1 후속 검토 (Go/No-Go 차단 조건 아님)
**10/8 정현님 최종 댓글의 범위로 정리**. 10/12 생성·10/15 Cutover·10/16 DR 시연이 우선이며 관측은 비차단 P1로 진행한다.
- RDS 기본 자동 백업·PITR 보존 기간/복원 증적 확인. **AWS Backup 장기 보관 별도 도입 제외**
- 운영 RDS 생성 후 **CloudWatch Alarm 상태 확인 + Grafana CloudWatch 데이터소스 연계 우선, SNS 연동 제외**
- 기존 On-Prem Blackbox Exporter에 `app`·`primary-health`·`dr-health` 등록(정현), Prometheus/Grafana 수집 확인. 외부 URL/Route 53 전환 후 접근 확인은 희재 협업
- CloudWatch Synthetics API Canary는 테스트 계정 세션·비용 부담으로 **P2 보류**

## 관련 및 리뷰 반영
- AWS Migration: #22, #28, #32, **#33**, #47~#50, #52, #55, #56~#62, **#76**(DB/VPN/TLS), **#75**(Cutover 후 RDS 계정 PR), **#77·PR #78**(T7 CA), **#79·#80**(On-Prem HTTPS), **#81·PR #82**(T5 Fence 런북)
- GitOps: **#6**(On-Prem IfNotPresent), **#10**(ROSA Fence 기본 `false`, Merged), **#11**(On-Prem HTTPS HTTPRoute, Merged), **#12**(이전 Backend `a4d120f` 지정, Open/미병합·현재 최신 `e5d288f`로 대체되어 리뷰 후 정리)
- Application: **#6**(Fence 구현, Merged), **#7**(RDS Secret 갱신 중 JWT 유지, Merged)
- 실행 가이드: 10/12 ROSA P0 구축 실행 가이드(기준일 10/8); 본 문서는 #33 일정·담당·Gate의 버전 관리본이며 해당 가이드 및 T5/T7 런북을 대체하지 않음
