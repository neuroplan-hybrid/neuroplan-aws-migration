# ROSA 구축 완료 후 통합 DR 검증 체크리스트 및 증적 기록 양식

> 상태: **후속 검증 계획 / 아직 실행 결과 아님**
> 작성: 2026-10-09 · 적용 시점: ROSA 서비스 구축·배포 준비 완료 후, T5 리허설 전
> 목적: ROSA 운영 서비스 ↔ On-Prem DR 연동을 검증하고, 실제 결과에 따라 T5 런북을 보완한다.
> 이 문서는 [T5 실제 실행 런북](site_dr_rosa_to_onprem_1008.md)을 **대체하지 않는다.** 실험 주입·DNS 변경·DB 승격을 이 문서만 보고 실행하지 않는다.

## 1. 범위와 진행 조건

- 사전 구축 완료 여부(Listener/HTTPRoute)는 [On-Prem HTTPS 사전 구축 가이드](onprem_https_preflight_1009.md)에서 확인한다.
- ROSA가 준비된 뒤 확인할 핵심은 **운영 이미지·Write Fence 동작**, **양쪽 트래픽 경로**, **DB 복제·승격 게이트**, **Route 53/HC 전환**, **실제 Control/User RTO 및 데이터 정합성**이다.
- **ROSA 구축 자체와 On-Prem HTTPS 사전 준비는 병행 가능**하지만, 최종 T5 DR 전환·복구 시연은 모든 필수 게이트를 충족한 후 별도 승인된 일정에 진행한다.
- T7 인증서 CA 전환은 [T7 전용 런북](cert_ca_switch_continuity_1008.md)의 A/B 범위로 별도 판정한다. ROSA 구축 완료가 T7 On-Prem 인증서 테스트의 직접적인 선행 조건은 아니다.

## 2. ROSA 운영 준비 검증 (아직 미실측)

| 항목 | 확인 내용 | 예상 증적 | 상태 |
|---|---|---|---|
| ROSA 클러스터/접속 | 대상 클러스터·Namespace·Operator/Route 상태 | 컨텍스트, Namespace, Route 상태 | 미검증 |
| ROSA Argo CD | 실제 Application, Git repo/branch/path, Auto-Sync/selfHeal/prune, Revision | Application spec/status | 미검증 |
| Frontend·Backend | 실제 이미지 digest/tag 및 Pod Ready | Deployment/Pod 이미지·Ready 캡처 | 미검증 |
| 사용자 정상 흐름 | ROSA 경유 로그인·조회·저장 성공 | 응답 및 k6 기준선 | 미검증 |
| 네트워크/Health | NLB/ROSA Route/상태 확인, DB 연결 | Health Check·로그 | 미검증 |
| 장애 전환 기준 | T5 시작 전 운영 주소·HC·권한 DNS 실측 | 상태 스냅샷 | 미검증 |

**ROSA와 On-Prem의 kubectl 컨텍스트를 혼동하지 않도록** 모든 명령 실행 시 클러스터·Namespace를 먼저 출력하고, 민감 정보·실제 자격증명은 증적에서 제외한다.

조회 위주의 예시(환경에 맞는 인증/컨텍스트를 확보한 뒤 실행):

```bash
kubectl config current-context
kubectl get namespaces
kubectl -n neuroplan get deployments,pods
kubectl -n neuroplan get configmap neuroplan-backend-config -o jsonpath='{.data.DEMO_WRITE_FENCE}{"\n"}'
kubectl -n neuroplan get deploy neuroplan-backend -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
```

위의 namespace/리소스 이름은 현재 GitOps ROSA overlay 설계를 기준으로 한 예시다. **조회 결과를 기록하기 전에는 구축 완료로 체크하지 않는다.**

## 3. Write Fence: 코드·이미지·롤아웃 일치 확인 (T5 핵심)

