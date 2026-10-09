# ROSA 가동 일정·10/12 P0 구축 및 Jenkins CI/CD 실행 체크리스트

> **#33 최신화 제안본 (2026-10-09)** — [AWS Migration Issue #33](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/issues/33)의 일정·담당·비용 기준을 유지하면서, [Issue #76의 ROSA P0 DB·VPN·TLS 협의 결과](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/issues/76)와 GitOps #12 리뷰에서 합의된 단계적 배포를 반영한 버전 관리용 문서이다.
> **PR Merge가 Issue #33 본문을 자동 수정하지는 않는다.** 리뷰·병합 후 #33 본문에서 본 문서로 연결하거나 최신 핵심 체크리스트를 반영한다.
> 이 문서는 **실행 계획**이다. ROSA/Terraform Apply, Secret 전송, Jenkins 실행, Route 53 전환, DB Cutover, T5·T7 리허설은 아직 이 문서만으로 완료·승인됐다고 판단하지 않는다.

## 개요
PR #32(ROSA 가동·비용 최적화 결정)에 따른 ROSA 가동 일정과 담당별 체크리스트입니다.
**10/8 Go/No-Go 결정 및 10/9 후속 합의 반영본**입니다. 기존 #33 일정·비용 결정은 유지하고 10/12 실제 배포 게이트를 구체화합니다.

## 핵심 결정 (3명 합의)
- ROSA는 **10/12에 1회 생성 → 10/16까지 5일 연속 가동**, 10/16 당일 destroy (주말 연장 없음)
- 10/12는 생성뿐 아니라 **기존 Backend 최초 배포·Smoke Test → 조건 충족 시 Jenkins CI/CD → 동일 Smoke Test 반복**까지 진행한다. 이후 통합·전환 사전 검증 → Cutover → DR 검증·종료 순서를 유지한다.

## 일정
| 날짜 | 단계 | 내용 |
|---|---|---|
| 10/2~10/5 | OFF | VPN·DR NLB만 유지 |
| 10/6~10/7 | 준비 | 담당별 사전 준비 (아래 체크리스트) |
| **10/8** | **Go/No-Go** | 이 문서 기준 판정, 10/12 실행 순서 확정 |
| 10/9~10/11 | 학원 불가 | 문서·코드 작업만 |
| 10/12 | Day 1 | ROSA·운영 RDS·NAT 생성, `b7deb4a` 최초 배포·Smoke Test → Jenkins CI/CD 조건부 실행·양쪽 이미지 검증, 데이터 초기 Import·GTID 복제 착수(RDS Available 이후) |
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
- [x] ECR `neuroplan-backend:a4d120f` 존재 확인(사용자 10/9 AWS 조회, digest `sha256:c9dfaabd54e556b874f25f3f79c03513e9363e2a915c57d31fb304949e82c70c`)
- [x] GitOps #12 `b7deb4a → a4d120f` PR 생성·Approve (미병합; **Jenkins 배포 성공 시 중복 변경 방지를 위해 Merge하지 않고 Close할지 결정**)
- [ ] **10/12 실제 Jenkins 변경 감지·배포, ROSA/On-Prem 실측 및 커밋 SHA 기록** (미실행)

