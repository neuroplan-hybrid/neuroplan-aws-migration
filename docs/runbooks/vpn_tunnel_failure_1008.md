# T4 런북 — Network HA: VPN 단일 터널 장애 (1008)

> 담당 희재 · P0 · 시연 10/16 (T5 전) · 리전 ap-northeast-2
> 기준: #55 확정표 T4, 작업일지 0930 2.11·9장(updown 래퍼), `check_vpn_state_0930.sh`
> 비밀번호·PSK·계정 ID는 적지 않는다

## 1. 목적과 판정

| 항목 | 내용 |
|---|---|
| 주입 | 트래픽이 흐르는 터널 1개를 libreswan에서 down |
| 기대 동작 | 남은 터널로 ① DR 진입 경로(DR NLB → VPN → 온프렘) ② RDS → 온프렘 복제가 유지 |
| 측정 유형 | 연속성 (RTO가 아니라 "끊김 없음 / 끊긴 시간" 측정). 주 지표 = probe `dr` 열 (DR NLB → VPN → 온프렘 `/actuator/health/routing`, 1초). k6는 ROSA 경로 보조 지표 |
| PASS | ① probe `dr` 열 실패 0행 (또는 허용치 이하, 아래 5장) ② DR NLB Target healthy 유지 ③ 복제 `Slave_IO_Running=Yes` 유지, 주입 중 쓴 행이 온프렘에 반영 ④ 복구 후 ESP 2·텔레메트리 UP 2 |

## 2. 왜 끊기지 않는가 (발표 설명용)

```
온프렘 → AWS : 10.20.0.0/16 dev vti1 metric 100 (우선) / dev vti2 metric 200 (대기)
              터널 down → updown 래퍼 down-client가 해당 vti 라우트 삭제 → 남은 vti로 즉시 전환 (0930 9.3)
AWS → 온프렘 : VGW가 정적 라우트(192.168.24.0/24, 192.168.44.0/24)를 UP인 터널로 전송
              IKE 종료 통보(Delete)를 받으면 해당 터널을 DOWN으로 보고 다른 터널 사용
비대칭 경로   : vti rp_filter=2(loose) → 갈 때·올 때 터널이 달라도 응답이 버려지지 않음 (0930 3.5)
```

- 1차 비교: 1차는 HAProxy VIP 하나, 2차는 사이트 간 연결 자체도 이중화

## 3. 사전 조건 (10/16 T4 시작 전)

```bash
# Infra VM (root) — 프롬프트 [root@infra ~] 확인
cd ~ && bash check_vpn_state_0930.sh --aws vpn-0cba1687403805b8a; echo "exit=$?"
timedatectl | grep -i synchronized
```
- 기대: `FAIL 0건`, `exit=0` (ESP 2, 라우트 vti1 100·vti2 200, rp_filter 2·2, 텔레메트리 UP 2), `System clock synchronized: yes`
- VPN ID는 10/12 plan에서 VPN replace 0이면 그대로. 바뀌었으면 `terraform output vpn_connection_id`로 교체
- **정현 복제 상태 확인 후 T4 시작** (`Slave_IO_Running=Yes`, `Slave_SQL_Running=Yes`, Lag 0)
- 측정 PC 2곳 시각 비교: `date '+%F %T.%N %z'`

## 4. 진행 절차

### 4.1 측정 시작 (T0 3분 전)
```bash
# DevOps VM (heejae) — DR 진입 경로 1초 측정
cd ~/neuroplan-aws-migration && pwd \
&& export DR_NLB_DNS=neuroplan-dr-nlb-450961729f2f0929.elb.ap-northeast-2.amazonaws.com \
&& bash scripts/probe_1006.sh run 600
```
- `dr` 열 = DR NLB → VPN → 온프렘 `dr-health` (VPN을 반드시 지나는 경로)
- 10/16에는 ROSA LB DNS도 넣어 `ROSA_LB_DNS=… ` 함께 기록 (ROSA 쪽은 VPN과 무관 → 대조군)

```bash
# Infra VM (root) — 터널별 상태 1초 기록 (별도 창)
while :; do
  printf '%s ' "$(date +%T.%3N)"
  ipsec trafficstatus 2>/dev/null | sed -nE 's/.*"(aws-tun[12])".*inBytes=([0-9]+), outBytes=([0-9]+).*/\1 in=\2 out=\3/p' | tr '\n' ' '
  ip -4 route show 10.20.0.0/16 | awk '{printf "| %s m%s ", $3, $NF}'
  echo
  sleep 1
done | tee ~/t4_tunnel_$(date +%m%d-%H%M).log
```

### 4.2 트래픽이 흐르는 터널 확인
- 위 로그에서 10초 동안 `in`·`out` 바이트가 늘어나는 터널을 확인
  - `out` 증가 = 온프렘 → AWS (보통 vti1, metric 100)
  - `in` 증가 = AWS → 온프렘 (VGW가 고른 터널, 실측으로 확인)
