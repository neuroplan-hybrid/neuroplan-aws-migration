# T7 런북 — 인증서 CA 전환 무중단 검증 (1008, #77 / r1~r3: #78 리뷰 반영)

> 담당 희재 · 부록 · 리허설·촬영 10/9~11 (ROSA 불필요) · 리전 ap-northeast-2
> 기준: #77 (T7 변경 합의, 정현·예린 조건부 동의), 교체 절차 = 런북 `cert_ca_switch_1007.md`(#62) 4장
> 이전 T7(DR 중 LB 전환)은 `lb_failover_dr_1008.md`(#69)로 유지하고, 발표 4장 근거로만 사용한다
> 인증서·개인 키·비밀번호는 이 문서, Git, 채팅, 로그에 남기지 않는다

## 1. 목적과 판정

| 항목 | 내용 |
|---|---|
| 성격 | **CA 장애 자동 Failover가 아니다.** 미리 발급해 둔 예비 CA(ZeroSSL) 인증서로 **수동 교체하는 절차가 서비스 중단 없이 동작하는지** 검증한다 (#63 A안 근거 유지) |
| 대상 | 온프렘 NGF Secret `application/neuroplan-cloud-onprem-tls` (SAN `app`, `dr-health`). ROSA는 건드리지 않음 |
| 주입 | 런북 #62 4.3 방식으로 Secret의 `data`만 LE → ZeroSSL로 patch (삭제·재생성 안 함) |
| 복구 | 백업한 LE Secret으로 같은 방식 patch (#62 4.5) |
| 측정 유형 | 연속성 |
| 측정 범위 | **A (기본)**: `dr-health` + `app` TLS 기록 + k6 로그인·조회·저장 / **B (A 전제 미충족 시)**: `dr-health` TLS 기록만 — 판정은 3.4 |
| PASS (A) | ① 교체 전후 인증서 확인(2장 조건 a) 통과 ② TLS 1초 기록에서 **두 호스트 모두 새 연결마다 `ssl_verify=0`·HTTP 200 유지**, Issuer가 LE → ZeroSSL → LE로 바뀐 시각 기록 ③ k6 `session` 실패 0건 ④ 관찰 시간 동안 Secret이 원복되지 않음 ⑤ 원복 후 LE·HTTPS 정상 |
| PASS (B) | ①·④·⑤는 A와 같음 / ② `dr-health`만 `ssl_verify=0`·HTTP 200 유지 / ③ 없음 (k6 생략) |
| 중단 (수동 판단) | 창 1에 `ALERT` 줄(같은 호스트가 **5초 이상 연속 실패**)이 찍히면 **운영자가** 즉시 4.5 원복. 자동 원복은 하지 않는다 |

- 결과가 나오기 전에는 "무중단 성공"으로 표현하지 않는다 (예린 #77)
- TLS 기록은 연속 감시가 아니라 **표본 측정**이다. 실제 표본 간격(4.7에서 호스트별 최대 간격 계산) 사이의 짧은 공백은 감지할 수 없으므로, 결과는 "표본 N건(최대 간격 X초) 중 실패 0건"으로 적고 "무중단"으로 단정하지 않는다 (예린 #78 r1)
- 발표 표현: A = "인증서 교체 중 사용자 로그인·조회·저장 연속성", **B = "dr-health HTTPS/TLS 연속성"만** (사용자 트랜잭션 무중단이라고 쓰지 않음, 예린 #78)

## 2. 사전 조건 (#77 정현·예린 조건)

| # | 조건 | 확인 위치 |
|---|---|---|
| a | 교체 전 ZeroSSL Issuer·SAN·만료일, 인증서·키 쌍 일치 | 3.2 |
| b | 현재 LE Secret을 백업하고 Git·채팅·로그에 노출하지 않음 | 4.2 |
| c | Argo CD가 Secret을 관리하지 않음 (10/8 예린 실측: tracking-id·instance 라벨 없음, 3개 Application 모두 NOT LISTED) → **리허설 직전 재확인** | 3.3 |
| d | (A) k6 `session` 실패 0건 / (A·B) `/actuator/health/routing` 200 | 4.1, 4.6 |
| e | 새 TLS 핸드셰이크에서도 인증서 오류 없음 | 4.1 TLS 기록 (요청마다 새 연결) |

## 3. 사전 점검

### 3.1 경로·스크립트
```bash
# 실행 위치: Infra VM (root)
ip -4 addr show ens161 | grep 192.168.24.62 && echo "DMZ NIC OK"
command -v k6 jq openssl curl
ls -ld /root/certbot-neuroplan/zerossl/prod/config/live/neuroplan-onprem    # drwx------ root
```

### 3.2 교체 전 인증서 확인 (조건 a)
```bash
# 실행 위치: Infra VM (root)
D=/root/certbot-neuroplan/zerossl/prod/config/live/neuroplan-onprem
openssl x509 -in "$D/fullchain.pem" -noout -issuer -enddate -ext subjectAltName
[ "$(openssl x509 -in "$D/fullchain.pem" -noout -pubkey | openssl sha256)" = "$(openssl pkey -in "$D/privkey.pem" -pubout | openssl sha256)" ] && echo "키 쌍 일치"
openssl x509 -in "$D/fullchain.pem" -noout -checkend 1209600 && echo "만료 14일 이상"
# 운영 Secret SAN (키는 가져오지 않음)
ssh root@192.168.14.31 "kubectl -n application get secret neuroplan-cloud-onprem-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -enddate -ext subjectAltName"
```
- 기대: ZeroSSL `ZeroSSL ECC DV SSL CA 2`, 만료 2027-01-05, SAN `app.neuroplan.cloud`·`dr-health.neuroplan.cloud` / 운영 Secret: Let's Encrypt, **같은 SAN**, 만료 2027-01-04

### 3.3 Argo CD 관리 여부 재확인 (조건 c)
```bash
# 실행 위치: Infra VM (root) → cp1 (조회만)
ssh root@192.168.14.31 '
kubectl -n application get secret neuroplan-cloud-onprem-tls \
  -o jsonpath="{.metadata.annotations.argocd\.argoproj\.io/tracking-id}|{.metadata.labels.argocd\.argoproj\.io/instance}|{.metadata.managedFields[*].manager}{\"\n\"}"
for a in $(kubectl -n argocd get applications -o name); do
  n=$(kubectl -n argocd get "$a" -o json | jq "[.status.resources[]? | select(.kind==\"Secret\" and .name==\"neuroplan-cloud-onprem-tls\")] | length")
  echo "$a secret_listed=$n"
done'
```
- 기대: 첫 줄 `||kubectl-create` 형태 (tracking-id·instance 비어 있음), 모든 Application `secret_listed=0`
- 하나라도 다르면 **진행하지 않고** 예린에게 공유

### 3.4 측정 범위 판정 (A / B)
k6는 `app.neuroplan.cloud`로 로그인·조회·저장한다. 10/8 실측(예린 #78)으로는 온프렘 Gateway에 `app.neuroplan.cloud` listener가 없고, HTTPRoute hostname도 `app.nplan.local`만 있어 **TLS 단계에서 실패**한다. A로 가려면 아래 두 가지가 먼저 반영돼야 한다 (T5에도 필요한 선행 조건).

| 선행 작업 | 담당 | 방법 |
|---|---|---|
| Gateway listener `https-public-app` (`app.neuroplan.cloud`, Secret `neuroplan-cloud-onprem-tls`) | 희재 | `scripts/setup_onprem_app_listener_1008.sh gateway --apply` (cp1, 별도 PR) |
| HTTPRoute `neuroplan-login-mvp`에 hostname `app.neuroplan.cloud` + parentRef `sectionName: https-public-app` | 예린 | GitOps `overlays/onprem-dr` |

```bash
# 실행 위치: Infra VM (root) — Route 53이 off라 공인 레코드가 없으므로 VIP로 직접
curl -s -o /dev/null -w 'app / %{http_code} ssl_verify=%{ssl_verify_result}\n' --max-time 10 \
  --resolve app.neuroplan.cloud:443:192.168.24.100 https://app.neuroplan.cloud/
curl -s -o /dev/null -w 'app /api/learning/state %{http_code}\n' --max-time 10 \
  --resolve app.neuroplan.cloud:443:192.168.24.100 https://app.neuroplan.cloud/api/learning/state
```

| 결과 | 의미 | 범위 |
|---|---|---|
| `/` 200 `ssl_verify=0`, `/api/learning/state` **401** | listener·HTTPRoute 모두 반영, Backend 도달 | **A** |
| `000` (curl `-v`에 `unrecognized name`) | listener 없음 | B (또는 listener 작업 후 재판정) |
| `404` | listener는 있으나 HTTPRoute hostname·parentRef 미반영 | B (또는 GitOps 반영 후 재판정) |

- **10/11 촬영 시점까지 A가 안 되면 B로 확정**하고 7장에 기록한다. 이후 4장의 `[A]` 표시 단계는 건너뛴다

**판정 결과를 파일에 기록 (4.1·4.6이 이 값만 읽는다)**
```bash
# 실행 위치: Infra VM (root) — 위 표로 판정한 범위를 입력 (A 또는 B)
read -rp 'T7 범위 (A/B): ' T7_SCOPE
case "$T7_SCOPE" in A|B) echo "$T7_SCOPE" > ~/t7_scope && echo "범위=$(cat ~/t7_scope) 기록" ;; *) echo "⚠ A 또는 B만 입력 → 다시 실행" ;; esac
```
- 4.1·4.6은 공통으로 아래 줄로 대상 호스트를 정한다 (파일이 없거나 값이 A·B가 아니면 `HOSTS`가 비어 다음 단계에서 멈춤)
```bash
case "$(cat ~/t7_scope 2>/dev/null)" in A) HOSTS="app dr-health" ;; B) HOSTS="dr-health" ;; *) HOSTS="" ;; esac; echo "범위=$(cat ~/t7_scope 2>/dev/null) HOSTS=${HOSTS:-없음}"
```

### 3.5 [A] k6 이름 해석 (Infra VM 한정, 종료 후 제거)
```bash
# 실행 위치: Infra VM (root)
grep -q 'app.neuroplan.cloud' /etc/hosts || echo '192.168.24.100 app.neuroplan.cloud # T7 임시' >> /etc/hosts
getent hosts app.neuroplan.cloud      # 기대: 192.168.24.100
```

## 4. 진행 절차

### 4.1 측정 시작 (주입 2분 전, 창 3개)

**창 1 — TLS 표본 기록 (목표 약 1초 간격, 새 연결마다 인증서 검증)**
```bash
# 실행 위치: Infra VM (root)
case "$(cat ~/t7_scope 2>/dev/null)" in A) HOSTS="app dr-health" ;; B) HOSTS="dr-health" ;; *) HOSTS="" ;; esac
echo "범위=$(cat ~/t7_scope 2>/dev/null) HOSTS=${HOSTS:-없음 → 3.4 먼저, 기록 시작 안 함}"
LOG=~/t7_tls_$(date +%m%d-%H%M).log
declare -A FAIL_SINCE=()
[[ -n "$HOSTS" ]] && while :; do
  round=$(date +%s%N)
  for h in $HOSTS; do
    p=/; [ "$h" = dr-health ] && p=/actuator/health/routing
    ts=$(date +%T.%3N); now=$(date +%s)
    r=$(curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}' --max-time 3 \
          --resolve "$h.neuroplan.cloud:443:192.168.24.100" "https://$h.neuroplan.cloud$p")
    i=$(echo | timeout 3 openssl s_client -connect 192.168.24.100:443 -servername "$h.neuroplan.cloud" 2>/dev/null \
          | openssl x509 -noout -issuer 2>/dev/null | sed -n 's/.*O *= *\([^,]*\).*/\1/p')
    printf '%s %s %s %s\n' "$ts" "$h" "${r:-000 -}" "${i:--}"
    if [[ "${r:-000 -}" == "200 0" ]]; then
      unset "FAIL_SINCE[$h]"
    else
      : "${FAIL_SINCE[$h]:=$now}"
      (( now - FAIL_SINCE[$h] >= 5 )) && printf '%s %s ALERT 연속 실패 %d초 → 4.5 원복 판단\n' "$ts" "$h" $(( now - FAIL_SINCE[$h] ))
    fi
  done
  left=$(( 1000000000 - ($(date +%s%N) - round) ))
  (( left > 0 )) && sleep "$(awk -v n="$left" 'BEGIN{printf "%.3f", n/1e9}')"
done | tee "$LOG"
```
- 한 줄 = `시각 호스트 HTTP ssl_verify Issuer조직`. 시각은 **호스트별 요청 시작 시각**이라, 실제 표본 간격은 로그에서 계산한다 (요청이 느리면 1초보다 길어짐, curl·openssl 각 최대 3초)
- `curl`은 `-k` 없이 검증하므로 잘못된 인증서면 `000 …`, `ssl_verify≠0`
- `ALERT` 줄은 알림일 뿐 자동 원복하지 않는다 (1장 중단 기준, 운영자 판단)
- 기록에는 인증서·키 내용이 남지 않음 (Issuer 조직명만)

**창 2 — [A] k6 연속성 (B면 생략)**
```bash
# 실행 위치: Infra VM (root) — 레포 scripts/k6_rto_1007.js 사본 (실행시트 1012 0.1 방식으로 복사, 해시 d4888242e0a572c4)
read -rp 'TEST_EMAILS (정현 테스트 계정): ' TEST_EMAILS
read -rsp 'TEST_PASSWORD: ' TEST_PASSWORD; echo; export TEST_PASSWORD
K6_CSV_TIME_FORMAT=rfc3339_nano k6 run \
  -e BASE_URL=https://app.neuroplan.cloud -e TEST_EMAILS="$TEST_EMAILS" \
  -e LOGIN_MODE=session -e NO_REUSE=true -e DURATION=30m \
  --out csv=k6_t7_$(date +%m%d-%H%M).csv /root/k6_rto_1007.js
unset TEST_PASSWORD
```
- `NO_REUSE=true` → 요청마다 새 TLS 연결 (기존 연결 유지로 교체가 가려지는 것 방지, 조건 e)
- `INSECURE`는 쓰지 않음 (기본 false = 인증서 검증)
- `DURATION=30m`은 상한이다. **4.5 원복 후 2분 관찰이 끝난 뒤 Ctrl+C로 직접 종료**한다 (주입 전 2분 + 백업 + 교체 후 3분 + 원복 후 2분 + 조작 시간을 모두 포함하도록, 예린 #78 r1). 30분 전에 원복 후 관찰이 끝나지 않으면 그 회차는 k6 판정에서 제외하고 다시 측정
- 종료 시각(T_k6_end)을 `~/t7_t0.log`에 기록: `echo "T_k6_end $(date '+%F %T.%3N %z')" | tee -a ~/t7_t0.log`

**창 3 — 작업 창** (4.2~4.5)

### 4.2 LE Secret 백업 (조건 b)
```bash
# 실행 위치: Infra VM (root)
umask 077; mkdir -p /root/certbot-neuroplan/backup && chmod 700 /root/certbot-neuroplan/backup
ssh root@192.168.14.31 "kubectl -n application get secret neuroplan-cloud-onprem-tls -o json" \
  | jq '{data:{"tls.crt":.data["tls.crt"],"tls.key":.data["tls.key"]}}' \
  > /root/certbot-neuroplan/backup/onprem-le-secret.json
ls -l /root/certbot-neuroplan/backup/
jq -r '.data["tls.crt"]' /root/certbot-neuroplan/backup/onprem-le-secret.json | base64 -d | openssl x509 -noout -issuer -enddate
```
- 기대: 파일 `-rw------- root`, Issuer Let's Encrypt, 만료 2027-01-04
- 백업이 LE가 아니거나 파일이 비어 있으면 **중단**

### 4.3 주입: LE → ZeroSSL (T_switch)
```bash
# 실행 위치: Infra VM (root) — 키는 인자에 넣지 않고 stdin으로만 전달 (#62 4.3)
D=/root/certbot-neuroplan/zerossl/prod/config/live/neuroplan-onprem
echo "T_switch $(date '+%F %T.%3N %z')" | tee -a ~/t7_t0.log
{ printf '{"data":{"tls.crt":"'; base64 -w0 "$D/fullchain.pem"
  printf '","tls.key":"';        base64 -w0 "$D/privkey.pem"
  printf '"}}'; } \
  | ssh root@192.168.14.31 "kubectl -n application patch secret neuroplan-cloud-onprem-tls --type merge --patch-file /dev/stdin"
```
- 기대: `secret/neuroplan-cloud-onprem-tls patched`
- 창 1에서 Issuer가 `ZeroSSL`로 바뀐 첫 시각 = **반영 지연** (T_switch 대비 초)

### 4.4 관찰 (T_switch ~ +3분)
| 확인 | 기대 |
|---|---|
| 창 1 | 대상 호스트(A: 2개, B: dr-health) 모두 `200 0`, Issuer `Let's Encrypt` → `ZeroSSL`, 그 사이 `000`·`ssl_verify≠0` 없음 |
| 창 2 | [A] k6 실패 없음 |
| Secret 유지 (조건 c) | 3분 뒤 아래 명령 결과가 여전히 ZeroSSL |

```bash
# 실행 위치: Infra VM (root)
ssh root@192.168.14.31 "kubectl -n application get secret neuroplan-cloud-onprem-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -enddate"
```

### 4.5 원복: ZeroSSL → LE (T_restore)
```bash
# 실행 위치: Infra VM (root)
echo "T_restore $(date '+%F %T.%3N %z')" | tee -a ~/t7_t0.log
ssh root@192.168.14.31 "kubectl -n application patch secret neuroplan-cloud-onprem-tls --type merge --patch-file /dev/stdin" \
  < /root/certbot-neuroplan/backup/onprem-le-secret.json
```
- 창 1에서 Issuer가 `Let's Encrypt`로 돌아오고 `200 0` 유지 → 2분 더 관찰 후 측정 종료

### 4.6 원복 확인·정리 (모든 확인이 통과할 때만 백업 삭제)
```bash
# 실행 위치: Infra VM (root) — 범위는 3.4에서 기록한 ~/t7_scope (A: app·dr-health, B: dr-health)
case "$(cat ~/t7_scope 2>/dev/null)" in A) HOSTS="app dr-health" ;; B) HOSTS="dr-health" ;; *) HOSTS="" ;; esac
echo "범위=$(cat ~/t7_scope 2>/dev/null) HOSTS=${HOSTS:-없음}"
ok=1
[[ -n "$HOSTS" ]] || { echo "[FAIL] 범위 기록(~/t7_scope) 없음"; ok=0; }
crt="$(ssh root@192.168.14.31 "kubectl -n application get secret neuroplan-cloud-onprem-tls -o jsonpath='{.data.tls\.crt}'" | base64 -d)"
iss="$(openssl x509 -noout -issuer <<<"$crt" 2>/dev/null)"
echo "Secret: $iss"; openssl x509 -noout -enddate <<<"$crt"
[[ "$iss" == *"Let's Encrypt"* ]] || { echo "[FAIL] Secret Issuer가 LE가 아님"; ok=0; }
openssl x509 -noout -checkend 0 <<<"$crt" >/dev/null || { echo "[FAIL] Secret 인증서 만료"; ok=0; }
for h in $HOSTS; do
  p=/; [ "$h" = dr-health ] && p=/actuator/health/routing
  r="$(curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}' --max-time 10 \
        --resolve "$h.neuroplan.cloud:443:192.168.24.100" "https://$h.neuroplan.cloud$p")"
  i="$(echo | timeout 10 openssl s_client -connect 192.168.24.100:443 -servername "$h.neuroplan.cloud" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"
  echo "$h: $r / $i"
  [[ "$r" == "200 0" && "$i" == *"Let's Encrypt"* ]] || { echo "[FAIL] $h 원복 확인 실패"; ok=0; }
done
if [[ $ok -eq 1 ]]; then
  rm -f /root/certbot-neuroplan/backup/onprem-le-secret.json && echo "[OK] 원복 확인 완료 → LE 백업 삭제"
else
  echo "[STOP] 원복 확인 실패 → LE 백업 보존 (/root/certbot-neuroplan/backup/), 4.5 재실행 또는 팀 공유"
fi
```
- 기대: Secret·외부 HTTPS 모두 Let's Encrypt, 만료 2027-01-04, 대상 호스트 모두 `200 0` → `[OK]`
- `[STOP]`이면 **백업을 지우지 않는다.** 4.5를 다시 실행하거나 런북 #62 4.5대로 판단

```bash
# 실행 위치: Infra VM (root) — [A]만, 4.6 [OK] 후
sed -i '/app.neuroplan.cloud # T7 임시/d' /etc/hosts && getent hosts app.neuroplan.cloud || echo "hosts 정리 완료"
```

### 4.7 요약
```bash
# 실행 위치: Infra VM (root) — 창 1 Ctrl+C 후
LOG="$(ls -t ~/t7_tls_*.log | head -1)"
awk '$3!="ALERT" {n++; if ($3!="200" || $4!="0") bad++; iss=$5; for (k=6; k<=NF; k++) iss=iss" "$k; if (iss!=prev[$2]) {print "Issuer 변경", $1, $2, (prev[$2]=="" ? "(시작)" : prev[$2]), "→", iss; prev[$2]=iss}}
     END {printf "총 %d건, 실패(HTTP≠200 또는 ssl_verify≠0) %d건\n", n, bad}' "$LOG"
# 호스트별 실제 표본 간격 (최대 간격 = 감지할 수 없는 공백의 상한)
awk '$3!="ALERT" {split($1,t,":"); s=t[1]*3600+t[2]*60+t[3]; if ($2 in last) {g=s-last[$2]; if (g>mx[$2]) mx[$2]=g; sum[$2]+=g; c[$2]++} last[$2]=s}
     END {for (h in mx) printf "%s 표본 간격: 평균 %.2f초, 최대 %.2f초\n", h, sum[h]/c[h], mx[h]}' "$LOG"
grep -c ALERT "$LOG" || true
# [A]만
python3 /root/k6_rto_summary_1007.py "$(ls -t k6_t7_*.csv | head -1)" --t0 "<T_switch 시각>" --mode continuity
```
- 기록: T_switch·T_restore·T_k6_end, Issuer 변경 시각(반영 지연), TLS 표본 수·실패 건수·**최대 표본 간격**, ALERT 수, k6 실패 수·PASS 여부
- [A] k6 판정 전 확인: T_k6_end가 "T_restore + 2분" 이후인지 (아니면 원복 구간이 빠진 것 → 판정 제외)

## 5. 범위 밖
- ROSA Secret 교체 (#62 4.6): 운영 중 Route 영향 위험이 있어 이번 시연에서 제외
- CA 장애 자동 감지·자동 교체: #63 A안 근거로 하지 않음
- 이미 맺어진 TLS 연결: 교체 후에도 기존 인증서로 유지되는 것이 정상 → 측정은 새 연결 기준

## 6. 발표 증적 (발표증적 2.x, 부록)
- 창 1 로그의 Issuer 전환 구간 캡처 (LE → ZeroSSL → LE, 그 사이 `200 0` 연속)
- [A] k6 summary (continuity, 실패 0건 여부)
- 설명 문장 (A): "넘어갈 인증서는 미리 받아 두고, 교체는 사람이 판단한다. 교체해도 사용자 요청은 끊기지 않는다."
- 설명 문장 (B): "교체 중에도 새 HTTPS 연결이 계속 검증을 통과했다 (dr-health 기준)." — 사용자 트랜잭션 연속성은 주장하지 않음

## 7. 실행 기록

| 일시 | 단계 | 결과 | 비고 |
|---|---|---|---|
| | 3.3 Argo CD 재확인 | | |
| | 3.4 범위 판정 | | A / B (결과 코드) |
| | 4.3 T_switch | | 반영 지연 __초 |
| | 4.5 T_restore | | |
| | 4.7 요약 | | TLS 표본 __건(최대 간격 __초) 실패 __건 / k6 실패 __건 |
