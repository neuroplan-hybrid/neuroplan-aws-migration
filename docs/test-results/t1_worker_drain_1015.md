# T1 Worker/Pod 장애 시연 — 실측 결과 (2026-10-15)

## 재테스트 배경 — Grafana 대시보드 코드 통합 및 모니터링 지표 재검증

2026-10-15 T1 Worker Drain 실측에서는 Backend Pod 재배치·플랫폼 정상 복귀와 **k6 T0 이후 연속성 단계 594건 / 실패 0건(PASS)**을 확인했다. 그러나 Grafana에는 **'수집 대상 이상'** 및 **'HTTP 5xx 건수(추정)'** 표시가 나타나, 실제 애플리케이션 오류인지 메트릭 수집·표시 문제인지 구분할 추가 검증이 필요했다.

- **Prometheus `up`**은 대상 메트릭 스크랩 성공 여부이며 **실제 HTTP 5xx 응답 건수와 다르다.** Pod 교체 직후 `up=0`이 관측되었다고 해서 서비스에서 HTTP 5xx가 발생했다고 단정할 수 없다.
- Grafana의 오류 상태 표시 및 HTTP 5xx 추정 패널은 **원시 PromQL·스크랩 상태·HTTP 응답 코드**를 대조해야 하며, 기존 자료로 전체 서비스 5xx 유무를 결론 내리지 않는다.
- 아울러 **Grafana 대시보드 코드 두 개를 통합한 이후** T2의 **'기존·신규 Pod Ready 변화'** 패널에서 `Data does not have a time field` 오류와 ReplicaSet 변수 선택값 불일치가 확인되어, **통합 대시보드의 변수 매핑·패널 설정 전반에 대한 재점검**이 필요했다. 단, 이 통합 작업이 **T1의 모든 이상 표시를 직접 유발했다고 확정한 것은 아니다.**

이에 Grafana 대시보드의 **지표 정의 분리, PromQL 쿼리·패널 설정·변수 매핑 및 수집 상태를 점검·개선**하고, Worker Drain 전·중·후 상태와 k6 결과를 같은 구간에서 다시 대조하기 위해 **T1 재테스트를 계획**했다.

**이 문서는 10/15 당시의 실측 결과를 그대로 보존하는 기록**이며, PR #124는 미병합 종료된 상태다. **기존 T1 실패를 의미하지 않으며, 재테스트나 Grafana 수정이 완료되었다는 뜻도 아니다.**

