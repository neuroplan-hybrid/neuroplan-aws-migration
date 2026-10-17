# T2 Deployment Safety — Readiness 실패 주입·GitOps 복구 재시연 결과 (2026-10-16)

## 재시연 배경 — Grafana 통합 대시보드 증적 보완

2026-10-15 T2의 **Readiness 실패 Pod 트래픽 제외·기존 정상 Pod 유지·k6 연속성 검증은 관측 범위 내 PASS**였다. 그러나 **두 Grafana 대시보드 코드를 통합한 뒤** T2 '기존·신규 Pod Ready 변화' 패널에서 `Data does not have a time field` 표시와 ReplicaSet 변수 선택값 중복이 보고되어, 장애 전·중·후의 모니터링 지표를 명확하게 제시하기 어려웠다.

- **보고된 증상:** 기존·신규 RS 선택값이 모두 `neuroplan-backend-db8bd9bb5`로 표시된 것으로 이전 대시보드 점검 내용에 기록되어 있다. 이 값은 **Grafana 변수에 나타난 표시값에 대한 보고**이지, 10/16 T2에서 Kubernetes로 확인한 ReplicaSet 이름이 아니다. **해당 화면 캡처·대시보드 JSON·원본 설정의 링크는 현재 PR에 없어 출처와 발생 시각을 독립 검증하지 못했다.**
- **10/16 실측 비교 대상:** 기존 정상 RS `neuroplan-backend-584495dbb6`와 신규 실패 RS `neuroplan-backend-bf4b9d995`는 공유된 Kubernetes `oc` 출력으로 구분했다.
- **해석과 조치 범위:** 시계열 패널의 시간 필드 오류 및 변수 매핑을 점검할 필요가 있었으나, **Range/Instant·Transformation 등 구체 원인과 Grafana 수정 완료 여부는 확정하지 않는다.** 두 대시보드 코드 통합이 직접 원인이었다는 점도 독립 입증되지 않았다.

이러한 **Grafana 증적 보완 목적**으로 2026-10-16 T2를 재시연했다. Kubernetes의 Readiness 보호 동작·GitOps 수동 원복 및 k6 **로그인 1/1·조회 434/434·저장 434/434 성공**은 확인·보고됐지만, Grafana 화면의 최종 수정과 Before/During/After 캡처 확보는 **별도 검증 대상**이다. 10/15 시험이 실패해 재시연한 것은 아니다.