### 정현 (데이터)
- [x] NFS 논리백업본 경로·대상 DB(infraready)·Import 검증 명령 확정 (SHA-256·`gzip -t`, dump GTID 기준)
- [x] 운영 RDS Endpoint / Master Secret ARN → Ansible이 RDS 식별자로 AWS에서 조회
- [x] On-Prem → RDS GTID 복제, RDS → db-primary·db-replica 역복제 Runbook/Ansible 실행 순서 확인 (#57, #58)
- [x] Cutover 전·후 확인 기준 정리 (GTID, IO/SQL Running, Lag, Row Count, 쓰기 후 재조회)
- [x] Health Endpoint 확인: `/actuator/health/liveness`, `/actuator/health/readiness`, `/actuator/health/routing`

## ROSA 5일 시간표
| 날짜 | 단계 | 내용 |
|---|---|---|
| 10/12 | 구축·첫 검증 | ROSA·RDS·NAT 생성, GitOps·Secret/TLS·앱 `b7deb4a` 최초 배포·Smoke Test → 승인된 Jenkins CI/CD로 Backend 버전 통일 시도·재검증; NFS Import/GTID 착수는 RDS Available 이후 데이터 담당 병행 |
| 10/13 | 통합 | 10/12 결과 재확인, ROSA TLS preflight, Route 53 tfvars apply(조건 충족 시), 헬스체크, **Fence=true 503 범위 사전검증(별도 승인 및 원복, 전체 T5 DR 전환 아님)** |
| 10/14 | 전환 사전검증 | GTID catch-up, Weighted 10/90 → 50/50 |
| 10/15 | Cutover | DB Cutover, 역복제, 저녁 진척·비용 판단 |
| 10/16 | DR·종료 | 장애 시연 T1~T6, RTO/RPO, 18:00 destroy 시작 |

## 10/12 ROSA P0 단계적 배포·Jenkins 실행 게이트 (5-1 → 5-2)

**합의된 변경:** GitOps #12를 즉시 Merge하는 대신, 10/12 ROSA의 기존 이미지 Smoke Test 후 **Jenkins AWS CI/CD로 ROSA·On-Prem DR Backend 이미지 태그를 함께 갱신**하는 방식을 우선한다. 실패·변경 미감지 등으로 자동 갱신을 할 수 없으면 팀 승인하에 **#12 Merge 경로로 복귀**한다. Jenkins 경로 성공 전에 #12를 Close하지 않는다.

### 0. 최초 배포 이전 필수 게이트 (예린·희재·정현)

- [ ] 승인된 Terraform **최신 Plan/State/AWS 계정·비용** 확인 후 별도 승인에 따라 Apply; ROSA Worker 3개 Ready, RDS Available 여부 기록(실제 변경 작업 승인 없이 실행 금지)
- [ ] ROSA GitOps Operator/Argo CD 설치 시 `rosa_gitops_application_enabled: false`로 시작; Secret/TLS·네트워크 준비 후에만 Application 활성화(`overlays/rosa`)
- [ ] 최초 ROSA Backend DB는 **On-Prem MaxScale `192.168.44.21:4006/infraready`**, 기존 `ir_app` 재사용(#76). ROSA 전용 On-Prem Grant 신규 생성 없음; RDS 서비스 Writer 전환은 **10/15 별도 승인된 Cutover**에서 수행
- [ ] On-Prem `application/neuroplan-auth-secrets`의 DB 키·`JWT_SECRET_BASE64` 및 `neuroplan-gemini-secrets`를 ROSA `neuroplan`에 **보호된 방식으로 이전**. JWT는 기존 값 유지, Secret 값 노출 금지
- [ ] 희재: ROSA → MaxScale TCP 4006 방화벽 `allow --apply`·`verify`와 TLS Secret `neuroplan-cloud-rosa-tls` 실제 등록/Route `externalCertificate`·Router RBAC·HTTPS 사전검증. **10/7 dry-run·인증서 발급은 실제 ROSA 적용 완료 증거가 아님**
- [ ] `route53_routing_mode=off` 유지. Route 53 전환은 별도 TLS/Health/Plan 게이트와 승인 뒤 진행

### 5-1. 기존 이미지로 ROSA 최초 Smoke Test (예린)

- [ ] ROSA Backend **`b7deb4a`**, Frontend **`bcc6857`** GitOps `main` 기준으로 최초 배포(ROSA Fence ConfigMap 기본값은 `false`)
- [ ] ECR Pull, Frontend·Backend Pod/Deployment Ready, Route·Service·TLS 확인
- [ ] **ROSA Pod 관점** MaxScale `192.168.44.21:4006` TCP 연결 및 기존 `ir_app` 인증·조회 성공; 사용자 **로그인 → 조회 → 저장** 성공
- [ ] MaxScale에 기록된 실제 ROSA Source IP를 희재님과 공유(예상 IP를 실측값으로 기록하지 않음)
- [ ] 첫 Smoke Test PASS 시각·Pod 이미지 태그/다이제스트·증적 저장. **실패하면 Jenkins·#12 Merge를 진행하지 않고 원인부터 분리**

### 5-2. Jenkins AWS CI/CD로 버전 통일 (합의된 우선 경로)

**실행 전 Gate — 예린, 희재 및 팀 승인**

- [ ] On-Prem VM 기동 후 **`ecr-pull-secret` 갱신 Job 성공**, Secret·Backend·Frontend Pod 상태 확인(기존 #33 A+B 게이트)
- [ ] Jenkins 사용 Job이 실제 `Jenkinsfile.aws`를 참조하는지 확인. 이전 성공 빌드의 커밋·현재 Application `HEAD`·Backend 경로 변경분을 **읽기 전용으로 비교**해 `BACKEND_CHANGED=true` 예상 여부 확인
- [ ] 예정 이미지 태그/이미 ECR에 존재하는 태그·GitOps `main` 최신 Revision 확인. `a4d120f` 등 기존 태그가 ECR에 있으면 **Build/Push는 생략될 수 있어도 GitOps 갱신은 진행 가능**. `BACKEND_CHANGED=false`면 무리하게 커밋을 만들어 강제하지 않고 아래 대안 사용
- [ ] **GitOps `main` 직접 Push → On-Prem DR Argo CD Auto-Sync/Pod 재배포 가능**을 팀 채널에 사전 공지하고 담당자·작업 시각·롤백 방안 합의 및 실행 승인 확보
- [ ] ROSA Argo CD Auto-Sync 및 대상 경로 `overlays/rosa` 확인. 현재 서비스 사용 중인 환경·테스트 계정/쓰기 영향 점검

**승인 후 Jenkins 실행 및 결과 확인**

- [ ] `BACKEND_CHANGED=true`가 확인된 승인 회차에 Jenkins 실행. 실제 단계별 `Test Backend`·ECR 이미지 존재 조회·(필요 시) 빌드/Push·GitOps `rosa`/`onprem-dr` 이미지 태그 변경·GitOps `main` Push 성공 확인
- [ ] Jenkins Job/빌드 번호, Application SHA, ECR 태그·다이제스트, GitOps 새 커밋 SHA를 기록. **Jenkins 실행 자체만으로 이미지 통일 성공 선언 금지**
- [ ] **ROSA 예린:** Argo CD Sync·Backend 전체 롤아웃·Pod Ready 확인 후 5-1과 동일 Smoke Test 반복. `DEMO_WRITE_FENCE=false` 상태에서 **로그인·조회·저장 정상 및 쓰기 허용** 확인
- [ ] **On-Prem 희재:** Argo CD Sync·Backend Pod Ready, `dr-health` HTTP 200, Infra VM VIP 직접 HTTPS `/` 200, 비인증 `/api/learning/state` 401, TLS `ssl_verify_result=0` 재검증
- [ ] **양쪽 실제 실행 이미지 태그·다이제스트** 확인하여 버전 일치 여부 기록. ROSA/On-Prem 검증 PASS 후 k6 기준선·T1/T2는 **새 이미지** 기준 측정

**Jenkins 우선 경로 실패/미실행 시 대안 및 #12 종료 기준**

- [ ] `BACKEND_CHANGED=false`/Jenkins 실패/배포 영향 승인 미완료 시 **#12는 유지**, 원인 및 결과 기록; 승인된 **#12 Merge → ROSA Sync·롤아웃·Smoke Test** 경로 사용(이 경우 On-Prem이 기존 태그일 수 있으므로 '동일 버전 Warm Standby'라고 주장하지 않음)
- [ ] Jenkins가 **양쪽 이미지 갱신·검증에 실제 성공**하고 #12가 중복 변경임을 확인한 다음에만 **#12 Merge 없이 Close**(별도 확인 후 수행). 실패·중단 상태에서 임의 Close 금지
- [ ] 늦어도 **10/13 T5 Fence 사전 리허설 전**에는 ROSA의 Fence 포함 이미지 배포·`false` 정상 쓰기 검증을 완료하도록 계획(미충족 시 리허설 보류)

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
- GitOps: **#6**(On-Prem IfNotPresent), **#10**(ROSA Fence 기본 `false`, Merged), **#11**(On-Prem HTTPS HTTPRoute, Merged), **#12**(Backend 태그 변경, Approved/Open·Jenkins 결과에 따라 판단)
- Application: **#6**(Fence 구현, Merged), **#7**(RDS Secret 갱신 중 JWT 유지, Merged)
- 실행 가이드: 10/12 ROSA P0 구축 실행 가이드(기준일 10/8); 본 문서는 #33 일정·담당·Gate의 버전 관리본이며 해당 가이드 및 T5/T7 런북을 대체하지 않음
