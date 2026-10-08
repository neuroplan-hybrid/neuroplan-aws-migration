# T4 런북 — Network HA: VPN 단일 터널 장애 (1008, r1: #67 리뷰 반영 / 10/8 리허설 반영)

> 담당 희재 · P0 · 시연 10/16 (T5 전) · 리전 ap-northeast-2
> 기준: #55 확정표 T4, 작업일지 0930 2.11·9장(updown 래퍼), `check_vpn_state_0930.sh`
> 비밀번호·PSK·계정 ID는 적지 않는다

## 1. 목적과 판정

| 항목 | 내용 |
|---|---|
| 주입 | 트래픽이 흐르는 터널 1개를 libreswan에서 down |
| 기대 동작 | 남은 터널로 ① DR 진입 경로(DR NLB → VPN → 온프렘) ② RDS → 온프렘 복제가 유지 |
| 측정 유형 | 연속성 (RTO가 아니라 "끊김 없음 / 끊긴 시간" 측정). 주 지표 = probe `dr` 열 (DR NLB → VPN → 온프렘 `/actuator/health/routing`, 1초). k6는 ROSA 경로 보조 지표 |
| PASS | ① 생존 터널 UP 유지 ② DR 경로가 생존 터널로 자동 전환 (주입 터널 VTI 라우트 제거, 생존 VTI 라우트만 남고 그 터널 `in`·`out` 증가) ③ probe `dr` **최대 연속 실패 시간을 측정·기록** ④ DR NLB Target healthy 유지 ⑤ RDS → 온프렘 복제 유지 (IO/SQL Yes, 주입 중 쓴 행 반영) ⑥ 복구 후 ESP 2·텔레메트리 UP 2 |
| 허용 끊김 시간 | **probe `dr` 최대 연속 실패 ≤ 35초** (제안, 10/8 리허설 실측 28초 + 여유, 팀 확인) |
| 중단 | 5장 (안전 기준, PASS와 별개) |

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
- VPN ID는 10/12 plan에서 VPN replace 0이면 그대로. 바뀌었으면 Infra VM에서 `aws ec2 describe-vpn-connections --region ap-northeast-2 --filters Name=state,Values=available --query 'VpnConnections[].VpnConnectionId' --output text`로 확인
- **정현 복제 상태 확인 후 T4 시작** (`Slave_IO_Running=Yes`, `Slave_SQL_Running=Yes`, Lag 0)
- 측정 PC 2곳 시각 비교: `date '+%F %T.%N %z'`

## 4. 진행 절차

### 4.1 측정 시작 (T0 3분 전)
```bash
# DevOps VM (heejae) — DR 진입 경로 1초 측정
cd ~/neuroplan-aws-migration && pwd \
&& scp -o ConnectTimeout=10 root@192.168.14.62:~/dr_nlb_dns.txt ~/ \
&& export DR_NLB_DNS="$(cat ~/dr_nlb_dns.txt)" \
&& echo "DR_NLB_DNS=${DR_NLB_DNS:?조회 실패 → 중단}" \
&& bash scripts/probe_1006.sh run 600
```
- `DR_NLB_DNS`는 고정값 대신 **AWS에서 현재 값을 조회** (NLB 교체 시 옛 DNS 측정 방지). DevOps VM `heejae`는 AWS 자격 증명·Terraform backend가 없어(10/8 예린 확인) Infra VM에서 먼저 조회:
```bash
# Infra VM (root) — 위 probe 실행 전에
aws elbv2 describe-load-balancers --region ap-northeast-2 --names neuroplan-dr-nlb --query 'LoadBalancers[0].DNSName' --output text | tee ~/dr_nlb_dns.txt
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
- 정한 대상을 변수로 고정 → **4.3 주입·4.4 관찰·4.5 복구 모두 같은 값 사용** (Infra VM 다른 창에서도 `source`로 재사용)
```bash
# Infra VM (root) — 아래 TUN만 실측 결과로 바꿔서 실행
TUN=aws-tun1        # 또는 aws-tun2
case "$TUN" in
  aws-tun1) VTI=vti1; SURV_TUN=aws-tun2; SURV_VTI=vti2; SURV_M=200 ;;
  aws-tun2) VTI=vti2; SURV_TUN=aws-tun1; SURV_VTI=vti1; SURV_M=100 ;;
  *) echo "⚠ TUN 값 오류: $TUN" ;;
