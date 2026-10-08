# T7 런북 — DR 운영 중 온프레미스 LB 전환 (초안 1008)

> 담당 희재 · **P2·부록** · 시연 10/16 (T5로 DR 운영 상태가 된 뒤, 시간 여유가 있을 때만) · 리전 ap-northeast-2
> 기준: #55 확정표 T7, 1차 PPT 3-17(LB Failover), 작업일지 0930 11장(DMZ NIC·LB 반환 경로), 런북 형식은 T4(#67)와 같음
> 비밀번호·계정 ID는 적지 않는다

## 1. 목적과 판정

| 항목 | 내용 |
|---|---|
| 상황 | T5 이후 Route 53이 온프렘(DR)을 응답 → 사용자 트래픽이 DR NLB → VPN → Infra VM → VIP `192.168.24.100` → HAProxy로 들어오는 중 |
| 주입 | VIP를 가진 LB1에서 `systemctl stop keepalived` (VM·HAProxy는 살아 있고 VRRP만 중단) |
| 기대 동작 | VIP가 LB2로 이동 + GARP → Infra VM이 ARP로 새 VIP 주인을 찾음 → DR 진입 경로 유지 |
| 측정 유형 | 연속성 (k6 실패 수, probe `dr` 최대 연속 실패 시간) |
| PASS | ① VIP가 LB2로 이동 ② Infra VM ARP의 VIP MAC이 LB2로 바뀜 ③ probe `dr` 최대 연속 실패 시간 측정·기록 ④ k6 로그인·조회·저장 실패 수 기록 (목표 0) ⑤ DR NLB Target healthy 유지 ⑥ 복구 후 VIP가 LB1로 돌아오고 같은 지표 기록 |
| 중단 | probe `dr` 30초 연속 실패, VIP가 양쪽 모두 없음 / 양쪽 모두 있음(split-brain) → 즉시 4.5 |

## 2. 왜 끊기지 않는가 (발표 설명용)

```
DR NLB(AWS) → VPN → Infra VM ens161(192.168.24.62, DMZ NIC) ─ ARP ─→ VIP 192.168.24.100 (현재 주인 LB)
                                                                      ├ LB1 ens192 (MASTER, priority 110)
                                                                      └ LB2 ens192 (BACKUP, priority 100)
- Infra VM은 특정 LB IP를 넥스트홉으로 쓰지 않고 같은 L2에서 VIP를 ARP로 찾음 → VIP가 옮겨가도 경로 유지 (시나리오 4.6)
- 응답 경로: LB1·LB2 모두 10.20.0.0/16 via 192.168.24.62 (0930 11장) → 어느 LB가 VIP를 가져도 대칭 경로
- 1차 실측: MASTER 상실 → LB2 인수 약 1초, LB1 복귀 → 재탈환 약 4초 (1차 PPT 3-17, graceful advert)
```

- 1차 대비 차이: 1차는 학원망 안에서 `curl --resolve`로 확인 → 2차는 **AWS에서 VPN을 지나 들어오는 실제 DR 트래픽** 중에 전환

## 3. 사전 조건 (T7 시작 전)

```bash
# lb1, lb2 각각 (root) — 상태·반환 경로
hostname -s; systemctl is-active keepalived haproxy
ip -4 addr show ens192 | grep -E '192\.168\.24\.(100|1[12])'
ip route get 10.20.0.10        # 기대: via 192.168.24.62 dev ens192
```
- 기대: 두 대 모두 keepalived·haproxy `active`, VIP는 **LB1에만**, 두 대 모두 `via 192.168.24.62`

```bash
# Infra VM (root) — 현재 VIP 주인 MAC 기록
ip neigh show 192.168.24.100 dev ens161
```
- 기대: LB1 `ens192` MAC (0930 기준 `00:0c:29:87:49:88`)
- T5 완료 상태: Route 53이 온프렘 응답 중, k6가 DR 경로로 정상 (T5 측정을 그대로 이어서 사용 가능)

## 4. 진행 절차

