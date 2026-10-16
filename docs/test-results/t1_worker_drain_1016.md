# T1 Application HA — ROSA Worker Drain 재시연 결과 (2026-10-16)

## 재시연 배경 — Grafana 대시보드 코드 통합 및 모니터링 지표 재검증

2026-10-15 기존 [T1 Worker Drain 결과 PR #124](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/124)에서는 Backend Pod 재배치 및 k6 **T0 이후 검증 단계 594건, 실패 0건**으로 관측 범위 내 PASS를 확인했다. 하지만 Grafana 대시보드의 **'수집 대상 이상' 및 'HTTP 5xx 건수(추정)' 표시**는 실제 서비스 오류와 메트릭 수집·시각화 상태를 구분해 해석할 필요가 있었다.

- **메트릭 의미 분리:** Prometheus `up`은 대상의 메트릭 수집 성공 여부이고, HTTP 5xx는 애플리케이션의 실제 오류 응답이다. Pod 교체 직후의 일시적인 `up=0` 또는 수집 대상 이상 표시만으로 실제 HTTP 5xx 발생을 확정할 수 없다.
- **Grafana 통합 대시보드 점검:** **두 대시보드 코드를 통합한 이후** T2의 '기존·신규 Pod Ready 변화' 패널에서 `Data does not have a time field` 및 기존·신규 ReplicaSet 선택값 중복 문제가 확인됐다. 이에 통합 대시보드의 **PromQL, 시계열 쿼리 모드, Transformation 및 변수 매핑**을 함께 점검할 필요가 있었다. 다만 **T1의 이상 표시가 코드 통합 때문에 발생했다는 직접적인 인과관계는 아직 확정되지 않았다.**
- **재검증 목적:** Worker Drain 전·중·후의 노드 Scheduling 상태, Pod 재배치·Ready 상태와 k6 연속성 결과를 구분해 확인하고, 실제 애플리케이션 오류 지표와 모니터링 수집 상태를 함께 대조하여 증적의 신뢰성을 높인다.

이에 **2026-10-16 T1을 재시연**했고, 본 문서는 해당 실행의 Pod 재배치·Uncordon·Argo 정상화와 **k6 로그인 1/1·상태 조회 170/170·저장 170/170 성공(전체 측정 기준)**을 기록한다. 기존 T1은 **실패로 판정한 것이 아니며**, 10/15 결과와 PR 이력은 보존한다.

**증적 범위:** Grafana에서 `배치 가능 → 배치 불가능 → 배치 가능` 상태 변화가 관측됐지만, 통합 대시보드의 **모든 패널 수정 완료·원인 규명·최종 스크린샷 첨부까지 확인된 것은 아니다.** k6 원본 CSV도 본 PR에 포함하지 않았다.

> **최종 판정: PASS (관측·k6 측정 범위 내).** Worker Drain과 Pod 재배치, Uncordon 및 ROSA 정상화를 확인했다. Infra VM에 보관된 k6 원본 CSV의 상세 분석 결과로, 측정 구간 전체에서 로그인 1/1·상태 조회 170/170·저장 170/170 성공, HTTP 응답 모두 200, 실패 상세 없음이 **정현 담당자 보고 기준**으로 확인됐다.
>
> **한계:** 정상 Worker를 대상으로 통제된 `oc adm drain`을 실행한 시험이지 실제 전원/물리 장애가 아니다. 로그인은 세션 모드의 **최초 1회**이므로 T0 이후 새 로그인 재시도는 시험하지 않았다. HTTP 200/실패 0은 k6 표본의 결과이며, 전체 서비스·모든 사용자의 5xx 부재를 증명하지 않는다.

기준: [통합 장애 시연안 PR #123](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123)의 T1 Worker/Pod 장애 번호. **10/15 결과와 별개의 10/16 재시연**이며, 기존 [10/15 T1 문서 PR #124](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/124)를 대체하거나 수정하지 않는다. 이 문서는 사용자에게 공유된 `oc` 출력·시각 기록과 k6 분석 보고를 바탕으로 정리했으며, GitHub에서 VM 원본 CSV를 직접 재분석한 것은 아니다.

## 1. 시험 범위 및 방법

| 항목 | 실측/구성 |
| --- | --- |
| 환경 | ROSA HCP Primary, Worker 3개 AZ 분산, Namespace `neuroplan` |
| 대상 | Worker **2b**, `ip-10-20-47-36.ap-northeast-2.compute.internal` |
| 주입 | `oc adm drain --ignore-daemonsets --delete-emptydir-data --timeout=5m` |
| 복구 | `oc adm uncordon` |
| 보호 체계 | Backend 다중 Replica, PDB·Pod 분산 구성, Service Readiness/Endpoint |
| k6 | Infra VM; `LOGIN_MODE=session`(세션 로그인 후 조회·저장 반복), 두 ROSA 연결 IP에서 성공 보고 |
| 성공 기준 | Worker drain/재배치/복구 확인 + k6 측정 구간 요청 실패 0건 |

## 2. 실행 타임라인 (2026-10-16 KST)

| 시각 | 실측/조치 |
| --- | --- |
| **19:15:53** | k6 전체 관측 시작(담당자 분석 보고, 초 단위) |
| **19:16:57.049 (T0)** | Drain 명령 실행 직전 기록된 장애 주입 기준 시각 |
| **19:17:15.475** | Drain 명령 종료, `DRAIN_EXIT=0`. **명령 실행 약 18.426초** |
| Drain 진행 중 | 대상 Worker `Ready,SchedulingDisabled`(Grafana: **배치 불가능**), 기존 Backend Pod eviction |
| Drain 이후 | Backend Pod가 다른 Worker로 재생성·Ready, 나머지 정상 Pod 가동 |
| **19:18:09.120** | Uncordon 시작(완료 시각은 이 기록과 구분) |
| **19:18:53** | k6 전체 관측 종료(담당자 분석 보고, 초 단위) |
| 이후 상태 확인 | ROSA Worker 3대 Ready, Backend/Frontend 2/2 Ready, Argo CD `Synced/Healthy` |

**시간 해석:** `18.426초`는 Drain 명령 소요시간이지 서비스 중단시간이나 User RTO가 아니다. T0는 Drain 실행 직전 기준 시각이며 Pod eviction/재생성 각각의 정확한 적용 시각이 아니다. 사용자 무중단 판정은 k6 **표본 실패 0건**을 근거로 한다.

## 3. Kubernetes 실측 결과

- Drain 대상 Worker: **2b**. Drain 이전 Backend Pod `neuroplan-backend-584495dbb6-4krcs`가 해당 Worker에 있었다.
- Drain으로 `4krcs`가 퇴거됐고, 신규 Backend Pod `neuroplan-backend-584495dbb6-zng5j`가 **2a**에 재생성됐다.
- 다른 Backend Pod `neuroplan-backend-584495dbb6-6tfz2`는 **2c**에서 정상 가동했다.
- Drain 후 확인 시 Backend는 **2/2 Ready**, Service 정상 Endpoint **2개**였다. Frontend 역시 **2/2 Ready**였다.
- Uncordon 후 Worker **3대 모두 Ready**, GitOps Application `neuroplan-rosa`는 **Synced/Healthy**로 확인됐다.
- Grafana `Drain 대상 · Scheduling`의 **배치 가능 → 배치 불가능 → 배치 가능**은 Cordon/Uncordon에 따른 스케줄링 차단/해제를 의미한다. `SchedulingDisabled`를 `NotReady`/노드 전원 장애로 해석하지 않는다.

## 4. k6 원본 CSV 상세 분석 결과 (정현 담당자 보고)

| 지표 | 10/16 전체 측정 구간 |
| --- | ---: |
| 측정 구간 | **19:15:53 ~ 19:18:53 KST** (초 단위 약 3분) |
| 로그인 | **1/1 성공** |
| 상태 조회 | **170/170 성공** |
| 저장 | **170/170 성공** |
| 보고된 요청 HTTP 코드 | **전부 200** |
| 실패 상세 | **없음** |
| 연결 경로 | ROSA 연결 IP **2개**에서 성공 보고 |
| 최종 결과 | **PASS**, 측정 구간 오류 0건 |

- **로그인은 최초 1회**이고 조회·저장을 반복하는 세션 연속성 검증이다. **T0 이후 단계별 성공 건수를 별도로 집계한 값은 이 요약에 수록되지 않았다.** 전체 구간에 실패가 없다는 보고는 T0 이후 표본에도 실패가 없음을 의미하지만, T0 이후 요청 수를 전체 170건으로 표기하지 않는다.
- 원본 CSV SHA-256 **축약 표기:** `44e407...736777`. **전체 64자리 해시는 원본 증적 보관처에서 확인**해야 하며 이 값만으로는 무결성 검증이 불가능하다.
- 본 문서에서 p95/p99, 노드 재배치 완료 초 단위, k6 VU 수 등 원본 분석 보고에 없는 값은 추정해서 쓰지 않는다.

## 5. 판정, 증적 및 제한

**판정: T1 PASS (인프라 재배치·스케줄링 복구 및 측정된 사용자 조회/저장 연속성).** Worker Drain 중 Pod 퇴거/다른 Worker 재배치가 이루어졌고 복구 후 서비스가 정상이며, k6 세션 시나리오의 요청 실패가 보고되지 않았다.

**별도 보관 증적:** DevOps VM의 ROSA `oc` Drain/RS/Pod/Endpoint/Argo 로그, Grafana Cordon/Uncordon 및 Replica 관측 화면, Infra VM의 k6 원본 CSV·SHA-256·HTTP 코드/단계별 실패 상세 보고. 실제 CSV 파일명·전체 SHA-256/화면 파일 경로는 원본 보관 담당자 확인 대상이다. 원본 CSV와 계정/인증정보를 이 PR에 첨부하지 않는다.

**추가 해석 주의:** Drain 명령 수행 중 모든 순간에 Ready Replica 2개가 유지됐다는 초 단위 전 구간 추적 자료는 이 문서에 없으며, 명확하게 기록된 것은 **Drain 이후 정상 2/2 및 k6 표본 실패 0건**이다. 이 결과를 대량 부하, 실제 Worker Crash, 전체 서비스 무장애 보증으로 일반화하지 않는다.
