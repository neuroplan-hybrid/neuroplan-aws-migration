# T2 Deployment Safety — 실패 Readiness 배포 차단 실측 결과 (2026-10-15)

> **판정: 실측 범위 내 PASS.** ROSA 신규 Backend ReplicaSet의 Readiness Probe 경로 오류를 GitOps로 주입했을 때, 기존 정상 ReplicaSet 2개가 Ready 상태를 유지했고 신규 Pod는 NotReady로 일반 서비스 트래픽에서 제외되었다. GitOps 원복 후 Argo CD Synced/Healthy와 Backend 2/2 복귀를 확인했다. k6 T0 이후 단계 검사 697건 중 실패 0건.
>
> **중요:** 이 테스트는 **잘못된 컨테이너 이미지/이미지 태그를 배포한 시험이 아니다.** 기존 이미지 태그는 유지하고 **신규 Pod의 Readiness Probe 경로만 의도적으로 잘못 설정한 RollingUpdate 안전성 시험**이다. T2 결과를 '불량 이미지 버전의 롤백'으로 표현하지 않는다.

기준: [통합 장애 시연안 PR #123](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123), **T2 — Deployment Safety**. 실측 기록만 추가하며 이 보고서 PR은 클러스터/Terraform/GitOps 운영 설정을 변경하지 않는다.

## 1. 환경과 안전 설정

| 항목 | 실제 확인 |
| --- | --- |
| 환경 | AWS ap-northeast-2 / ROSA HCP Primary / Namespace `neuroplan` |
| 대상 리소스 | Deployment `neuroplan-backend`, Argo CD Application `neuroplan-gitops/neuroplan-rosa` |
| GitOps 소스 | `git@github.com:neuroplan-hybrid/neuroplan-gitops.git`, branch `main`, path `overlays/rosa` |
| Argo CD | 자동 동기화 활성화(`prune: true`, `selfHeal: true`) |
| 기존 정상 ReplicaSet | `neuroplan-backend-594d678765`, DESIRED/CURRENT/READY = **2/2/2** |
| RollingUpdate | `replicas=2`, `maxUnavailable=0`, `maxSurge=1` |
| 정상 Readiness 경로 | `/actuator/health/readiness` |
| 사전 ConfigMap | `DEMO_READINESS_FAIL=false` |
| 기저 이미지 | ROSA GitOps overlay의 Backend `newTag: "e5d288f"` (T2에서 태그 변경 없음) |
| 측정 | Infra VM에서 k6 `LOGIN_MODE=session`, 테스트 계정 1개/1 VU, `https://app.neuroplan.cloud` |

기존 정상 Endpoint IP 두 개는 `10.130.0.32`, `10.129.1.219`였다. 실제 Pod 이미지 digest를 양쪽에서 따로 대조한 기록은 없으며, 이번 변경의 핵심은 이미지 교체가 아닌 Readiness 경로 변경이다.

## 2. 장애 주입 방식 및 GitOps 변경 이력

**주입 방법:** ROSA overlay `overlays/rosa/kustomization.yaml`에 Backend Deployment만 대상으로 하는 JSON6902 patch를 추가하여, **신규 PodTemplate**의 `readinessProbe.httpGet.path`를 다음과 같이 바꿨다.

~~~yaml
- target:
    kind: Deployment
    name: neuroplan-backend
  patch: |-
    - op: replace
      path: /spec/template/spec/containers/0/readinessProbe/httpGet/path
      value: /actuator/health/t2-intentional-notready
~~~

- 정상 경로: `/actuator/health/readiness`.
- 실패 경로: `/actuator/health/t2-intentional-notready` (존재하지 않는 경로를 통한 Readiness 실패 의도).
- **변경하지 않은 항목:** 이미지/태그, replicas, RollingUpdate 정책, liveness/startup Probe, DB, Route 53, TLS, Secret, Fence.
- 별도로 ConfigMap의 `DEMO_READINESS_FAIL=true` 스위치를 사용하지 않았다. 애플리케이션 내 Deployment Safety health indicator는 Route 53 routing health group에도 포함되어 있기 때문에, T2에서는 **신규 Pod의 Kubernetes Readiness Probe 경로만** 수정하는 방식을 채택했다.
- Argo CD `selfHeal`과 충돌할 수 있는 직접 `oc patch`가 아니라 **GitOps PR 병합/원복**으로 진행했다.

GitOps 변경 링크:
- [PR #19 — T2 Readiness 실패 주입](https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/19), **2026-10-15 12:50:09 KST 병합**, merge commit `d97f35c2a1e98aca46f76ef5a4407a9bf569aaa3`.
- [PR #20 — T2 Readiness 정상 원복](https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/20), **2026-10-15 12:56:31 KST 병합**, merge commit `083d0062405319abef8d0f60cda44d3b59cdc636`.

## 3. 실측 타임라인 (2026-10-15 KST)

| 시각 | 확인 내용 |
| --- | --- |
| 12:47:27.420 | k6 CSV 측정 시작 |
| 12:50:09 | GitOps PR #19 병합; Argo CD Auto Sync 대상 변경 |
| **12:52:07.000** | **T0: 신규 실패 ReplicaSet `neuroplan-backend-696b7bd548`의 `metadata.creationTimestamp=2026-10-15T03:52:07Z`** |
| T0 후 실측 | Argo CD revision `d97f35c2...` / Synced / Progressing, 기존 RS Ready 2/2, 신규 RS Ready 0/1 |
| T0 후 실측 | 기존 두 Endpoint `ready=true`; 신규 실패 Pod `10.128.0.42`는 EndpointSlice에 존재하나 `ready=false` |
| 12:56:31 | GitOps PR #20 정상 Readiness 원복 병합 |
| 원복 반영 확인 (정확한 시각 미수집) | Argo CD revision `083d0062...` / Synced / Healthy, Backend 2/2 Ready·UP-TO-DATE 2·AVAILABLE 2; 실패 RS 0/0/0, 정상 경로 복귀 |
| 12:58:08.562 | k6 CSV 마지막 측정 레코드 |

**T0 기준 주의:** 신규 ReplicaSet의 생성 시각을 장애 주입 관찰 기준점으로 사용했다. 이는 PR 병합 시각이나 첫 Readiness Probe 실패 시각과 다르며, 후자의 정확한 시각은 별도 수집하지 않았다. 원복의 Argo CD Healthy 도달 시각 또한 초 단위로 기록하지 않았으므로 **복구 소요 시간/RTO 수치를 계산하지 않는다**.

## 4. Pod / ReplicaSet / Endpoint 실측

장애 주입 중 Kubernetes 조회 결과:

~~~text
# Deployment
NAME                READY   UP-TO-DATE   AVAILABLE
neuroplan-backend   2/2     1            2

# ReplicaSets
NAME                            DESIRED  CURRENT  READY
neuroplan-backend-594d678765    2        2        2
neuroplan-backend-696b7bd548    1        1        0

# Pods
neuroplan-backend-594d678765-2wl4n   1/1  Running  RESTARTS=0
neuroplan-backend-594d678765-n89gf   1/1  Running  RESTARTS=0
neuroplan-backend-696b7bd548-kpqb4   0/1  Running  RESTARTS=0

# Service EndpointSlice
10.130.0.32   ready=true
10.129.1.219  ready=true
10.128.0.42   ready=false
~~~

**해석:** 신규 실패 Pod는 `Running`이지만 `Ready=false`이므로 일반 서비스 트래픽에 투입되지 않는다. 신규 IP는 EndpointSlice에서 완전히 사라진 것이 아니라 **존재하면서 ready=false**로 표시됐다. `maxUnavailable=0`에 따라 정상 구버전 RS의 두 Pod가 제거되지 않고 유지되었다.

정상 원복 후:

~~~text
Argo CD   Revision 083d0062405319abef8d0f60cda44d3b59cdc636
          Sync=Synced  Health=Healthy

Deployment neuroplan-backend   READY=2/2 UP-TO-DATE=2 AVAILABLE=2
RS neuroplan-backend-594d678765   DESIRED=2 CURRENT=2 READY=2
RS neuroplan-backend-696b7bd548   DESIRED=0 CURRENT=0 READY=0
Readiness path  /actuator/health/readiness
~~~

## 5. k6 연속성 결과 (원본 CSV 분석 출력 기준)

분석 위치: Infra VM `/root/k6_rto_summary_1007.py`; 파일 `/root/k6_t2.csv`; `--mode continuity --allow-fail 0`.

~~~bash
python3 /root/k6_rto_summary_1007.py \
  /root/k6_t2.csv \
  --t0 "2026-10-15T12:52:07+09:00" \
  --mode continuity \
  --allow-fail 0
~~~

| 지표 | 전체 실측 | **T0 이후 판정 구간** |
| --- | ---: | ---: |
| 측정 기간 | 12:47:27.420 ~ 12:58:08.562 (**약 10분 41초**) | 12:52:07.000 ~ 12:58:08.562 (**약 6분 2초**) |
| `step_ok` 검증 단계 수 | 1,240 | **697** |
| 실패 | **0** | **0** |
| 단계 실패율 | 0.00% | **0.00%** |
| 로그인 | 2건 성공 / 0 실패 | **1건 성공 / 0 실패** |
| 상태 조회 (`state`) | 619건 성공 / 0 실패 | **348건 성공 / 0 실패** |
| 상태 저장 (`save`) | 619건 성공 / 0 실패 | **348건 성공 / 0 실패** |
| state 응답 p95 / p99 | 16ms / 24ms | **15ms / 25ms** |
| save 응답 p95 / p99 | 29ms / 37ms | **29ms / 41ms** |

분석기 최종 출력:

~~~text
T0 (장애 주입)      : 12:52:07.000
첫 실패 [보조]      : -
[연속성 T1·T2·T5·T8] PASS — T0 이후 사용자 실패 0건 (허용 0건)
[발표] T0 이후 구간: 12:52:07.000 ~ 12:58:08.562
       step_ok 697건, 실패 0건, 에러율 0.00%
       login 1건, state 348건, save 348건
~~~

**정확한 주장 범위:**
- `step_ok` 697건은 **검증 단계 수**로, 전체 HTTP 요청 수나 동시 사용자 수가 아니다.
- T0 이후 **로그인 1회**가 성공했지만 로그인 요청 1건의 p95/p99(579ms)를 의미 있는 분포 지표로 일반화하지 않는다.
- `LOGIN_MODE=session`의 1 VU 테스트이므로 다중 사용자 고부하나 모든 서비스 API의 무중단, 전체 HTTP 5xx 0건을 입증하지 않는다.
- 계획 실행 시간은 15분이었으나 실제 CSV 측정은 **약 10분 41초**다.
- 연결 IP가 `15.165.65.7`(12:47:27.420~12:52:08.014)에서 `54.180.48.186`(12:52:09.048~12:58:08.562)로 바뀌었다. **IP 변화만으로 DR 전환, 라우팅 장애 또는 DNS Failover를 단정하지 않는다.**

## 6. 판정

| 검증 항목 | 결과 |
| --- | --- |
| GitOps 실패 배포 반영 / 신규 RS 생성 | **PASS** |
| 신규 실패 Pod `Ready=false` 유지 | **PASS** |
| 기존 정상 ReplicaSet Ready 2/2 유지 | **PASS** |
| EndpointSlice에서 신규 Pod `ready=false` | **PASS** |
| `maxUnavailable=0` RollingUpdate 배포 보호 | **PASS (관찰 범위 내)** |
| k6 T0 이후 연속성 `step_ok` 697건 / 실패 0건 | **PASS** |
| GitOps 원복 / Argo CD Synced·Healthy / 정상 Probe 경로 복귀 | **PASS** |
| 실제 잘못된 이미지 빌드·태그 교체 / 신규 digest 검증 | **수행하지 않음** |
| 전체 사이트 5xx 0건 / 다중 사용자 부하 / DR 전환 | **미검증 / 범위 외** |
| Grafana RS Ready 시계열 캡처 원본 제출 | **별도 첨부 필요** |

**발표용 표현:** “ROSA Backend RollingUpdate 중 신규 Pod의 Readiness Probe 오류를 의도적으로 주입했습니다. 신규 ReplicaSet은 Ready 0/1로 서비스에서 제외됐지만, 기존 정상 Pod 2개와 서비스 Endpoint가 유지됐습니다. T0 이후 k6 로그인·조회·저장 검증 697건에서 실패 0건을 기록했고, GitOps 원복 후 Argo CD Synced/Healthy와 Backend 2/2를 확인했습니다.”

## 7. 증적 경로 / 추후 보강

- GitOps 실패 배포 PR: https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/19
- GitOps 정상 원복 PR: https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/20
- k6 원본 CSV: **Infra VM `/root/k6_t2.csv`** (이 문서 PR에는 미업로드)
- k6 분석 스크립트: **Infra VM `/root/k6_rto_summary_1007.py`** (동일 스크립트가 마이그레이션 저장소 `scripts/k6_rto_summary_1007.py`에도 존재)
- Grafana: 기존 RS `neuroplan-backend-594d678765` / 신규 RS `neuroplan-backend-696b7bd548` 선택 화면 캡처 필요 (이 문서 PR에 미업로드)
- k6 HTML 대시보드 및 관련 스냅샷: 보관 여부 확인 후 별도 첨부 필요; 생성 완료를 주장하지 않음

관련: [T1 결과 PR #124](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/124), [통합 시연안 PR #123](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123).