> **판정: T1 측정 범위 내 PASS.** 실제 ROSA Worker Drain, Backend Pod 재배치, Uncordon, OpenShift 플랫폼 정상 복귀 및 k6 연속성 실패 0건을 확인했다.  
> **범위 제한:** k6는 1 VU / 세션 로그인 방식의 상태 조회·저장 연속성 시험이다. 사이트 전체 5xx 0건, T0 이후 신규 로그인, 하드웨어 강제 장애 또는 T2 성공을 의미하지 않는다.
>
> 기준: [통합 시연 제안 PR #123](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123) 신규 번호 **T1 — Worker/Pod 장애**. 기존 #63 T1과 동일하다. 이 문서는 **실행 결과만 추가**하며 운영 설정·Terraform·GitOps를 변경하지 않는다.

## 1. 시험 구성 / 사전 조건

| 항목 | 확인 내용 |
| --- | --- |
| 환경 | ROSA HCP Primary, ap-northeast-2, OpenShift 4.20.40, Worker 3대 |
| 대상 | ip-10-20-47-36.ap-northeast-2.compute.internal (10.20.47.36) |
| 주입 방식 | 승인된 통제 Worker Drain; DaemonSet 무시 및 emptyDir 삭제 허용 |
| 보호 설정 | Backend / Frontend 각각 Replica 2, PDB minAvailable 1, allowed disruptions 1, topologySpread maxSkew 1 / DoNotSchedule, Readiness Probe |
| 잔여 Worker | 10.20.19.220 / 10.20.52.133 |
| k6 | Infra VM, k6 v0.54.0, 1 VU, LOGIN_MODE=session, 대상 https://app.neuroplan.cloud |
| 시간 동기화 | DevOps VM 및 Infra VM 모두 NTP 동기화 확인 |
| 사전 테스트 | 1분: checks 169/169(100%), step_ok 113/113, http_req_failed 0/113, 56 iterations |
| 사전 점검 | Drain dry-run 통과. Cluster Operator 21개 정상, Backend / Frontend 2/2 Ready |

실제 Drain 대상에는 Backend Pod 외에도 Router, GitOps 및 OpenShift 운영 Pod가 다수 포함되므로 **애플리케이션만 축출한 테스트가 아니다**.

## 2. 실행 타임라인 (KST, 2026-10-15)

### 시작·종료 시각 및 소요 시간 (정확한 기록 기준)

| 구분 | 시작 | 종료/기준 시각 | 시간 / 의미 |
| --- | --- | --- | --- |
| **전체 k6 실측 구간** | **12:09:54.585** | **12:17:22.727** | **7분 28.142초** (CSV 최초~마지막 기록) |
| **T1 장애 주입 이후 검증 구간** | **12:12:06.487 (T0)** | **12:17:22.727** | **5분 16.240초** (T0~CSV 마지막 기록) |
| k6 시작~Drain 직전 T0 | 12:09:54.585 | 12:12:06.487 | **2분 11.902초** (장애 주입 전 기준선 측정 구간) |
| **Worker Drain 실제 종료·Uncordon 완료 시각** | — | **정확한 시각 미기록** | Drain/Pod 재배치/Uncordon 후 정상 상태만 확인; **장애·복구 소요시간 산출 불가** |

**시각 정의:** T0는 DevOps VM `~/t1-drain-start.txt`에 **Worker Drain 명령 실행 직전에** 저장된 시각이다. 실제 개별 Pod eviction 시작·완료 시각이 아니다. **12:17:22.727은 k6 CSV의 마지막 측정 레코드 시각**이며 Worker가 정상 복구된 시각이나 k6 프로세스 종료 시각을 뜻하지 않는다. Worker의 Ready 복귀, Uncordon, 서비스 재배치 완료는 확인했지만 각각의 초 단위 완료 시각이 없으므로 **RTO 또는 실제 복구 소요시간으로 표시하지 않는다**.

| 시각 | 기록된 사실 |
| --- | --- |
| 12:09:54.585 | k6 본 측정 구간 시작 |
| **12:12:06.487** | **T0: DevOps VM에서 실제 Drain 명령 직전에 기록한 주입 기준 시각** |
| T0 이후 (정확한 초 단위 별도 로그 없음) | 대상 Backend Pod neuroplan-backend-594d678765-vbqbx 및 Router/GitOps 등 다수 Pod eviction 로그 확인 |
| Drain 이후 | 대상 Worker Ready,SchedulingDisabled 확인; 새 Backend Pod neuroplan-backend-594d678765-n89gf가 10.20.52.133에서 1/1 Ready로 재생성; Backend/Frontend 모두 2/2 Ready |
| 이후 | oc adm uncordon 완료; 세 Worker 모두 Ready; Cluster Operator 21/21 Available=True, Progressing=False, Degraded=False |
| **12:17:22.727** | **k6 CSV 마지막 측정 레코드** (T0 이후 5분 16.240초; Worker 실제 복구 완료 시각과 구분) |

**주의:** T0는 Drain 명령 바로 앞에 저장한 시각이며 개별 eviction의 실제 API 적용/완료 시각을 밀리초 단위로 확정한 값은 아니다. Pod 재배치 시간 또는 복구 RTO를 계산하기 위한 개별 종료/Ready 전환 시각은 수집되지 않았다.

## 3. k6 실측 (원본 CSV 분석)

분석 기준: Infra VM의 k6_rto_summary_1007.py, continuity 모드, 실패 허용 0건, T0=2026-10-15T12:12:06.487+09:00.

| 지표 | 전체 측정 구간 | **T0 이후 판정 구간** |
| --- | ---: | ---: |
| CSV 측정 구간 (KST) | **12:09:54.585 ~ 12:17:22.727 (7분 28.142초)** | **12:12:06.487 ~ 12:17:22.727 (5분 16.240초)** |
| step_ok 검사 수 | 843 | **594** |
| step_ok 실패 | **0** | **0** |
| 실패율 | 0.00% | **0.00%** |
| Login | 1건, 실패 0 | **0건** (세션 재사용) |
| State 조회 | 421건, 실패 0 | **297건, 실패 0** |
| Save 저장 | 421건, 실패 0 | **297건, 실패 0** |
| State 응답시간 p95 / p99 | 35ms / 91ms | **39ms / 96ms** |
| Save 응답시간 p95 / p99 | 54ms / 88ms | **59ms / 96ms** |

- 스크립트 출력: **[연속성 T1·T2·T5·T8] PASS — T0 이후 사용자 실패 0건 (허용 0건)**.
- **표기 주의:** `[연속성 T1·T2·T5·T8]`은 `k6_rto_summary_1007.py` 분석기의 **공통 연속성 판정 라벨**이다. 본 문서에서 실제 수행·판정한 시험은 [PR #123의 제안 번호](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123) 기준 **T1 Worker Drain만** 해당한다. 라벨에 포함된 다른 시험까지 실행 완료했다는 뜻은 아니다.
- k6는 15분으로 설정했으나 **실제 측정은 약 7분 28초**에서 종료했다. 발표에서 15분 연속 검증이라고 표현하지 않는다.
- 로그인 단계는 T0 이전 1회 수행되었으므로 **T0 이후 신규 로그인 무중단은 이번 본 측정으로 입증하지 않았다**. 세션 기반 상태 조회·저장만 T0 이후 검증했다.
- 시험은 단일 테스트 계정의 1 VU 요청이므로 다중 사용자 부하 테스트 또는 전체 사용자 100% 무중단을 의미하지 않는다.

### 분석 재실행 명령

~~~bash
python3 /root/k6_rto_summary_1007.py \
  /root/k6_t1.csv \
  --t0 "2026-10-15T12:12:06.487+09:00" \
  --mode continuity \
  --allow-fail 0
~~~

## 4. 네트워크 독립 관측 및 Grafana 해석 유의

PR #123 네트워크 담당 [독립 관측 댓글](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123#issuecomment-6183648409)과 대조:

- 12:07~12:17 Route 53 HC 관측 및 12:06 이후 외부 앱 probe에서 **앱 경로 비정상 0행**, **HC_ROSA Failure 0**, **권한 DNS의 온프렘 전환 없음(ROSA 유지)** 보고.
- **12:12:28, 12:12:31, 12:12:33**: primary-health probe 기준 0.9초 초과 **timeout 3회**를 네트워크 담당자가 원본으로 재확인했다. **연속 timeout이 아닌 각각 단발 관측이며 사이 구간에는 HTTP 200 응답이 있었다.** Route 53 Health Checker의 Failure와 구분하고, Drain이 직접 원인인지는 확정하지 않는다.
- **12:13:34**: ROSA NLB IP 하나 교체 보고. k6 연결 응답 IP가 12:12:09 전후 변경된 현상은 별도 확인 사항이며, 이를 DR 전환 증거로 해석하지 않는다. 참고로 [T2 결과 PR #125의 네트워크 독립 관측](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/125#issuecomment-6184199856)에서는 권한 DNS가 **NLB IP 두 개를 동시에 반환**했고 외부 probe의 직접 접속 IP가 둘 사이를 오가는 현상이 확인됐다. **T1 당시의 k6 DNS 조회는 검증하지 않았으므로**, T1 IP 변경 역시 같은 원인이라고 단정하지 않는다.
- 네트워크 담당의 질문([12:12:30 HTTP 200 그래프 관련](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123#issuecomment-6183714140))에 대한 시연 구분: **이때 실행한 것은 T1 Worker Drain이며 T2 RollingUpdate / Git revert 시연이 아니다**. k6의 측정된 상태 조회/저장 실패는 0건이나, 특정 Grafana 패널의 순간적인 200 그래프 저하는 패널 PromQL·scrape·series 전환 등을 확인하기 전까지 원인을 단정하지 않는다.
- 초기 사용자 보고에는 Grafana **'수집 대상 이상'** 및 **'선택 기간 HTTP 5xx 건수 (추정)' 증가**가 포함됐으나, 10/16 과거 지표 조회에서는 신규 Pod scrape 실패와 경고 표시 조건을 확인했고 Backend 업무 5xx 시계열은 관측되지 않았다. 상세 후속 결과는 아래에 구분하며, **k6 step_ok 실패 0건이 전체 사이트 HTTP 5xx 0건을 보증하지 않는다는 제한은 유지**한다.
- 테스트 후 Drain 대상 10.20.47.36의 node-exporter 2/2 Running (restart 0), Prometheus 2개 6/6 Running, Metrics Server 2개 Running, Monitoring/Ingress Operator 정상 확인. 당시 수집 이상에 대한 **10/16 후속 확인 결과와 남은 검증 범위는 아래에 구분**한다.

### Grafana 관측 이상 후속 확인 (10/16 과거 시계열 재조회)

10/16 모니터링 점검에서 실제 Grafana `np-demo-t1` version=6, panel id=5의 PromQL과 value mapping을 조회하고, 동일 데이터 소스의 10/15 과거 지표를 읽기 전용으로 재계산했다. 대상 요청 구간은 12:09~12:18 KST, 앞뒤 원시 지표는 12:07~12:20이다. 현재 쿼리를 재현한 것이므로 영상 당시 설치 버전·시간 범위와의 완전한 일치까지 확정하지 않는다.

- 패널은 비율이 아니라 `sum(increase(http_server_requests_seconds_count{namespace="neuroplan",service="neuroplan-backend",uri!~"/actuator(/.*)?",status=~"5.."}[$__range]))` 기반 **선택 기간 5xx 추정 건수**다. 업무 counter 계산 가능 여부를 확인한 후, 현재 Backend 대상의 `min(up)==1`일 때만 건수를 표시한다.
- 대상 하나라도 `up=0`이면 별도 분기에서 **-2**를 반환하고, value mapping이 **수집 대상 이상**으로 표시한다. 이는 HTTP 5xx 응답 발생 표시가 아니다. 전체 표현식 결과가 없는 경우의 **수집 확인 필요**와도 다르다.
- 신규 Pod `...-n89gf`의 첫 raw scrape 표본은 **12:12:22.319 up=0**, 다음은 **12:12:42.984 up=1**이었다. 기존 `...-vbqbx`의 마지막 up=1 표본은 12:11:51.324, 유지 Pod `...-2wl4n`의 조회한 up 표본은 모두 1이었다. Pod 교체와 시각상 일치하지만 첫 scrape 실패의 세부 원인(timeout/접속 거절 등)은 미확정이다.
- **선택 범위 15분을 가정**, 현재 쿼리를 12:09~12:18에 1초 간격으로 평가하면 **12:12:23~12:12:42에 -2**, 그 전후에는 0이 재현됐다. 20회 scrape 실패가 아니라, raw 실패 표본 1개가 다음 성공까지 반영된 것이다. 영상의 모든 반복 표시까지 재현한 것은 아니다.
- 12:07~12:20 Backend 업무 5xx counter raw range-vector 조회는 **result=[]**, 200 counter는 실제 증가했고 Deployment Available Replica 원시 표본은 **모두 2**였다. 수집된 Backend 지표에서 5xx가 관측되지 않은 결과이며, 수집 공백·ingress/router·전체 외부 요청까지 5xx 0건으로 확대하지 않는다.
- 사용자 요청에 따라 5xx 추정 건수와 Backend scrape 상태 카드를 분리하는 **적용 파일**을 준비했다. Kubernetes·Prometheus를 변경하지 않는다. 부분 수집에서 수치를 보여주더라도 이를 전체 오류 없음으로 해석하지 않도록 설명을 붙였다. **서버 대시보드 적용·실제 화면 검증은 아직 미완료**다.
- 수정 쿼리의 과거 재계산 결과는 12:09~12:18의 관측 5xx=0 유지, 수집 상태만 12:12:23~42에 실패로 분리됐다. 업무 counter가 없는 쿼리는 0이 아니라 빈 결과로 남는 것도 확인했다. 통계가 increase 기반이므로 “관측된 실제 정수 건수”라고 표기하지 않는다.

**후속 상태:** 표시 조건과 신규 Pod의 일시적 scrape 실패는 확인했다. scrape 세부 오류 원인, HTTP 200 순간 변동의 정확한 원인, 영상 당시 버전/범위 대조, 별도 수집 공백의 HTTP 응답 및 원시 Router 로그는 미검증이다. k6 연속성 594건/실패 0건 판정은 변경하지 않는다. 전체 5xx 0건 또는 모든 관측 이상 해결로 표현하지 않는다.

## 5. 최종 판정과 후속 확인

| 검증 | 판정 |
| --- | --- |
| 실제 Worker Drain·Pod eviction | **확인** |
| Backend Pod 타 Worker 재배치 / Replica 2/2 회복 | **PASS** |
| Frontend Replica 2/2 / Worker 3대 Uncordon 후 Ready | **PASS** |
| OpenShift Router 2개 및 Cluster Operator 21/21 정상 | **PASS** |
| k6 T0 이후 상태 조회·저장 연속성 (594건 / 실패 0) | **PASS** |
| T0 이후 신규 로그인 / 전체 사이트 5xx 0건 | **미검증** |
| Grafana 5xx 추정 패널 / 수집 대상 이상 | **표시 조건·신규 Pod 일시 scrape 실패 확인. 상세 원인 및 영상/원시 로그 대조는 일부 미검증. 패널 분리 적용 파일 준비, 서버 미적용** |
| T2 비정상 배포 차단 | **별도 테스트, 이 결과에 포함되지 않음** |

**발표용 안전한 표현:** "ROSA Worker 1대에 대해 통제 Drain을 실시하여 Backend Pod가 다른 Worker에 재생성되고 Replica 2/2가 회복되는 것을 확인했습니다. T0 이후 k6 상태 조회·저장 594건은 실패 0건으로 서비스 연속성 목표를 충족했고, Worker 및 OpenShift 운영 구성 요소가 정상 복구됐습니다."

**증적 보관 위치(Infra VM; GitHub에는 원본 미업로드):**
- /root/k6_t1.csv — 요청별 k6 CSV (당시 약 1.4 MB)
- /root/t1-report.html — k6 HTML 보고서 (당시 약 168 KB)
- DevOps VM ~/t1-drain-start.txt — T0 기록
- Grafana T1 대시보드 — 별도 화면 캡처/PromQL/시각 검증 권장

관련: [PR #123](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123), [T1 사전 점검만 완료했던 과거 댓글](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123#issuecomment-6183431317), [네트워크 독립 관측](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123#issuecomment-6183648409).