관련: [GitOps PR #10](https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/10), [AWS Migration #74](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/issues/74), [애플리케이션 PR #6](https://github.com/neuroplan-hybrid/neuroplan-application/pull/6).

### 3.1 기능 포함 Backend 이미지

- GitOps ROSA overlay에 기록된 Backend 태그는 10/8 확인 기준 **`b7deb4a`**였다. 이 이미지에 병합된 Fence 구현이 들어 있는지 **아직 검증되지 않았다**.
- 코드 PR이 병합되었다는 사실만으로 **ECR 이미지 갱신·운영 Pod 적용 완료를 의미하지 않는다**.
- 필요 시 별도의 이미지 빌드/배포 및 GitOps 태그 변경 PR로 검증된 digest를 고정한다.
- 실제 Pod image ID/digest 및 앱의 Fence 분기 동작을 기록한다. 태그만 같다고 동일 이미지라고 단정하지 않는다.

### 3.2 `false` 기본값 확인

- GitOps PR #10의 `DEMO_WRITE_FENCE: "false"`는 **기본값 구성**이다. T5 장애 시 쓰기 차단을 활성화한 상태가 아니다.
- ConfigMap은 Deployment의 `envFrom`으로 전달되므로 **이미 실행 중인 Backend Pod에는 ConfigMap 변경만으로 환경변수가 즉시 바뀌지 않는다.**
- `false` 기본 배포/롤아웃과 ROSA 정상 사용자 흐름을 확인한다.

### 3.3 `true` 전환 시 실제 차단 범위 확인

- **중요: 로그인도 쓰기를 수행할 수 있음.** 애플리케이션 Write Fence 구현은 로그인·토큰 갱신·로그아웃 등 내부 쓰기 경로를 503 처리할 수 있으므로, **'Fence=true에서도 로그인 정상'을 사전 성공 기준으로 고정하면 안 된다.**
- T5 기존 [런북](site_dr_rosa_to_onprem_1008.md)은 일부 표에서 `로그인·조회 정상`을 가정하고 있어 **실제 Backend 구현 및 QA 결과에 맞춰 수정할 필요가 있다**.
- `true` 적용 → 승인된 GitOps 변경/Sync → **Backend 전체 Pod 롤아웃** → 모든 Pod의 환경변수/Ready 확인 → 상태 변경 API 503, 로그인·refresh·logout 등 실제 차단 대상 응답, 읽기 전용 API/Health 영향 확인.
- 읽기 요청처럼 보이더라도 내부에서 쓰기를 발생시키는 API는 차단 대상일 수 있다. 테스트 대상·예외 API를 정현님과 최종 합의한다.
- **복제 catch-up·DB 승격 전에** 기존 ROSA Writer로 들어가는 모든 쓰기 경로 차단 완료를 확인한다. Fence 활성화 결과가 불충분하면 DB 승격을 진행하지 않는다.
- **DR 운영 중에는 Fence 유지**; Failback 때 Writer 및 트래픽 전환 안전성이 확인된 뒤 별도 승인 아래 `false`로 되돌린다.

| 테스트 항목 | 기대/확인 방법 | 상태/실측 |
|---|---|---|
| 설정 변경·전체 Pod 롤아웃 | 모든 Backend Pod에 `true` 반영, Ready | 미검증 |
| 주요 상태 변경 API | HTTP 503, DB 변경 없음 | 미검증 |
| 로그인/refresh/logout | 구현·QA로 503 여부 확정, 결과 기록 | 미검증 |
| 읽기 전용 경로 | 실제 읽기 동작·예외 경로 구분 | 미검증 |
| Routing/Readiness | HC 기대값 유지 여부 확인 | 미검증 |
| Fence 해제(원복 시점) | 정합성 및 Writer 재확정 후 별도 승인 | 미검증 |

## 4. On-Prem DR 진입 경로 사전 재검증

필수 조건:
- 희재님 `https-public-app` Gateway Listener 실제 적용·`verify` PASS
- GitOps PR #11 반영 및 HTTPRoute parent 상태 확인
- Infra VM에서 VIP `192.168.24.100` 대상으로 인증서 검증을 **끄지 않은** HTTPS 요청

| 체크 | PASS 기준 | 상태 |
|---|---|---|
| Gateway | `Accepted=True`, `Programmed=True`, `ResolvedRefs=True` | 미검증 |
| HTTPRoute | 신규 parent `Accepted=True`·`ResolvedRefs=True` | 미검증 |
| Frontend | `/` → HTTP 200, `ssl_verify=0` | 미검증 |
| Backend | 비인증 `/api/learning/state` → HTTP 401, `ssl_verify=0` | 미검증 |
| 기존 경로 | `app.nplan.local` 및 `dr-health` 영향 없음 | 미검증 |

실제 DNS는 바꾸지 않는다. **cp1(root)의 `verify`/`verify-route`는 NGF NodePort (`VERIFY_IP=192.168.34.41`, `VERIFY_PORT=30443`) 직접 경로로 확인**하고, **Infra VM에서는 `curl --resolve`로 VIP `192.168.24.100:443`을 지정해 HAProxy/VIP 경유 HTTPS를 별도로 검증**한다. 상세 순서와 검증 기준은 [사전 구축 가이드](onprem_https_preflight_1009.md) 및 [PR #79 스크립트](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/79)를 따른다.

## 5. T5 DR 전환 통합 검증 게이트

[T5 런북](site_dr_rosa_to_onprem_1008.md)의 순서를 우선하며, 담당자 간 **실제 운영 변경 승인**이 완료된 회차에만 실행한다.

| 단계 | 사전 조건 / 검증 포인트 | 담당·증적 | 상태 |
|---|---|---|---|
| 운영 기준선 | ROSA 사용자 요청 성공, DNS/HC/NLB 상태 | 희재·공동 / k6·probe | 미검증 |
| 쓰기 차단 | Fence=true, **전체 Backend Pod** 반영, 차단 대상 503 확인 | 정현·예린 / Pod·HTTP·DB 로그 | 미검증 |
| 데이터 복제 | GTID 연속성, IO/SQL 상태, Lag=0 등 T5 런북 게이트 충족 | 정현 / DB 증적 | 미검증 |
| DR Writer 승격 | 복제 게이트 충족·승인 후 db-primary 승격 및 제한 쓰기 확인 | 정현 / DB 증적 | 미검증 |
| DNS/HC 장애 주입 | 승인된 HC/DNS 전환, 권한 DNS 응답 확인 | 희재 / probe·HC | 미검증 |
| DR 서비스 복구 | On-Prem에서 로그인→조회→저장 연속 성공 확인 | 공동 / k6 CSV | 미검증 |
| Failback | 승격 상태·Writer·복제 역전환 확인 후 DNS/Fence 해제 | 공동 / 런북 증적 | 미검증 |

**중단/롤백:** T5 런북의 **승격 전(5.1) / 승격 후(5.2) 분기**를 반드시 구별한다. 특히 승격 후에는 DNS 또는 Fence만 단독 원복하지 않는다. GTID/복제/승격 조건 미충족 시 다음 단계로 진행하지 않는다.

## 6. 복구 시간 및 정합성 기록

- **Control RTO**: 장애 주입 `T_inject` → 권한 DNS의 On-Prem 응답 전환 확인 `T_dns`.
- **User RTO**: 장애 주입 `T_inject` → k6의 **로그인→조회→저장 30초 연속 성공 구간 시작** `T_user`.
- **데이터 전환 시간**: 쓰기 차단 시작 `T0` → 온프렘 Writer 승격 `T_promote`. **RTO와 별도** 표기한다.
- **데이터 정합성**: GTID 및 복제 상태, 승격 전후 쓰기·재조회 증적, 손실·중복·충돌 여부 확인. 결과 없이는 RPO=0 또는 정합성 성공이라고 주장하지 않는다.
- **서비스 연속성**: k6 실패 건수·연속 실패 구간·Health Check 결과를 별도로 기록한다. Write Fence 활성화 중 기존 ROSA 로그인/쓰기 실패와 DR 전환 후 복구 판정을 혼합하지 않는다.

| 시각/지표 | 값 | 로그/증적 |
|---|---|---|
| `T_sync` (Fence 반영) | 미측정 | |
| `T_rollout` (Backend 전체 롤아웃) | 미측정 | |
| `T0` (Fence 확인) | 미측정 | |
| `T_promote` (DB 승격) | 미측정 | |
| `T_inject` (장애 주입) | 미측정 | |
| `T_dns` (권한 DNS 전환 확인) | 미측정 | |
| `T_user` (30초 연속 성공 구간 시작) | 미측정 | |
| Control RTO | 미측정 | |
| User RTO | 미측정 | |
| 데이터 전환 시간 | 미측정 | |
| DB GTID/복제/마지막 쓰기 검증 | 미검증 | |

모든 측정 결과는 **실행 호스트, 시간대, 실제 Git SHA·Pod 이미지 digest, 테스트 계정 범위(비밀정보 제외), 명령 결과 또는 증적 링크**와 함께 기록한다.

## 7. ROSA 구축 후 수정할 문서/설정

- [ ] ROSA Argo CD 실제 Application·Auto-Sync 및 배포 정책 확정
- [ ] GitOps PR #10 Merge·반영 상태 확인, Backend Fence 구현 이미지/태그 검증
- [ ] T5 런북의 **Fence=true 로그인 정상 가정**을 실제 구현·QA에 맞춰 정리
- [ ] ROSA 경유 운영 테스트의 k6 시나리오 및 테스트 계정 준비
- [ ] Route 53/HC·NLB·VPN 경로 실측 및 전환 전제 업데이트
- [ ] DB 복제 catch-up·Writer 승격·중단 분기 실측 기록
- [ ] T5 리허설 결과에 따라 지표(별도 RTO·데이터 전환 시간·정합성) 및 실패/원복 절차 보완
- [ ] T7 A/B 인증서 전환 결과는 **별도 런북**에 기록 (B는 TLS 전용)

## 8. 리뷰 요청 및 증적 수집 현황

| 역할 | 확인 요청 | 상태 |
|---|---|---|
| 정현 | Backend Fence API 범위, 로그인·세션 부작용, DB 승격 게이트 | 요청 전 |
| 희재 | ROSA/DR DNS·HC·NLB 동작, Control/User RTO 측정 절차 | 요청 전 |
| 예린 | ROSA GitOps 자동 배포 정책, Backend 이미지와 Pod 롤아웃, On-Prem HTTPRoute | 요청 전 |
| 공동 | 리허설 일정·장애 주입 승인·Failback 시점 및 증적 담당 | 요청 전 |

> **현재 검증 완료로 표시된 T5 항목은 없다.** 이 문서는 ROSA 구축 후 사용할 체크리스트이며, 증적 없는 완료 표시·숫자 기입·'무중단' 또는 'RPO=0' 주장 금지.
