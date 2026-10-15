# T5 VPN 단일 터널 장애 (구 T4) — 본 시연 실측 결과 (2026-10-15)

> **판정: 실측 범위 내 PASS (네트워크 기준).** Site-to-Site VPN 이중 터널 중 `aws-tun2`를 중단했을 때, 온프렘은 즉시 남은 터널(`aws-tun1`)로 전환했고 AWS 쪽도 약 20~21초 뒤 `aws-tun1`로 전환했다. DR 경로(probe `dr`)의 **연속 실패는 20표본(약 21초)** 으로 판정 기준(≤35초)을 만족했고, ROSA 앱 경로는 영향이 없었다. 중단 시간 약 3분 9초 동안 정현님 두 DB 연속 기록에서 이상 표본은 없었다.
>
> **중요:** 이 시험은 `ipsec auto --down`으로 SA를 **정상 종료(종료 알림 전송)** 한 시험이다. 알림 없이 회선이 끊기는 실제 장애와 AWS 쪽 감지 방식이 같다고 단정하지 않는다.

번호: 10/15 18:50 이후 [통합 장애 시연안 PR #123](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123)의 Tn 기준을 따른다. VPN 단일 터널 장애는 **T5**(이전 번호 T4)이며, 실측 시점(10/15 18:02)에는 이전 번호로 불렸다. 이 PR은 실측 기록만 추가하며 Terraform·클러스터·방화벽 등 운영 설정을 변경하지 않는다. 절차 근거는 `docs/runbooks/vpn_tunnel_failure_1008.md`(#67)이다.

## 1. 환경과 사전 확인

| 항목 | 실제 확인 |
| --- | --- |
| 환경 | AWS ap-northeast-2 / ROSA 운영 중(Route 53 ROSA 1 / 온프렘 0) / 온프렘 Infra VM(libreswan CGW) |
| 터널 구성 | `aws-tun1`(`vti1`, 라우트 metric 100) / `aws-tun2`(`vti2`, metric 200). 평소 경로는 비대칭: 온프렘→AWS `aws-tun1`, AWS→온프렘 `aws-tun2` |
| 주입 대상 | **`aws-tun2`** (평소 AWS→온프렘 `in` 트래픽이 흐르는 터널). 생존 터널 `aws-tun1` |
| 사전 점검 | `check_vpn_state_0930.sh --aws` FAIL 0·exit 0, 시각 동기화 yes, ESP 2개 확인 후 주입 |
| 복제 사전 (정현) | 17:42 복제 정상, 17:51 두 DB `check_db_rds_path` exit 0, 5초 시험 통과. 주입 1분 전(18:01:31) 이후 주입 가능 확인 |
| 관측 도구 | DevOps VM `probe_1006.sh`(1초 간격, 열 11 `dr` = DR NLB → VPN → 온프렘 `dr-health` 응답 코드), Infra VM 터널 in/out 로그·HC_DR 로그, 정현님 두 DB 연속 기록(#116 스크립트, 약 1초 간격) |
| 판정 기준 (런북) | probe `dr` **최대 연속 실패 ≤35초**, 중단 기준: 60초 연속 실패 또는 두 터널 동시 DOWN. 앱 경로는 ROSA 유지, HC_DR이 Unhealthy가 돼도 서비스 영향 아님 |

참고: DevOps VM(192.168.44.21)은 사전 단계에서 MariaDB 오류 1129(반복 연결 오류로 호스트 차단)가 있어 시연 중 반복 TCP 점검에서 제외했다(원인 확인은 정현님 담당). 복제 소스(.51/.52)와는 별개다.

## 2. 장애 주입·복구 방법

~~~bash
# Infra VM / root — 주입 (T0 기록 후)
echo "T0 $(date '+%F %T.%3N %z')" | tee -a ~/t4_t0.log
ipsec auto --down aws-tun2

# Infra VM / root — 복구 (T0 + 3분 이후)
ipsec auto --up aws-tun2
~~~

- 변경하지 않은 항목: Terraform, AWS 리소스, Route 53 가중치, 방화벽 정책, `aws.conf`.
- 복구는 사람이 명령으로 수행했다(자동 복구 시간이 아니다). 복구 이전에 이미 AWS 쪽이 `aws-tun1`로 전환해 DR 경로는 회복돼 있었다.

## 3. 실측 타임라인 (2026-10-15 KST)

| 시각 | 확인 내용 | 근거 |
| --- | --- | --- |
| 17:46~ | probe(`probe_1015-1746.csv`)·터널 로그·HC_DR 로그 기록 시작 | 파일 첫 줄 |
| 18:00:27 / 18:00:31 | 정현님 db-primary / db-replica 연속 기록 시작 | 정현 보고 |
| **18:02:17.258** | **T0: `aws-tun2` 중단.** pluto `terminating SAs using this connection`, IKE SA 삭제·알림 전송. updown `aws-tun2 down: 10.20.0.0/16 dev vti2 removed (rc=0)` | `~/t4_t0.log`, journalctl, updown 로그 |
| 18:02:18~18:02:37 | probe `dr` 연속 실패 20표본(`000`). 터널 로그에서 `aws-tun1 in=0` 유지, out은 `aws-tun1`로 계속 증가 | probe CSV, 터널 로그 |
| **18:02:38.005** | probe `dr` 첫 회복(200) | probe CSV |
| **18:02:38.340** | `aws-tun1 in` 0 → 28,994 (AWS가 `aws-tun1`로 돌려주기 시작). 직전 표본 18:02:37.332는 0 | 터널 로그 |
| 18:03~18:05 | DR NLB Target `192.168.24.100` healthy(3회 조회), AWS VPN 텔레메트리 두 터널 UP(주입 약 1·2분 시점) | 조회 출력 |
| **18:05:26.9** | **복구:** `ipsec auto --up aws-tun2` 완료, updown `aws-tun2 up … metric 200, rp_filter=2` (단일 터널 유지 약 3분 9초) | updown 로그 |
| 18:05:32 | `check_vpn_state`: ESP 2, `vti1` m100 / `vti2` m200, rp_filter 2·2, firewalld OK, **텔레메트리 UP 1(FAIL 1건)** | 스크립트 출력 |
| 18:07 | 재점검: 텔레메트리 UP 2, FAIL 0 | 스크립트 출력 |
| 18:08:40 / 18:08:41 | 정현님 두 DB 기록 종료(복구 후 3분 이상 유지) | 정현 보고 |
| 약 18:13 | probe 종료(Ctrl+C) | CSV 수정 시각 |

터널 로그 발췌 (1초 간격 누적 바이트, 값은 터널별 `in`/`out`):

~~~text
18:02:17.159 aws-tun1 in=0 out=20133328  aws-tun2 in=303823 out=0 | vti1 m100 | vti2 m200
18:02:18.167 aws-tun1 in=0 out=20135556                            | vti1 m100
18:02:37.332 aws-tun1 in=0 out=20143296                            | vti1 m100
18:02:38.340 aws-tun1 in=28994 out=20171360                        | vti1 m100
~~~

## 4. probe 결과 (`dr` 경로 경계 구간)

| 항목 | 결과 |
| --- | --- |
| 직전 성공 | 18:02:17.003 (`dr`=200, 56ms) |
| 첫 실패 | 18:02:18.003 (T0 이후 첫 표본) |
| 마지막 실패 | 18:02:37.003 |
| 첫 회복 | **18:02:38.005** (228ms → 이후 87·43·47ms) |
| `dr` 연속 실패 | **20표본, 직전 성공~첫 회복 약 21초** (≤35초 기준 통과, 60초 중단 기준 미접근) |
| 전체 `dr` 비200 표본 | 위 20개뿐 (복구 시점 18:05:26 전후 추가 실패 없음) |
| `app`·`rosa` 경로 | 경계 구간(18:02:14~18:02:41) 모두 200 |
| 실패 표본 응답 시간 | 약 789ms로 거의 일정 (원인 미확인) |

AWS 쪽 전환 시간(주입 후 `aws-tun1 in` 증가까지)은 **약 20~21초**로, probe `dr` 회복 시각과 일치했다. 참고로 같은 방식(`aws-tun2` 중단)의 이전 리허설 값은 10/8 약 29초, 10/14 약 11.9초였다(발표증적·작업일지 기록). **같은 방식인데 값이 매번 다른 이유는 확인하지 못했으며 추정하지 않는다.**

## 5. HC_DR·DR NLB·텔레메트리 관찰

| 항목 | 결과 |
| --- | --- |
| HC_DR 로그 (`t4_hcdr_1015-1747.log`, 296줄) | 주입 구간(18:02:17~18:05:26) `16 Success` 유지. `15 Success`는 17:48:18·17:52:13·17:55:26·18:01:06·18:01:34·18:06:45·18:07:45·18:10:02의 8줄로 **주입 구간 안에는 없고** 시험 전후에도 나타난 간헐 변동(원인 미확인). 이 로그는 Success 개수만 기록 |
| DR NLB Target | `192.168.24.100` healthy 유지 (18:03·18:04·18:05 조회) |
| CloudWatch (`AWS/NetworkELB`, DR TG, 1분 단위 18:00~18:09) | `UnHealthyHostCount` 전 구간 0 (`HealthyHostCount`는 3으로 표시되나 지표 합산 방식은 확인하지 않아 판정에 쓰지 않음) |
| VPN 텔레메트리 | 주입 약 1·2분 시점 두 터널 UP(최종 상태 변경 시각은 오전 값 그대로), 복구 6초 후 UP 1, 약 1분 뒤 UP 2. 반영 시점은 정확히 모름 |

**해석:** 20초 끊김 동안 HC_DR·NLB Target·텔레메트리는 이상을 보이지 않았다. 따라서 이 시험의 판정 지표는 계획대로 probe `dr`과 터널 in/out이며, 헬스체크가 이번 끊김을 감지하지 못한 이유는 이 기록만으로는 알 수 없다. 복구 6초 후 `UP 1`은 AWS 텔레메트리 반영 지연으로 추정하나 확정하지 않는다.

## 6. 복제 영향 (정현님 두 DB 연속 기록)

| 항목 | db-primary | db-replica |
| --- | --- | --- |
| 기록 구간 | 18:00:27 ~ 18:08:40 | 18:00:31 ~ 18:08:41 |
| 전체 표본 / 조회 오류 | 475 / 0 | 473 / 0 |
| 주입 구간 18:02:17.258~18:05:26.900 | 183표본, 이상 0 | 183표본, 이상 0 |
| 주입 구간 상태 | IO/SQL Yes, Lag 0, 오류 번호 0, `read_only=1` 유지 | 동일 |
| 종료 시 | 두 DB Applied GTID 일치 | |

주입 구간에 오류 1129는 관찰되지 않았다. **약 1초 간격 관측이므로 표본 사이의 순간적 현상까지 없었다는 의미는 아니다.**

## 7. 판정

| 검증 항목 | 결과 |
| --- | --- |
| 온프렘 라우트 전환 (남은 터널로) | **PASS** (T0와 같은 초, updown 로그) |
| AWS 쪽 전환 / DR 경로 회복 | **PASS** (T0 후 약 20~21초, probe `dr` 연속 실패 20표본 ≤35초) |
| ROSA 앱 경로 영향 | **영향 없음** (`app`·`rosa` 200 유지) |
| 복제 연속성 | **이상 표본 0** (두 DB 각 183표본, 약 1초 간격) |
| 복구 후 상태 | **PASS** (ESP 2, `vti1`/`vti2` 라우트 복귀, rp_filter 2·2, `check_vpn_state` FAIL 0, 텔레메트리 UP 2) |
| 복구 시점 끊김 | **없음** (복구 후 `dr` 비200 표본 0) |
| 알림 없는 회선 단절 / 두 터널 동시 장애 / 다중 사용자 무중단·User RTO | **수행하지 않음·미검증** |

**발표용 표현:** "VPN 이중 터널 중 하나를 중단하자 온프렘은 즉시 남은 터널로 전환했고, AWS 쪽도 약 20초 뒤 같은 터널로 전환해 DR 경로가 회복됐습니다. 이 동안 운영 앱 경로(ROSA)는 영향이 없었고, 두 DB의 복제 기록에서도 이상 표본은 없었습니다. 전환 시간은 같은 방식으로 시험해도 회차마다 달랐습니다(29초 → 11.9초 → 약 20초)."

## 8. 한계

- 주입이 정상 종료 알림을 보내는 방식(`ipsec auto --down`)이다. 실제 회선 단절은 미시험.
- 관측점이 DevOps VM probe 1곳과 Infra VM 로그 기준이다. 다중 사용자 무중단·User RTO·전체 5xx 0건은 주장하지 않는다. T5는 DNS 전환이 없어 Control RTO도 발생하지 않는다.
- 복제 기록은 약 1초 간격이다.
- `ipsec auto --up` 출력에 `vti interface "vti2" already exists with conflicting setting (perhaps need vti-sharing=yes?` 경고가 있었으나 Child SA 수립·라우트 복귀·updown `rc=0`은 정상이었다(원인 미확인, 10/15 오전 `aws-tun1` 복구 때도 같은 경고).
- `probe_1006.sh summary` 요약 출력 전문과 화면 캡처는 이 PR에 첨부하지 않았다(아래 증적 참조).

## 9. 증적 경로 / 추후 보강

- Infra VM: `~/t4_tunnel_1015-1746.log`(125,612 bytes), `~/t4_hcdr_1015-1747.log`(296줄), `~/t4_t0.log` — 이 PR에는 미업로드
- DevOps VM: `~/neuroplan-aws-migration/probe_1015-1746.csv`(213,095 bytes) — 이 PR에는 미업로드(`git add` 금지 대상)
- 정현님 두 DB 연속 기록 파일은 정현님 측 보관
- 화면 캡처(주입 줄·probe 실패 구간·터널 in/out 전환·복구 점검)는 Notion `발표용 문서 캡쳐` 5.4에 보관 예정. 공인 IP·VPN ID·헬스체크 ID는 마스킹한다.
- 이 문서에는 공인 IP·VPN 연결 ID·헬스체크 ID·RDS 엔드포인트를 적지 않았다.

관련: [T2 결과 PR #125](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/125), [T1 결과 PR #124](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/124), [rp_filter 고정 스크립트 PR #126](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/126)(머지됨, 운영 적용은 별도 합의), [통합 시연안 PR #123](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123).
