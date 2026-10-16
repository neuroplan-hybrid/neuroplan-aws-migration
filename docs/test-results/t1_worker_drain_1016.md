# T1 Application HA — ROSA Worker Drain 재시연 결과 (2026-10-16)

## 재시연 배경 — Grafana 수집 상태와 실제 서비스 오류 구분

2026-10-15 [기존 T1 Worker Drain 결과 PR #124](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/124)에서는 Backend Pod 재배치 및 k6 **T0 이후 594개 검증 단계·실패 0건**으로 측정 범위 내 PASS를 확인했다. 다만 Grafana의 **'수집 대상 이상' 및 'HTTP 5xx 건수(추정)'** 표시를 서비스 장애의 직접적인 증거로 해석할 수 없어, 메트릭 수집 상태와 애플리케이션 오류 응답을 분리해 검증할 필요가 있었다.

- **지표 의미 구분:** Prometheus `up`은 메트릭 스크랩 성공 여부이며 실제 HTTP 5xx 응답 건수가 아니다. Pod 교체 중 일시적인 `up=0`이 관측됐다는 이유만으로 서비스에서 5xx가 발생했다고 확정하지 않는다.
- **재검증 목적:** Worker Drain 전·중·후의 Scheduling 상태, Pod 재배치·Readiness, k6 조회·저장 성공 여부를 원시 메트릭·Grafana 표시와 대조하여 T1 모니터링 증적의 해석 정확도를 높인다.

이러한 증적 보완 목적으로 **2026-10-16 T1을 재시연**해 Pod 재배치·Uncordon·Argo CD 정상화와 **k6 전체 구간 로그인 1/1, 상태 조회 170/170, 저장 170/170 성공**을 기록했다. 기존 테스트가 실패했다는 의미는 아니다.

**결과 문서 기준:** **10/16 재시연 결과인 이 문서를 현재 T1 대표 결과**로 사용한다. **10/15 결과 문서는 미병합 종료된 [PR #124](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/124)의 브랜치·PR 이력에 보존**하며, `main`에는 추가되지 않았다. T2 역시 #138에서 10/16 재시연을 대표 결과로 관리하고 10/15 기록은 [PR #125](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/125)의 병합 이력에 보존한다.

**증적 범위:** Grafana의 `배치 가능 → 배치 불가능 → 배치 가능` 상태 변화가 관측됐지만, 대시보드 전체 수정 완료·원인 규명·최종 화면 캡처 확보까지 확인된 것은 아니다. k6 원본 CSV도 이 PR에 첨부되지 않았다.

> **최종 판정: PASS (관측·k6 측정 범위 내).** Worker Drain과 Pod 재배치, Uncordon 및 ROSA 정상화를 확인했다. Infra VM에 보관된 k6 원본 CSV의 상세 분석 결과로, 측정 구간 전체에서 로그인 1/1·상태 조회 170/170·저장 170/170 성공, HTTP 응답 모두 200, 실패 상세 없음이 **정현 담당자 보고 기준**으로 확인됐다.
>
> **한계:** 정상 Worker를 대상으로 통제된 `oc adm drain`을 실행한 시험이지 실제 전원/물리 장애가 아니다. 로그인은 세션 모드의 **최초 1회**이므로 T0 이후 새 로그인 재시도는 시험하지 않았다. HTTP 200/실패 0은 k6 표본의 결과이며, 전체 서비스·모든 사용자의 5xx 부재를 증명하지 않는다.

기준: [통합 장애 시연안 PR #123](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123)의 T1 Worker/Pod 장애 번호. **10/16 재시연을 T1의 대표 결과로 사용**한다. 기존 [10/15 T1 문서 PR #124](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/124)는 미병합 종료 상태이며, 당시 실측과 리뷰 이력을 보존하되 이 PR의 파일로 옮기거나 변경하지 않는다. 이 문서는 사용자에게 공유된 `oc` 출력·시각 기록과 k6 분석 보고를 바탕으로 정리했으며, GitHub에서 VM 원본 CSV를 직접 재분석한 것은 아니다.

## 1. 시험 범위 및 방법

| 항목 | 실측/구성 |
| --- | --- |
| 환경 | ROSA HCP Primary, Worker 3개 AZ 분산, Namespace `neuroplan` |
| 대상 | **Worker 2b** (호스트명 및 사설 IP 비공개) |
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
| 측정 구간 | **19:15:53.096600 ~ 19:18:53.608601 KST** (CSV 기록 기준, 약 3분) |
| 로그인 | **1/1 성공** |
| 상태 조회 | **170/170 성공** |
| 저장 | **170/170 성공** |
| 보고된 요청 HTTP 코드 | **전부 200** |
| 실패 상세 | **없음** |
| 연결 경로 | ROSA 연결 IP **2개**에서 성공 보고 |
| 최종 결과 | **PASS**, 측정 구간 오류 0건 |

- **로그인은 최초 1회**이고 조회·저장을 반복하는 세션 연속성 검증이다. **T0 이후 단계별 성공 건수를 별도로 집계한 값은 이 요약에 수록되지 않았다.** 전체 구간에 실패가 없다는 보고는 T0 이후 표본에도 실패가 없음을 의미하지만, T0 이후 요청 수를 전체 170건으로 표기하지 않는다.
- **원본 CSV 보관 경로:** Infra VM `/root/k6_t1_20261016-191553.csv` (정현 담당자가 공유한 CSV 분석·해시 출력과 리뷰어의 대조를 바탕으로 기록. 리뷰어가 Infra VM에 직접 접속해 파일을 열어본 것은 아님).
- **CSV SHA-256 (전체 64자리):** `44e407929bc2ce89c9e32b0a1df54cb6f95019e7fc792e37372488e032736777` (정현 담당자 제공 SHA-256 출력과 리뷰어 대조 기준. 본 PR 작성 과정에서 CSV 원본을 직접 재해시한 값은 아님).
- **상세 분석 보고서:** Infra VM `/root/t1_k6_evidence_fixed_20261016-193720.txt`.
- **정확한 관측 시각:** 2026-10-16 **19:15:53.096600 ~ 19:18:53.608601 KST**. T0 `19:16:57.049`는 DevOps VM에서 별도 기록한 Drain 명령 직전 시각이므로 구분한다.
- 본 문서에서 p95/p99, 노드 재배치 완료 초 단위, k6 VU 수 등 원본 분석 보고에 없는 값은 추정해서 쓰지 않는다.

## 5. 판정, 증적 및 제한

**판정: T1 PASS (인프라 재배치·스케줄링 복구 및 측정된 사용자 조회/저장 연속성).** Worker Drain 중 Pod 퇴거/다른 Worker 재배치가 이루어졌고 복구 후 서비스가 정상이며, k6 세션 시나리오의 요청 실패가 보고되지 않았다.

**별도 보관 증적:** DevOps VM의 ROSA `oc` Drain/RS/Pod/Endpoint/Argo 로그 및 Grafana Cordon/Uncordon·Replica 관측 화면, Infra VM의 k6 원본 CSV(`/root/k6_t1_20261016-191553.csv`)와 상세 분석 보고서(`/root/t1_k6_evidence_fixed_20261016-193720.txt`). 파일명·전체 SHA-256·정확한 CSV 관측 시각은 **정현 담당자가 제공한 분석 및 SHA-256 출력과 리뷰어의 대조 결과**를 근거로 기록했다. 리뷰어가 Infra VM에 직접 접속하여 원본 CSV를 독립 분석·재해시했다고 주장하지 않는다. Grafana 화면의 실제 저장 경로는 별도 확인이 필요하다. 원본 CSV 및 계정·인증정보는 이 PR에 첨부하지 않는다.

**추가 해석 주의:** Drain 명령 수행 중 모든 순간에 Ready Replica 2개가 유지됐다는 초 단위 전 구간 추적 자료는 이 문서에 없으며, 명확하게 기록된 것은 **Drain 이후 정상 2/2 및 k6 표본 실패 0건**이다. 이 결과를 대량 부하, 실제 Worker Crash, 전체 서비스 무장애 보증으로 일반화하지 않는다.