### 4.1 측정 시작 (주입 2분 전)
```bash
# DevOps VM (heejae) — DR 진입 경로 1초 측정 (T5에서 이어서 돌고 있으면 생략)
cd ~/neuroplan-aws-migration && pwd \
&& export DR_NLB_DNS="$(cd envs/prod && terraform output -raw dr_nlb_dns_name 2>/dev/null)" \
&& echo "DR_NLB_DNS=${DR_NLB_DNS:?terraform output 실패 → 중단}" \
&& bash scripts/probe_1006.sh run 300
```
- k6: T5에서 시작한 측정을 그대로 유지 (app이 DR을 가리키는 중이므로 로그인·조회·저장 전체가 DR 경로)

```bash
# Infra VM (root) — VIP 주인 MAC 1초 기록 (별도 창)
while :; do
  printf '%s %s\n' "$(date +%T.%3N)" "$(ip neigh show 192.168.24.100 dev ens161 | awk '{print $3, $NF}')"
  sleep 1
done | tee ~/t7_arp_$(date +%m%d-%H%M).log
```

### 4.2 주입 (T_inject)
```bash
# lb1 (root) — 호스트 가드
if [[ "$(hostname -s)" == lb1 ]]; then
  echo "T_inject $(date '+%F %T.%3N %z')" | tee -a ~/t7_t0.log
  systemctl stop keepalived
else
  echo "⚠ lb1 아님($(hostname -s)) → 중단"
fi
```

### 4.3 관찰 (T_inject ~ +2분)

| 확인 | 위치 | 명령 / 기대 |
|---|---|---|
| VIP 이동 | lb2 | `ip -4 addr show ens192 \| grep 192.168.24.100` → 있음 |
| VIP 해제 | lb1 | 같은 명령 → 없음 |
| ARP 갱신 | Infra VM | 4.1 로그에서 MAC이 LB1 → LB2로 바뀐 시각 |
| Keepalived 로그 | lb2 | `journalctl -u keepalived --since -3min` → `Entering MASTER STATE` 시각 |
| DR 경로 | DevOps VM | probe `dr` 열 |
| 사용자 | 측정 PC | k6 실패 수 |
| DR NLB Target | AWS CLI | T4 런북 4.4와 같은 명령 → `healthy` 유지 |

### 4.4 복구 측정 (LB1 복귀 = 두 번째 전환)
```bash
# lb1 (root)
[[ "$(hostname -s)" == lb1 ]] && { echo "T_restore $(date '+%F %T.%3N %z')" | tee -a ~/t7_t0.log; systemctl start keepalived; }
```
- 기대: LB1이 priority 110으로 preempt → VIP 재탈환 (1차 약 4초), ARP MAC이 LB1로 복귀
- 복구 중 끊김도 4.1 로그·probe로 같은 방식으로 기록

### 4.5 원상 확인
```bash
# lb1, lb2 각각 (root)
hostname -s; systemctl is-active keepalived haproxy; ip -4 addr show ens192 | grep -c 192.168.24.100
```
- 기대: lb1 `1`, lb2 `0`, 모두 `active`

### 4.6 측정 종료·요약
```bash
# DevOps VM (heejae) — probe Ctrl+C 후
cd ~/neuroplan-aws-migration && pwd
T0="15:10:05"            # ~/t7_t0.log의 T_inject 시각으로 교체
CSV="$(ls -t probe_*.csv | head -1)" && echo "$CSV"
bash scripts/probe_1006.sh summary "$CSV" "$T0"
awk -F, 'NR>1 { if ($11 != "200") { c++; if (c > m) { m = c; e = $1 } } else c = 0 }
         END { printf "dr 최대 연속 실패: %d초 (마지막 실패 %s)\n", m, (m ? e : "-") }' "$CSV"
```
- 기록: 주입·복구 각각의 VIP 이동 시각, ARP MAC 변경 시각, `dr` 최대 연속 실패, k6 실패 수

## 5. 범위 밖
- K8s API VIP(`192.168.34.100`)도 같은 keepalived로 함께 이동하지만 DR 사용자 경로와 무관 → 기록만
- HAProxy 프로세스 장애(`track_script` weight 110 → 80)는 1차에서 검증 → 이번엔 keepalived 중단만

## 6. 발표 증적 (발표증적 5.7, 부록)
- 주입·복구 타임라인 표 (T_inject → LB2 MASTER → ARP 변경 → probe 복구 / T_restore → LB1 재탈환)
- Infra VM ARP 로그 전환 구간 캡처, probe·k6 결과
- 1차 결과(인수 약 1초)와 같은 설계가 **AWS → VPN 경유 DR 트래픽**에서도 유지됨을 대비