- **주입 대상 = `in`이 늘어나는 터널** (DR NLB·RDS에서 오는 트래픽이 실제로 지나는 쪽). 둘이 다르면 `in` 쪽을 우선하고 기록

### 4.3 주입 (T0)
```bash
# Infra VM (root) — 예: 대상이 aws-tun1
TUN=aws-tun1
esp="$(ipsec trafficstatus | grep -c 'type=ESP')"
if [[ "$esp" == "2" ]]; then
  echo "T0 $(date '+%F %T.%3N %z')" | tee -a ~/t4_t0.log
  ipsec auto --down "$TUN"
else
  echo "⚠ ESP ${esp}개 → 두 터널이 모두 UP일 때만 주입 (중단)"
fi
```
- 가드: ESP가 2개가 아니면 실행하지 않음 (두 터널 동시 장애 방지)
- `auto=start`는 시작 시에만 연결 → `--down` 후에는 `--up` 전까지 내려간 상태 유지 (AWS 터널 기본 시작 동작은 대기)

### 4.4 관찰 (T0 ~ T0+5분)

| 확인 | 위치 | 명령 / 기대 |
|---|---|---|
| 라우트 | Infra VM | 4.1 로그에 `vti2 m200`만 남음 |
| 남은 터널 트래픽 | Infra VM | 4.1 로그에서 남은 터널 `in`·`out` 증가 |
| updown 로그 | Infra VM | `journalctl -t neuroplan-vti-updown --since -5min` → `aws-tun1 down: … removed` |
| DR 경로 | DevOps VM | probe `dr` 열 200 유지 |
| 텔레메트리 | AWS CLI | 아래 명령 → 대상 터널 DOWN, 반대 UP (반영 수 분) |
| DR NLB Target | AWS CLI | 아래 명령 → `healthy` 유지 |
| 복제 | 정현 (db-primary) | `SHOW SLAVE STATUS\G` IO/SQL Yes, Lag / RDS에 테스트 행 1건 쓰기 → 온프렘 재조회 |

```bash
# AWS CLI (DevOps VM 또는 Infra VM), ap-northeast-2
aws ec2 describe-vpn-connections --region ap-northeast-2 --vpn-connection-ids vpn-0cba1687403805b8a \
  --query 'VpnConnections[0].VgwTelemetry[].[OutsideIpAddress,Status,LastStatusChange]' --output table
TG=$(aws elbv2 describe-target-groups --region ap-northeast-2 --names neuroplan-dr-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --region ap-northeast-2 --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
```

### 4.5 복구
```bash
# Infra VM (root)
ipsec auto --up aws-tun1
sleep 5 && bash check_vpn_state_0930.sh --aws vpn-0cba1687403805b8a; echo "exit=$?"
```
- 기대: ESP 2, 라우트 vti1 100·vti2 200 복구 (updown `up` 로그), `FAIL 0` (텔레메트리 UP 2는 수 분 뒤)
- tun1이 `retransmission`만 반복하면 0930 3.3(듀얼 WAN 회선 불일치) → `leftikeport` 확인, 다시 `--up`. **T5 전에 반드시 ESP 2 복구**

### 4.6 측정 종료·요약
```bash
# DevOps VM (heejae) — probe Ctrl+C 후
cd ~/neuroplan-aws-migration && bash scripts/probe_1006.sh summary $(ls -t probe_*.csv | head -1) <T0 HH:MM:SS>
```
- 기록: `dr HC 비정상 N행`, 측정 공백, 터널 로그 전환 시각, 텔레메트리 DOWN 반영 시각, 복제 Lag 최대값

## 5. 중단 기준
- probe `dr` 열이 **30초 연속 실패** → 즉시 4.5 복구 (장애 시연 실패로 기록, 원인 분석은 시연 후)
- 남은 터널도 DOWN이 되면 즉시 4.5 (두 터널 동시 단절)
- 복제 IO 스레드 중단 → 정현 판단, 4.5 복구 후 재개 확인

## 6. 팀 합의 (10/8 카톡, 예린 동의)
1. **판정 지표**: probe `dr` 열(VPN 경유 1초)로 판정. Cutover 후 온프렘 DB는 읽기 전용이라 DR 경로 k6는 쓰기 실패가 섞임 → k6는 ROSA 경로 보조 지표
2. **주입 방식**: `ipsec auto --down`으로 한 터널만 의도적으로 내림. 설명은 "물리 회선 장애"가 아니라 "VPN 단일 터널 Down 시 남은 터널로 경로 유지". 회선 차단형(UDP 4500 차단, DPD 감지)은 범위 밖
3. **리허설**: 10/9~11 원격 1회 (복제 확인 제외) → probe 기준 전환 공백(초) 확인
4. **순서**: 10/16 정현 복제 상태 확인 → T4 진행

## 7. 발표 증적 (발표증적 5.4)
- **Tunnel 1 Down / Tunnel 2 Up** 텔레메트리 표, probe summary(`dr` 실패 행 수·**연속 실패 시간**), 터널 로그 전환 구간 캡처, Target healthy 표, 복제 상태, updown 로그 1줄