esac
printf 'TUN=%s\nVTI=%s\nSURV_TUN=%s\nSURV_VTI=%s\nSURV_M=%s\n' "$TUN" "$VTI" "$SURV_TUN" "$SURV_VTI" "$SURV_M" | tee ~/t4_target.env
```

### 4.3 주입 (T0)
```bash
# Infra VM (root) — 4.2에서 정한 대상 사용
source ~/t4_target.env && echo "주입 대상 $TUN ($VTI) / 생존 $SURV_TUN ($SURV_VTI)"
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
| 라우트 | Infra VM | 4.1 로그에서 **주입 터널(`$VTI`) 라우트 제거**, 생존 VTI(`$SURV_VTI m$SURV_M`)만 남음 |
| 생존 터널 트래픽 | Infra VM | 4.1 로그에서 `$SURV_TUN`의 `in`·`out` 증가 |
| updown 로그 | Infra VM | `journalctl -t neuroplan-vti-updown --since -5min \| grep "$TUN"` → `$TUN down: … $VTI removed` |
| DR 경로 | DevOps VM | probe `dr` 열 200 유지 |
| 텔레메트리 | AWS CLI | 아래 명령 → 주입 터널 Outside IP DOWN, 생존 터널 UP (반영 수 분) |
| DR NLB Target | AWS CLI | 아래 명령 → `healthy` 유지 |
| 복제 | 정현 (db-primary) | `SHOW SLAVE STATUS\G` IO/SQL Yes, Lag / RDS에 테스트 행 1건 쓰기 → 온프렘 재조회 |

```bash
# AWS CLI — Infra VM (root), ap-northeast-2 (DevOps VM heejae는 AWS 자격 증명 없음)
aws ec2 describe-vpn-connections --region ap-northeast-2 --vpn-connection-ids vpn-0cba1687403805b8a \
  --query 'VpnConnections[0].VgwTelemetry[].[OutsideIpAddress,Status,LastStatusChange]' --output table
TG=$(aws elbv2 describe-target-groups --region ap-northeast-2 --names neuroplan-dr-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --region ap-northeast-2 --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
```

### 4.5 복구
```bash
# Infra VM (root) — 주입한 같은 터널 복구
source ~/t4_target.env && ipsec auto --up "$TUN" \
&& sleep 5 && bash check_vpn_state_0930.sh --aws vpn-0cba1687403805b8a; echo "exit=$?"
```
- 기대: ESP 2, 라우트 vti1 100·vti2 200 모두 존재 (updown `$TUN up` 로그), `FAIL 0` (텔레메트리 UP 2는 수 분 뒤)
- `$TUN`이 `retransmission`만 반복하면 0930 3.3(듀얼 WAN 회선 불일치) → `leftikeport` 확인, 다시 `--up`. **T5 전에 반드시 ESP 2 복구**

### 4.6 측정 종료·요약
```bash
# DevOps VM (heejae) — probe Ctrl+C 후
cd ~/neuroplan-aws-migration && pwd
T0="14:32:10"            # ~/t4_t0.log의 시각(HH:MM:SS)으로 교체
CSV="$(ls -t probe_*.csv | head -1)" && echo "$CSV"
bash scripts/probe_1006.sh summary "$CSV" "$T0"
# dr 열 최대 연속 실패 시간 (11번째 열 dr_code가 200이 아닌 행이 연속된 최대 길이 = 초)
awk -F, 'NR>1 { if ($11 != "200") { c++; if (c > m) { m = c; e = $1 } } else c = 0 }
         END { printf "dr 최대 연속 실패: %d초 (마지막 실패 %s)\n", m, (m ? e : "-") }' "$CSV"
```
- 기록: `dr HC 비정상 N행`, **최대 연속 실패 시간**, 측정 공백, 터널 로그 전환 시각, 텔레메트리 DOWN 반영 시각, 복제 Lag 최대값