**문서 관리:** **10/16 재시연을 현재 대표 T2 결과로 사용**하며, [10/15 실측 결과](./t2_deployment_safety_1015.md)는 삭제하지 않고 이전 실행 이력으로 보존한다([원본 병합 PR #125](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/125)). 같은 날 수행한 [T1 재시연 #137](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/137)은 별도의 시험이다.

> **최종 판정: PASS (관측·k6 측정 범위 내).** ROSA Backend의 신규 ReplicaSet에만 의도적으로 잘못된 Readiness Probe 경로를 반영했다. 기존 정상 RS 2/2 Ready를 유지하는 동안 신규 RS 0/1 Ready 및 EndpointSlice `ready=false`를 확인했고, GitOps 원복 후 실패 RS 0/0/0·Backend 2/2·Argo CD Synced/Healthy로 돌아왔다. Infra VM의 k6 상세 분석 결과는 로그인 1/1·조회 434/434·저장 434/434 모두 성공, 응답 HTTP 200, 실패 상세 없음(**정현 담당자 보고 기준**)이다.
>
> **중요:** **불량 컨테이너 이미지 배포 시험이 아니다.** 이미지 태그를 그대로 유지하고 **신규 Backend PodTemplate의 Kubernetes Readiness Probe 경로만 잘못 설정한 통제된 배포 안전성 테스트**이다. 자동 트래픽 격리는 Readiness/Service가 수행했고, **원복은 GitOps PR을 수동 병합**해 수행했다.

기준: [통합 장애 시연안 PR #123](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123)의 T2 Deployment Safety 번호. 이 문서는 **2026-10-16 재시연 결과를 현재 대표 T2 결과로 기록**한다. 2026-10-15의 이전 T2 결과 문서(`t2_deployment_safety_1015.md`)는 삭제하지 않고 **이전 실행 결과로 보존**하며, 당시 병합 이력은 [PR #125](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/125)에서 확인할 수 있다. GitHub 문서 작성자는 사용자 공유 `oc` 출력·GitOps 변경 이력·담당자 k6 분석 보고를 근거로 했으며, 원본 CSV를 직접 재분석한 것은 아니다.

## 1. 시험 환경과 주입 방법

| 항목 | 구성/실측 |
| --- | --- |
| 환경 | ROSA HCP Primary, Namespace `neuroplan`, Argo CD Application `neuroplan-gitops/neuroplan-rosa` |
| 대상 | Deployment `neuroplan-backend`, 기존 정상 RS `neuroplan-backend-584495dbb6` |
| 보호 설정 | Backend `replicas=2`, RollingUpdate `maxUnavailable=0`, `maxSurge=1` |
| 정상 Readiness | `/actuator/health/readiness` |
| 실패 주입 Readiness | `/actuator/health/t2-intentional-notready` |
| 이미지 | Backend `e5d288f` 유지, 이미지 변경 없음 |
| k6 | Infra VM, `LOGIN_MODE=session`, 로그인 1회 후 조회/저장 반복; 두 ROSA 연결 IP에서 성공 보고 |
| 성공 기준 | 신규 비정상 Pod 미유입·기존 정상 Pod 유지·GitOps 원복·k6 측정 요청 실패 0건 |

ROSA overlay `overlays/rosa/kustomization.yaml`의 **Backend Deployment 한정** JSON6902 patch로 `readinessProbe.httpGet.path`만 잘못된 경로로 대체했다. DB/Route 53/Secret/Replica/이미지 변경 없이 GitOps PR 병합으로 주입했다.

- [GitOps PR #21 — 실패 Readiness 주입](https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/21), Squash Merge `c3f36e09487f9531afb77d7f31439d5d9be03f95`.
- [GitOps PR #30 — 정상 Readiness 복구](https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/30), Squash Merge `b567646c5bd4f90696650290f8695844103664c5`.
- 원래 준비했던 복구 PR #22는 Squash Merge 이후 GitHub 비교에서 **변경 파일 0개**로 나타나 사용하지 않았다. **실제 원복에는 PR #30을 사용**했다.

## 2. 실행 타임라인 (2026-10-16 KST)

| 시각 | 실측/조치 |
| --- | --- |
| **19:20:18.404** | 사전 상태 확인: Argo Synced/Healthy, Backend 2/2, 정상 Readiness, Service 정상 Endpoint 2개 |
| **19:21:36** | k6 측정 시작(담당자 분석 보고, 초 단위) |
| PR #21 병합 후 | Argo CD에 실패 설정 전달; 정확한 동기화 적용 시작 시각은 별도 확정하지 않음 |
| **19:24:31 (T0)** | 신규 실패 RS `neuroplan-backend-bf4b9d995` 생성(`metadata.creationTimestamp=2026-10-16T10:24:31Z`) |
| **19:26:31.382** | During: 기존 RS 2/2 Ready, 실패 RS 0/1 Ready, Backend AVAILABLE=2, 신규 Pod Endpoint `ready=false` |
| PR #30 병합 후 | 정상 Probe 경로로 GitOps 원복 시작(정확한 클러스터 반영 시각 별도 측정 없음) |
| **19:27:41.309** | 원복 반영 중간 관측: Argo `Synced/Progressing`, 실패 RS 1/1/0 및 잘못된 Probe 경로 아직 남아 있음 |
| **19:28:33** | After: Argo `Synced/Healthy`, Backend `2/2`·UP-TO-DATE 2·AVAILABLE 2, 실패 RS `0/0/0`, 정상 Probe 경로 확인 |
| **19:29:18** | k6 측정 종료(담당자 분석 보고, 초 단위) |

**시각 정의:** T0는 신규 RS의 Kubernetes **생성 시각(초 단위)**이다. GitHub Merge 시각, 최초 Probe 실패 시각과 같다고 가정하지 않는다. T0→19:28:33은 **관측상 정상화 확인까지 약 4분 2초**이지 자동 롤백 시간, User RTO 또는 서비스 다운타임이 아니다.

## 3. During — ReplicaSet·Pod·Endpoint 실제 상태

2026-10-16 19:26:31.382 KST 공유 `oc` 출력:

~~~text
Deployment neuroplan-backend    READY=2/2  UP-TO-DATE=1  AVAILABLE=2

ReplicaSet                                  DESIRED  CURRENT  READY
neuroplan-backend-584495dbb6               2        2        2
neuroplan-backend-bf4b9d995                1        1        0

Pod
neuroplan-backend-584495dbb6-6tfz2         1/1 Running
neuroplan-backend-584495dbb6-zng5j         1/1 Running
neuroplan-backend-bf4b9d995-q9pwq          0/1 Running

EndpointSlice
기존 정상 Pod 2개  ready=true
신규 실패 Pod 1개  ready=false
~~~

**해석:** 신규 Pod는 컨테이너 `Running`이라도 Kubernetes `Ready=false`이므로 **일반 Service 로드밸런싱 대상이 아니었다**. EndpointSlice에서 신규 Pod가 완전히 사라진 게 아니라 항목으로 존재하되 `ready=false`인 상태였다. `maxUnavailable=0` 및 `maxSurge=1` 정책 아래 정상 RS 2개의 가용 상태가 유지되는 것을 확인했다.

## 4. After — GitOps 원복 확인

2026-10-16 **19:28:33 KST**의 DevOps VM 관측:

~~~text
Argo CD Application neuroplan-rosa
Sync=Synced  Health=Healthy
Revision=b567646c5bd4f90696650290f8695844103664c5

Deployment neuroplan-backend    READY=2/2  UP-TO-DATE=2  AVAILABLE=2

ReplicaSet                                  DESIRED  CURRENT  READY
neuroplan-backend-584495dbb6               2        2        2
neuroplan-backend-bf4b9d995                0        0        0

Readiness Probe:
/actuator/health/readiness
~~~

원복 전 `Synced/Progressing` 관측을 곧바로 완료 판정하지 않고, **실패 RS 0/0/0·Probe 경로·Argo Healthy까지 확인**한 뒤 최종 복구 완료로 판단했다.

## 5. k6 원본 CSV 상세 분석 결과 (정현 담당자 보고)

| 지표 | 10/16 전체 측정 구간 |
| --- | ---: |
| 측정 구간 | **19:21:36.210947 ~ 19:29:18.537531 KST** (담당자 제공 CSV 분석 시각, 약 7분 42초) |
| 로그인 | **1/1 성공** |
| 상태 조회 | **434/434 성공** |
| 저장 | **434/434 성공** |
| 보고된 요청 HTTP 코드 | **전부 200** |
| 실패 상세 | **없음** |
| 연결 경로 | ROSA 연결 IP **2개**에서 성공 보고 |
| 최종 결과 | **PASS**, 측정 구간 오류 0건 |

- 측정은 최초 로그인 1회 후 세션으로 반복 조회·저장하는 **연속성 검증**이다. T0 후 **새 로그인 자체를 다시 시험한 것은 아니다**.
- **T0 이후 단계별 요청 건수는 본 요약에 별도 제공되지 않았다.** 전체 구간에 실패가 없다는 보고와 T0 이후 각 단계의 세부 요청 수를 혼동하지 않는다.
- **원본 CSV 보관 경로:** Infra VM `/root/k6_t2_20261016-192136.csv`.
- **CSV SHA-256 (전체 64자리):** `3ff0ac7e44bfec9cdbbf65a9895daf3e9c0269d0582946802db18c776e97cc14`.
- **상세 분석 보고서:** Infra VM `/root/t2_k6_evidence_fixed_20261016-193720.txt`.
- **증적 출처와 한계:** 파일명·해시·정밀 관측 시각은 **정현 담당자가 제공한 CSV 분석 및 SHA-256 출력과 PR 리뷰어의 대조 결과**에 근거한다. 본 PR 작성자와 리뷰어가 Infra VM의 실제 CSV를 각각 독립적으로 내려받아 재분석·재해시했다고 주장하지 않는다.
- 이 결과는 측정 중 **k6 요청 응답이 모두 HTTP 200**이었다는 뜻이다. 애플리케이션의 모든 다른 사용자, 외부 지표 및 관측하지 않은 요청까지 5xx=0이었다고 단정하지 않는다.

## 6. Grafana·증적·최종 판정

Grafana T2 Before/During/After 비교 변수:
- **기존 RS:** `neuroplan-backend-584495dbb6`
- **신규 실패 RS:** `neuroplan-backend-bf4b9d995`
- **관측 시간 범위:** 2026-10-16 19:21~19:30 KST

**대시보드 점검 상태:** 코드 통합 후 `Data does not have a time field` 표시와 두 RS 변수 선택값 중복이 **보고되었다**(재시연 배경 참조). 구체 원인, PromQL/Time series 설정 수정 여부, 10/16 재시연 당시 패널 정상화 및 최종 Grafana 캡처는 **확인 자료가 제출되지 않아 미검증**이다. Kubernetes/k6 PASS를 Grafana 패널 수정 완료의 근거로 삼지 않는다.

**판정: T2 PASS (Readiness 비정상 Pod 미유입·정상 RS 유지·GitOps 원복·측정된 조회/저장 연속성).**

**증적 현황:** DevOps VM에서 공유된 `oc` RS/Pod/EndpointSlice/Deployment/Argo 관측 출력과 GitOps PR #21/#30의 변경·복구 커밋을 근거로 한다. k6 원본 CSV 및 분석 보고서는 **Infra VM에 별도 보관된 경로를 담당자가 제공**했으며, 본 PR에는 첨부하지 않는다. **Grafana 화면 캡처·대시보드 JSON의 실제 보관처 및 첨부 여부는 확인되지 않았다.** 테스트 계정·IP·인증정보를 PR에 공개하지 않는다.

**한계:** 실제 잘못된 이미지의 배포 차단, 자동 Git revert/자동 롤백, 복수 사용자 부하, 신규 로그인 반복, 서비스 전체 5xx 부재, 장애에서의 User RTO는 이 측정으로 입증하지 않는다.
