# [제안] 전체 구축 완료 후 통합 장애 시연 — RDS Multi-AZ 포함

> **상태: 팀 검토용 신규 시연안 / 실행·병합·인프라 변경 승인 아님.**
>
> AWS ROSA Primary + On-Prem Warm Standby DR의 **전체 구축이 끝나고**, 운영 RDS Multi-AZ까지 **실제 적용 및 안정화한 뒤** 시연한다는 가정이다. 기존 #63 확정 시연 범위·#33의 10/16 촬영/종료 일정·#97의 "Multi-AZ 강제 장애 시연 제외" 결정을 이 문서 작성만으로 바꾸지 않는다.
>
> 새 시연안에 팀이 동의하고, 운영 일정·비용·DB/플랫폼/네트워크 GO를 별도로 받은 경우에만 진행한다. **RDS Multi-AZ Plan PASS(#122)와 실제 Apply/안정화 완료는 다르다.**

## 1. 목표와 전체 구성

기존 T1/T2 및 PITR, VPN 이중화, ROSA → 온프렘 DR, 예비 인증서 운영을 연결하고,
추가 구축한 **RDS Multi-AZ의 실제 Failover 복구능력**까지 검증하는 통합안이다.

| 번호 | 분류 | 시연 / 주입 | 핵심 질문 | 판정·증적 | 주담당 |
| --- | --- | --- | --- | --- | --- |
| **T1** | 플랫폼 HA | Worker drain / Pod 재배치 | 노드 장애 중 정상 Replica로 서비스가 지속되는가? | Replica·PDB·Topology Spread·Ready 및 k6 실패 수 | 플랫폼(예린) |
| **T2** | 배포 안정성 | 비정상 버전 유입 / Readiness 실패 | 잘못된 배포가 정상 트래픽에 유입되지 않는가? | 기존 Pod 유지, Service Endpoint, GitOps revert, k6 | 플랫폼(예린) |
| **T3** | **DB HA** | **승인된 RDS Multi-AZ 강제 Failover** | Standby로 전환한 뒤 DB 쓰기와 서비스가 복구되는가? | RDS 이벤트·AZ·Endpoint·연결 오류·k6 User RTO·역복제 | DB(정현), 플랫폼 협조 |
| **T4** | 데이터 보호 | 격리된 테스트 데이터 삭제 / PITR | 삭제 이전의 데이터 상태를 복구할 수 있는가? | 별도 복원 DB, 복원 시간·복원 시점·Row Count·조회 | DB(정현) |
| **T5** | 네트워크 HA | VPN 터널 1개 장애 | 나머지 터널로 DR 경로·RDS→온프렘 복제가 유지되는가? | 터널 상태·NLB Target·IO/SQL·Lag·k6 | 네트워크(희재), DB 협조 |
| **T6** | **사이트 DR** | **ROSA 서비스 장애 → 온프렘 Writer 승격·Route 53 전환** | 온프렘에서 로그인·조회·쓰기까지 복구되는가? | GTID·단일 Writer·권한 DNS·User/Control RTO·정합성 | 네트워크(희재) + DB(정현) |
| **T7** | TLS 운영 연속성 | **Let's Encrypt → ZeroSSL 수동 교체·원복** | 예비 CA 인증서 전환 시 HTTPS가 유지되는가? | Issuer·SAN·TLS 검증·세션 k6 실패·LE 원복 | 네트워크(희재), 플랫폼 검토 |
| **T8** | 절차 설명 | **Failback 런북 설명만** | DR Writer에서 AWS Primary로 안전하게 복귀하려면? | 재동기화·쓰기 차단·Writer 교대·Route 53 복귀 절차 | DB(정현) + 네트워크(희재) |

**실측 대상: T1~T7 총 7개. T8은 실제 장애 주입/Failback 실행 없이 절차만 설명한다.**
새 번호는 **본 제안서 안에서만 유효**하며, 기존 #63의 T1~T7 번호를 소급해 바꾸지 않는다.

### 기존 확정안 ↔ 본 제안서 번호 대응표

실제 명령/촬영/리뷰 시 **`기존 런북 번호`와 `신규 제안 번호`를 함께 기록**해 혼동을 방지한다.

| 검증 내용 | 기존 #63 및 운영 런북 | 본 제안서 | 비고 |
| --- | --- | --- | --- |
| Worker / Pod | T1 | T1 | 동일 |
| 비정상 배포 | T2 | T2 | 동일 |
| RDS Multi-AZ Failover | 제외(#97) | **T3 신규 제안** | 팀 신규 GO가 있어야 실제 장애 주입 |
| RDS PITR | T3 | T4 | 번호 이동 |
| VPN 단일 터널 | **T4** | **T5** | 기존 VPN 런북은 T4 |
| ROSA → 온프렘 Site DR | **T5** | **T6** | **기존 `site_dr_rosa_to_onprem_1008.md`는 T5** |
| 수동 Failback 설명 | T6 | T8 | 실행 없이 설명 |
| LE → ZeroSSL 수동 인증서 전환 | T7(#77 변경안) | T7 | 동일 |

### #122 적용 순서와 충돌 — 별도 팀 합의 필요

**현재 #122는 '#118의 기존 T5 Site DR 8번 Merge/Apply 및 사후 확인 완료 → 최신 main 기반 Plan → #122 Merge/Apply' 순서이며, 본 제안서와 다르다.** 본 제안서는 **Multi-AZ를 시연 전 완료 → 신규 T3 Failover → 신규 T6 Site DR**을 가정한다.

- 본 시연안이 **실제로 채택되기 전에는 #122의 Merge/Apply 보류·현재 실행 순서를 임의 변경하지 않는다**. #122 브랜치의 이전 ROSA 1 / 온프렘 0 값을 #118 이후 운영 State에 덮어쓰면 안 된다.
- 팀이 새 순서를 채택한다면 **DB·네트워크·플랫폼 담당자가 먼저 #122 적용/병합 순서와 #118의 가중치·HC 상태 보존 방안을 다시 합의**하고, 관련 PR/런북을 갱신한 뒤 최신 main·State·비공개 #115 ON 입력으로 두 tfvars Plan을 재검증한다.
- 신규 T3의 강제 Failover는 **#122 코드 리뷰·Plan 검증·실제 Apply/DB 역복제 안정화 이후에도 독립적인 장애 시연 GO가 있어야** 가능하다. 문서 병합이나 #122 Plan PASS만으로 허가되지 않는다.

## 2. 구축 완료 및 시연 GO 게이트

- [ ] **#97/#122 RDS Multi-AZ 실제 적용 완료**: 최신 승인 Plan에 따라 `multi_az=true`; 운영 RDS `available`, 별도 AZ Standby의 안정화, Pending 변경/이벤트 확인. 단순 `terraform plan` 성공은 적용 완료가 아니다.
- [ ] RDS 기존 Endpoint/백업·PITR·SNS 이벤트 구독과 `failover` 이벤트 설정 확인. **이메일 발송과 실제 수신은 구분**한다.
- [ ] RDS Writer → 온프렘 `db-primary`·`db-replica` 직접 GTID 역복제, 두 DB `read_only=1`, IO/SQL·Last Error·Lag·GTID 정상 기준선 저장.
- [ ] ROSA Backend Ready/Replica·PDB·Topology Spread·Readiness·GitOps 정상; 로그인→조회→저장 성공, DB 재연결 특성과 k6 기준선 확보.
- [ ] VPN 이중 터널, DR NLB Target, Route 53 Weighted(시연 전 **ROSA 1 / 온프렘 0**) 및 `primary-health`/`dr-health` 확인. **Health Check는 DB를 제외한 routing 검증**이며 DB 쓰기 성공과 별개다.
- [ ] 기존 온프렘 Grafana/Prometheus/Blackbox와 RDS CloudWatch/SNS 알람 정상; ROSA Thanos 토큰의 실제 유효기간·조회 상태 확인.
- [ ] 예비 ZeroSSL 인증서의 SAN·Issuer·유효기간·키 쌍 확인, 기존 온프렘 LE Secret 백업·Argo CD 관리 여부·원복 방법 검토.
- [ ] **각 시연별 변경 권한·복구 담당·시간·비용·중단 기준·증적 담당** 및 DB/플랫폼/네트워크 전원 GO. PITR 별도 복원 인스턴스 과금도 포함.
- [ ] 측정 PC/장애 주입 VM의 시각 동기화(NTP), k6·probe·스크린 녹화 동시 시작, 원본 영상 및 로그 비공개 저장 경로 확인.

게이트 미충족 시 해당 테스트는 **미실행·설계 검토**로만 발표한다. 테스트를 성사시키기 위한 즉석 DB 재시드·GTID reset·Writer 승격·Route 53 변경은 금지한다.

## 3. 시나리오별 실행·판정 원칙

### T1 — Worker / Pod 장애 (플랫폼)

- 정상 Replica가 분산됐고 PDB가 허용할 때만 사전 승인된 Worker drain 실시.
- Pod 재스케줄·Ready·Service Endpoint·k6 연속성을 동시 측정.
- 대상 노드 복구와 Replica/Ready 정상 복귀 확인 후 다음 테스트로 진행.
- **기대:** 정상 서비스 연속성. 실패 0건을 목표로 하되 실측값 그대로 기록.

### T2 — 비정상 배포 유입 방지 (플랫폼)

- 사전 준비한 **격리된 실패 버전**을 GitOps로 반영, 신규 Pod Readiness FAIL 및 기존 정상 Pod 유지 확인(`maxUnavailable: 0` 기준).
- Git revert는 **수동 복구**이고 Readiness 트래픽 차단은 자동 보호라는 차이를 명시.
- 정상 배포·GitOps Synced/Healthy·k6 성공을 확인한 뒤 다음 진행.

### T3 — **RDS Multi-AZ Failover** (DB 핵심 추가)

- 사전 승인된 **RDS 강제 Failover 시연**으로 실제 AZ/Writer 전환을 유도한다. 이는 **실제 장애 자동 감지**가 아니라 AWS Failover 메커니즘의 통제된 시험이다.
- **주입 전:** RDS Multi-AZ/Standby 안정화, Pending 변경, 백업·DB 연결/재시도, 두 온프렘 역복제의 IO/SQL·Lag·GTID 확인. 독립적인 정상 쓰기 기준선 확보.
- **주입 중:** 통제된 강제 Failover **요청 실행 시각 `T_rds_inject`**를 기록하고, RDS 이벤트/역할 전환·Endpoint 상태·k6 로그인→조회→저장 실패 구간·`DatabaseConnections`·`WriteLatency`·5xx를 관측한다. 30초 연속 성공의 **시작 시각 `T_rds_user`**를 분리 기록해 **DB User RTO = `T_rds_user − T_rds_inject`**로 계산한다. 이는 사이트 DR의 `T0`·`T_inject`와 별개다.
- **주입 후:** RDS `available` 및 구성/이벤트 확인, Backend 재연결·저장 복구, **두 온프렘 DB 역복제 재연결/GTID 연속성** 확인. Endpoint 동일만으로 서비스 복구 성공이라 판단하지 않는다.
- **주의:** Multi-AZ라고 완전 무중단이 보장되지 않는다. 복제 정지·GTID 불일치·쓰기 오류가 지속되면 후속 테스트 STOP. 승인 없이 `RESET MASTER`, `CHANGE MASTER`, 재시드, RDS 재부팅을 반복하지 않는다.

### T4 — RDS PITR 데이터 보호 (DB)

- 운영 서비스에 영향을 줄 수 있는 임의 데이터 삭제를 피하고, **사전 합의한 격리 테스트 데이터**만 사용한다.
- 테스트 데이터 삭제 전후 시각과 복원 목표 시점을 기록하고, **별도 복원 RDS**로 PITR 수행. 기존 Writer를 복원본으로 교체하지 않는다.
- Row Count/특정 레코드 조회, 복원 시점·복원 소요시간, 원본과 차이 확인.
- **T3 HA의 RTO와 T4 PITR 복원 소요시간·RPO를 합산하거나 동일 지표로 표시하지 않는다.**

### T5 — VPN 단일 터널 장애 (네트워크)

- 두 터널과 복제 상태를 기준선으로 기록하고, 승인된 방법으로 **한 터널만** Down 주입.
- 잔여 터널·DR NLB Target·RDS→온프렘 복제 IO/SQL/Lag·Blackbox·k6 추적. 수렴 과정의 실패/지연도 숨기지 않는다.
- 터널 정상 복구·복제 안정화를 확인하고 다음 진행. 온프렘 복제가 끊긴 채 T6 DR에 진입하지 않는다.

### T7 — 예비 CA 인증서 수동 교체·원복 (네트워크)

- **실행 순서는 T5 다음, T6 이전.** T7 번호는 기술 분야 분류용이고 실제 DR 전환 후에 수행하지 않는다.
- 기존 [예비 CA 전환 런북](cert_ca_switch_1007.md)과 #77 합의에 따라 **온프렘 NGF의 LE TLS Secret 백업 → ZeroSSL로 data-only 교체 → HTTPS/세션 검증 → LE 원복**.
- 교체 전·후 Issuer, SAN, 만료일, 키 쌍, 새로운 TLS 핸드셰이크, `dr-health` HTTPS 200, k6 세션 요청 실패 수 측정.
- 시연 전 Route 53 `app`이 ROSA를 가리키므로, **온프렘 DR VIP/DR NLB 경로를 명시적으로 대상으로 설정**해야 한다. 공인 `app` 성공만으로 온프렘 인증서 교체 성공이라고 하지 않는다.
- Argo CD Self-Heal·Secret 소유권을 **교체 직전 재확인**하고, 교체 후에도 의도한 Secret이 유지되는지 확인한다. 교체/원복 뒤 실제 외부 TLS Issuer와 SAN을 재조회하며 자격증명·TLS 개인 키를 노출하지 않는다.
- **T6 진입 게이트:** 유효한 기존 LE Secret으로 원복한 후 DR VIP와 `dr-health`의 **실제 TLS 핸드셰이크·Issuer·HTTP 200·정상 k6 요청 및 DR NLB Target**까지 재확인한다. 미원복·인증서 오류·연결 문제·Argo CD 재변경 의심 시 **T6 STOP** (단순 원복 명령 성공만으로 GO 금지).
- **CA 장애 자동 Failover가 아니라 사전 발급한 예비 인증서의 수동 운영 전환**임을 명시.

### T6 — ROSA → 온프렘 통합 DR (네트워크 + DB, 마지막 실제 장애 주입)

- **사전:** T3·T5 이후 두 온프렘 DB의 역복제 정상화, T7 인증서 LE 원복, ROSA Writer/On-Prem read-only 상태를 모두 확인. 시나리오 중간에 자동 DB 승격된다고 가정하지 않는다. **선행 테스트 미실행/시간 부족과 환경 이상은 다르다.** T1~T5·T7 중 어떤 시연을 생략하더라도 아래 5장의 **독립 DR GO 게이트**를 만족하면 T6를 독립 실행할 수 있지만, 미복구 장애/복제 이상이 남았다면 불가하다.
- **순서(기존 T5 런북 준수):** (1) k6/probe 시작 → (2) `DEMO_WRITE_FENCE=true` GitOps Sync·Backend 롤아웃 후 쓰기 API **503 실측 시각 `T0`** 기록 → (3) GTID catch-up·마지막 쓰기 데이터 확인 → (4) 승인된 `db-primary` 단일 Writer 수동 승격 및 제한 쓰기/재조회 완료(`T_promote`) → (5) **`primary-health` HC `--inverted` 명령 실행 시각 `T_inject` 기록** → (6) 권한 DNS가 온프렘 응답을 시작한 시각 `T_dns` 확인 및 DR 쓰기 재개 → (7) DR 사용자 로그인·조회·저장 30초 연속 성공 **구간 시작 `T_user`** 기록 → (8) **ROSA 0 / 온프렘 1** 고정·추가 증적.
- **주 지표(#68/기존 T5 런북 기준 그대로): `Control RTO = T_dns − T_inject`, `User RTO = T_user − T_inject`.** `T0`는 HC 장애 주입 시각이 아닌 **ROSA 쓰기 Fence 롤아웃 완료 후 실제 503 확인 시각**이므로 주 RTO 기점에 사용하지 않는다.
- **보조 지표:** 데이터 전환 시간 `T_promote − T0`, 쓰기 차단 확인부터 사용자 복구까지 `T_user − T0`, **최초 실패 관측 시각 `T_first_fail`부터 복구까지 `T_user − T_first_fail`**을 별도로 기록한다. 최초 실패는 k6 표본 간격의 한계가 있어 실제 장애 전체 시간과 동일시하지 않는다. `T_unhealthy → T_dns`는 Route 53 전파 구간의 보조 측정이다.
- 주 RTO 기준을 바꾸려면 새 문서에서 임의 변경하지 않고 **#68 및 `site_dr_rosa_to_onprem_1008.md` 기존 합의 변경을 별도로 승인**받는다.
- 데이터 정합성: 최종 GTID·마지막 쓰기/복원 전후 레코드·단일 Writer·반대편 쓰기 차단 확인. GTID 미수렴/중복 Writer 위험 시 승격·트래픽 전환 중단.
- T6 이후 서비스 Writer·Route 53·Terraform State 변경이 남을 수 있으므로, **실제 Failback을 그 자리에서 강행하지 않는다**. 종료/정리·State 일치 계획을 별도 승인한다.

### T8 — Failback 런북 설명 (실행 없음)

- 온프렘 Writer의 최신 데이터 RDS 재동기화 → DR 쓰기 차단·최종 GTID 확인 → RDS Writer 전환·ROSA 연결 확인 → Route 53 복귀 → 역복제 재구축 순서를 **절차 설명**으로 제시.
- 실제 복귀 성공·복귀 RTO를 주장하지 않는다.

## 4. 판정·측정 지표

| 유형 | 적용 | 최소 수집 자료 | 해석 주의 |
| --- | --- | --- | --- |
| 서비스 연속성 | T1·T2·T5·T7 | T0, k6 요청 수/실패 수·p95/p99, Pod/터널/TLS 상태 | 실패 0건은 사전 목표. 허용 기준과 실제 결과 구분 |
| DB 복구시간 | **T3** | RDS 이벤트/전환 시각, Endpoint·연결 오류, 로그인→조회→저장 회복, 두 온프렘 복제 | AWS 제어 이벤트만으로 User RTO 주장 금지 |
| 데이터 보호 | T4 | 삭제/복원 시각, 복원 인스턴스·Row Count·실제 레코드, 복원 시점 | PITR 복원 시간과 RPO 구분 |
| 사이트 DR 복구시간 | **T6** | 쓰기 Fence/GTID·Writer 승격, 권한 DNS 전환, k6 30초 연속 성공 | Control RTO ≠ User RTO, GTID 정합성 별도 검증 |
| 수동 인증서 교체 | **T7** | 적용/원복 타임라인, 실제 LE/ZeroSSL Issuer·SAN, HTTPS·세션 k6 | CA 자동 Failover 검증으로 표시 금지 |
| 런북 설명 | T8 | Failback 흐름도·검증 항목 | 실제 Failback PASS/시간 측정 없음 |

**시나리오별 RTO 기준을 혼용하지 않는다.**
- **T3 DB Multi-AZ:** `T_rds_inject` = 통제 강제 Failover 요청 실행 시각; `T_rds_user` = k6 로그인→조회→저장 30초 연속 성공 **시작 시각**; **DB User RTO = `T_rds_user − T_rds_inject`**. 연결 오류/복제 복구는 별도 기록한다.
- **T6 Site DR (= 기존 T5 런북):** `T0` = Fence 롤아웃 후 실제 쓰기 API 503 확인, `T_inject` = `primary-health --inverted` 실행, `T_dns` = 권한 DNS 첫 온프렘 응답, `T_user` = 30초 연속 성공 시작, `T_promote` = 온프렘 DB 승격·제한 쓰기 성공. **Control RTO = `T_dns − T_inject`, User RTO = `T_user − T_inject`**. **보조:** `T_promote − T0`, `T_user − T0`, `T_user − T_first_fail`. 기존 #68 주 지표 변경은 별도 팀 합의가 있어야 한다.
- T1·T2·T5·T7은 각 장애의 실제 주입·변경 시각을 개별 표기하고 사용자 요청 연속성을 기록하며, T6의 `T0` 정의를 일괄 적용하지 않는다. **실제 로그/측정 근거가 없으면 결과는 `계획`으로만 표기한다.**

## 5. 안전한 권장 실행 순서와 STOP 기준

**권장 순서: T1 → 정상화 → T2 → 정상화 → T3 → RDS/복제 안정화 → T4 → T5 → VPN/복제 안정화 → T7 → LE 원복 → T6 → T8 설명.**

### T6 사이트 DR 독립 실행 게이트 (다른 테스트 생략 시에도 필수)

T6를 앞선 모든 시연의 **성공 여부와 무조건 연동하지 않는다**. 시간 부족으로 T1·T2·T3·T4·T5·T7 일부를 **실행하지 않은 경우**에도, DB·네트워크·플랫폼 담당이 아래를 별도 확인하고 명시적 GO하면 T6 실행 가능하다.

- ROSA 1 / 온프렘 0, **RDS 유일 Writer**, 온프렘 DB 2대 read-only/GTID·IO/SQL·Lag 정상, Backend Ready 및 로그인·조회·저장 기준선 정상.
- VPN/DR NLB·`dr-health`·`primary-health` TLS/HC 정상. **인증서 T7을 수행했다면 LE 원복 후 실제 TLS·k6·Target 정상 증적 확인**.
- T3 또는 T5 등 이전 테스트를 실행했다면 모든 중단·복제·네트워크 이상이 **완전히 복구**됐다는 별도 증적 필요. **문제가 남은 테스트를 '생략'으로 바꿔 GO할 수 없다.**
- 기존 T5 DR 런북의 Fence/GTID 승격 중단 기준, HC 주입·권한 DNS·k6 측정, 승인된 트래픽 고정 계획·복구 담당이 모두 준비돼 있어야 한다. 하나라도 미충족이면 **T6 NO-GO**.

### 실제 촬영·비용 일정은 별도 확정

| 단계 | 작업 창/예상 소요 | 필수 중단·복구 확인 |
| --- | --- | --- |
| T1·T2 | **미확정** — 플랫폼 담당 기록 | Worker/Pod/배포 완전 정상화 |
| T3·T4 | **미확정** — DB 담당 기록 | RDS AZ 전환·역복제 재연결, PITR 격리 DB 비용/정리 |
| T5·T7 | **미확정** — 네트워크 담당 기록 | 이중 VPN 정상화, LE 복귀/TLS |
| **T6 사이트 DR** | **별도 우선 확보** — 팀 시간·예산 합의 | 독립 GO 게이트, DR 승격/트래픽 고정 |
| T8·증적 정리·종료 | **미확정** — 전원 기록 | 최종 Writer/State·비용·destroy 전제 |

현재 #33 일정이 그대로라면 **10/16 촬영·18:00 destroy 시작**, **10/15 저녁 비용 판단(누적 $430 이하 진행, $480 이상 즉시 중단 및 종료 우선)**과 충돌하는지 먼저 확인한다. 이는 기존 #33 기준을 인용한 것으로, 새 시연 일정이나 각 작업 소요시간을 확정한 것이 아니다. **시연 7개에 충분한 시간·예산이 확보되지 않으면 임의 연장하거나 복구 확인을 생략하지 않고**, T6 별도 GO·필수 증적에 우선순위를 둔다. 일정 변경은 담당자 합의·기록 후 반영한다.

- 서로 다른 종류의 장애를 동시에 주입하지 않는다. 특히 T3 Failover와 T5 VPN Down/T6 DB 승격은 절대 중첩하지 않는다.
- 테스트 중 예상 밖 교체·삭제·데이터 불일치·장기 복제 정지·중복 Writer·복구되지 않는 사용자 쓰기 장애 발견 시 즉시 **후속 단계 STOP, 담당자 합의 후 복구**.
- Failover/DR/Secret 변경/데이터 삭제는 **사전 승인된 런북, 작업 창, 즉시 복구 담당**이 없으면 실행하지 않는다. 이 PR은 명령 실행이나 Terraform Merge/Apply 승인으로 볼 수 없다.
- 영상은 T1~T7 시나리오별로 촬영하고 T0·복구 시각, Grafana/CloudWatch, Kubernetes·DB·VPN·TLS 측정값을 함께 남긴다. 원본 비공개 보관, 발표용 클립·캡처 분리, AWS 계정 ID·토큰·키·DB 자격 증명 노출 금지.

## 6. 팀 리뷰 요청 / 기존 결정과의 차이

1. **DB 담당 @0baba0:** #97에서 **의도적으로 제외했던 강제 Multi-AZ Failover 시연(T3)**을 새 시연안에 **조건부로 재추가**해도 되는지, 온프렘 두 DB GTID 역복제·Backend 연결 복구 확인 및 T4 PITR 격리 방식을 검토.
2. **네트워크 담당 @heejae0512:** T5 VPN 이중화와 T7 인증서 수동 전환(온프렘 경로 대상), T6 최종 DR/Route 53 전환 순서·원복·촬영 범위를 검토.
3. **플랫폼 담당 @o3orro:** T1/T2 장애 영향, RDS 연결 재시도·ROSA 상태·Grafana 지표, #122 실제 적용 GO/검증 상태 및 최종 자원 종료 영향 검토.
4. #63/#95 및 기존 #33 시연·종료 일정과 **별개인 전체 구축 완료 가정의 제안**이다. 기존 계획을 대체하려면 팀 합의 후 관련 문서와 일정·우선순위를 별도 변경한다. **#68의 Site DR 주 RTO는 변경하지 않았으며, #122의 기존 T5 이후 적용 순서를 변경하려면 별도 합의**가 필요하다.

### 관련 근거

- [#63 기존 T1~T7 확정 범위 및 Multi-AZ 테스트 제외](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/issues/63)
- [#95 PPT 목차·담당별 배치](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/issues/95)
- [#97 RDS Multi-AZ 적용 제안 — 강제 시연 제외](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/issues/97)
- [PR #122 RDS Multi-AZ / failover 이벤트 Draft](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/122)
- [#77 T7 인증서 CA 전환 팀 합의](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/issues/77)
- [#117 시나리오별 촬영·증적 정리](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/issues/117)
- [#68 T5 DR / T6 Failback 기존 역할 분담](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/issues/68)