## 5. 중단 기준 (안전 기준, PASS 판정과 별개)
- probe `dr` 열이 **60초 연속 실패** → 즉시 4.5 복구 (장애 시연 실패로 기록, 원인 분석은 시연 후)
  - 10/8 리허설에서 정상 동작인데도 AWS 쪽 전환에 약 29초가 걸림 → 30초 기준은 정상 동작과 구분이 안 돼 60초로 조정 (제안)
- 남은 터널도 DOWN이 되면 즉시 4.5 (두 터널 동시 단절)
- 복제 IO 스레드 중단 → 정현 판단, 4.5 복구 후 재개 확인

## 6. 팀 합의 (10/8 카톡, 예린 동의)
1. **판정 지표**: probe `dr` 열(VPN 경유 1초)로 판정. Cutover 후 온프렘 DB는 읽기 전용이라 DR 경로 k6는 쓰기 실패가 섞임 → k6는 ROSA 경로 보조 지표
2. **주입 방식**: `ipsec auto --down`으로 한 터널만 의도적으로 내림. 설명은 "물리 회선 장애"가 아니라 "VPN 단일 터널 Down 시 남은 터널로 경로 유지". 회선 차단형(UDP 4500 차단, DPD 감지)은 범위 밖
3. **리허설**: 10/9~11 원격 1회 (복제 확인 제외) → probe 기준 전환 공백(초) 확인
4. **순서**: 10/16 정현 복제 상태 확인 → T4 진행

## 7. 발표 증적 (발표증적 5.4)
- **주입 터널 / 생존 터널 / 남은 VTI metric** 실제 결과 표 (예: `aws-tun1` DOWN / `aws-tun2` UP / `vti2 m200`), 텔레메트리 표, probe summary(`dr` 실패 행 수·**연속 실패 시간**), 터널 로그 전환 구간 캡처, Target healthy 표, 복제 상태, updown 로그 1줄

## 8. 10/8 리허설 결과 (ROSA OFF, DR 경로만, 복제 확인 제외)

| 항목 | 결과 |
|---|---|
| 평소 경로 | **비대칭**: out = `aws-tun1`(vti1 m100) / in = `aws-tun2`(AWS VGW 선택) |
| 주입 | T0 12:14:53.984 `ipsec auto --down aws-tun2` (in 쪽 터널, 4.2 기준) |
| 온프렘 전환 | 약 1초 (updown 래퍼 vti2 라우트 삭제) |
| AWS 전환 | **약 29초** (12:15:23 `aws-tun1 in` 증가 시작). IKE Delete를 보냈어도 VGW가 그동안 죽은 터널로 전송 → AWS 쪽 감지(DPD 추정) 시간이 병목 |
| probe `dr` | **최대 연속 실패 28초** + 전환 직후 1회 (총 29행 / 369행, 측정 공백 0) |
| 복구 | 12:16:55.97 `aws-tun2` UP → 약 1초 만에 AWS가 in을 tun2로 되돌림, **실패 0** |
| 텔레메트리 | 복구 직후 UP 1 → 약 3분 뒤 UP 2 |

- 본 시연(10/16)에서도 끊김은 약 30초가 나올 것으로 보고 설명: "장애 감지는 AWS 쪽 타이머에 좌우, 사람 개입 없이 자동 복구, 복구 방향은 무중단"
- 남은 확인: 본 시연 때 DR NLB Target health(4.4), 복제 상태(정현)
