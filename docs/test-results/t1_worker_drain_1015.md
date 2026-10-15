# T1 Worker/Pod 장애 시연 — 실측 결과 (2026-10-15)

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
- **12:12:28~12:12:33**: primary-health probe 기준 0.9초 초과 **timeout 3회** 보고. Route 53 Health Checker의 Failure와는 구분한다. T0 직후이지만 Drain이 직접 원인인지 확정하지 않는다.
- **12:13:34**: ROSA NLB IP 하나 교체 보고. k6 연결 응답 IP가 12:12:09 전후 변경된 현상은 별도 확인 사항이며, 이를 DR 전환 증거로 해석하지 않는다.
- 네트워크 담당의 질문([12:12:30 HTTP 200 그래프 관련](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123#issuecomment-6183714140))에 대한 시연 구분: **이때 실행한 것은 T1 Worker Drain이며 T2 RollingUpdate / Git revert 시연이 아니다**. k6의 측정된 상태 조회/저장 실패는 0건이나, 특정 Grafana 패널의 순간적인 200 그래프 저하는 패널 PromQL·scrape·series 전환 등을 확인하기 전까지 원인을 단정하지 않는다.
- Grafana에서 **'수집 대상 이상'** 및 **'선택 기간 HTTP 5xx 건수 (추정)' 증가**가 관찰되었다는 사용자 보고가 있다. 패널 쿼리·집계 대상·정확한 원시 5xx 응답은 미확인이다. **k6 step_ok 실패 0건이 Grafana 전체 HTTP 5xx 0건을 보증하지 않는다.**
- 테스트 후 Drain 대상 10.20.47.36의 node-exporter 2/2 Running (restart 0), Prometheus 2개 6/6 Running, Metrics Server 2개 Running, Monitoring/Ingress Operator 정상 확인. 당시 수집 이상 원인과 범위는 **추가 분석 필요**.

## 5. 최종 판정과 후속 확인

| 검증 | 판정 |
| --- | --- |
| 실제 Worker Drain·Pod eviction | **확인** |
| Backend Pod 타 Worker 재배치 / Replica 2/2 회복 | **PASS** |
| Frontend Replica 2/2 / Worker 3대 Uncordon 후 Ready | **PASS** |
| OpenShift Router 2개 및 Cluster Operator 21/21 정상 | **PASS** |
| k6 T0 이후 상태 조회·저장 연속성 (594건 / 실패 0) | **PASS** |
| T0 이후 신규 로그인 / 전체 사이트 5xx 0건 | **미검증** |
| Grafana 5xx 추정 패널 / 수집 대상 이상 원인 | **미해결, 쿼리·스크레이프 점검 필요** |
| T2 비정상 배포 차단 | **별도 테스트, 이 결과에 포함되지 않음** |

**발표용 안전한 표현:** "ROSA Worker 1대에 대해 통제 Drain을 실시하여 Backend Pod가 다른 Worker에 재생성되고 Replica 2/2가 회복되는 것을 확인했습니다. T0 이후 k6 상태 조회·저장 594건은 실패 0건으로 서비스 연속성 목표를 충족했고, Worker 및 OpenShift 운영 구성 요소가 정상 복구됐습니다."

**증적 보관 위치(Infra VM; GitHub에는 원본 미업로드):**
- /root/k6_t1.csv — 요청별 k6 CSV (당시 약 1.4 MB)
- /root/t1-report.html — k6 HTML 보고서 (당시 약 168 KB)
- DevOps VM ~/t1-drain-start.txt — T0 기록
- Grafana T1 대시보드 — 별도 화면 캡처/PromQL/시각 검증 권장

관련: [PR #123](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123), [T1 사전 점검만 완료했던 과거 댓글](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123#issuecomment-6183431317), [네트워크 독립 관측](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123#issuecomment-6183648409).
