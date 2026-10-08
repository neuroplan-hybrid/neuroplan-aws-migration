# T7 런북 — 인증서 CA 전환 무중단 검증 (1008, #77)

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
| PASS | ① 교체 전후 인증서 확인(2장 조건 a) 통과 ② TLS 1초 기록에서 **새 연결마다 인증서 검증 성공(`ssl_verify=0`)·HTTP 200 유지**, Issuer가 LE → ZeroSSL → LE로 바뀐 시각 기록 ③ k6 `session` 실패 0건 ④ 관찰 시간 동안 Secret이 원복되지 않음 ⑤ 원복 후 LE·HTTPS 정상 |
| 중단 | TLS 기록에서 `ssl_verify≠0` 또는 `000`이 **5초 연속** → 즉시 4.5 원복 |

- 결과가 나오기 전에는 "무중단 성공"으로 표현하지 않는다 (예린 #77)

## 2. 사전 조건 (#77 정현·예린 조건)

| # | 조건 | 확인 위치 |
|---|---|---|
| a | 교체 전 ZeroSSL Issuer·SAN·만료일, 인증서·키 쌍 일치 | 3.2 |
| b | 현재 LE Secret을 백업하고 Git·채팅·로그에 노출하지 않음 | 4.2 |
| c | Argo CD가 Secret을 관리하지 않음 (10/8 예린 실측: tracking-id·instance 라벨 없음, 3개 Application 모두 NOT LISTED) → **리허설 직전 재확인** | 3.3 |
| d | k6 `session` 실패 0건, `/actuator/health/routing` 200 | 4.1, 4.6 |
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

### 3.4 app 호스트가 온프렘에서 라우팅되는지 (k6 전제)
k6는 `app.neuroplan.cloud`로 로그인·조회·저장한다. Route 53이 `off` 단계라 공인 레코드가 없으므로 **Infra VM에서 VIP로 직접** 측정한다.
```bash
# 실행 위치: Infra VM (root)
curl -s -o /dev/null -w 'app / %{http_code} ssl_verify=%{ssl_verify_result}\n' --max-time 10 \
  --resolve app.neuroplan.cloud:443:192.168.24.100 https://app.neuroplan.cloud/
curl -s -o /dev/null -w 'app /api/learning/state %{http_code}\n' --max-time 10 \
  --resolve app.neuroplan.cloud:443:192.168.24.100 https://app.neuroplan.cloud/api/learning/state
```
- 기대: `/` 200 `ssl_verify=0`, `/api/learning/state` **401** (로그인 전, Backend까지 도달)
- 404면 온프렘 HTTPRoute에 `app.neuroplan.cloud`가 없는 상태 → T7은 TLS 기록(4.1)만으로 진행하고 k6는 생략, 예린에게 GitOps hostname 추가 여부 공유 (T5에도 필요한 항목)

### 3.5 k6 이름 해석 (Infra VM 한정, 종료 후 제거)
```bash
# 실행 위치: Infra VM (root)
grep -q 'app.neuroplan.cloud' /etc/hosts || echo '192.168.24.100 app.neuroplan.cloud # T7 임시' >> /etc/hosts
getent hosts app.neuroplan.cloud      # 기대: 192.168.24.100
```

## 4. 진행 절차

### 4.1 측정 시작 (주입 2분 전, 창 3개)

**창 1 — TLS 1초 기록 (새 연결마다 인증서 검증)**
```bash
# 실행 위치: Infra VM (root)
LOG=~/t7_tls_$(date +%m%d-%H%M).log
while :; do
  ts=$(date +%T.%3N)
  for h in app dr-health; do
    p=/; [ "$h" = dr-health ] && p=/actuator/health/routing
    r=$(curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}' --max-time 3 \
          --resolve "$h.neuroplan.cloud:443:192.168.24.100" "https://$h.neuroplan.cloud$p")
    i=$(echo | timeout 3 openssl s_client -connect 192.168.24.100:443 -servername "$h.neuroplan.cloud" 2>/dev/null \
          | openssl x509 -noout -issuer 2>/dev/null | sed -n 's/.*O *= *\([^,]*\).*/\1/p')
    printf '%s %s %s %s\n' "$ts" "$h" "${r:-000 -}" "${i:--}"
  done
  sleep 1
done | tee "$LOG"
```
- 한 줄 = `시각 호스트 HTTP ssl_verify Issuer조직`. `curl`은 `-k` 없이 검증하므로 잘못된 인증서면 `000 …`, `ssl_verify≠0`
- 기록에는 인증서·키 내용이 남지 않음 (Issuer 조직명만)

**창 2 — k6 연속성 (3.4 통과 시)**
```bash
# 실행 위치: Infra VM (root) — 레포 scripts/k6_rto_1007.js 사본 (실행시트 1012 0.1 방식으로 복사, 해시 d4888242e0a572c4)
read -rp 'TEST_EMAILS (정현 테스트 계정): ' TEST_EMAILS
read -rsp 'TEST_PASSWORD: ' TEST_PASSWORD; echo; export TEST_PASSWORD
K6_CSV_TIME_FORMAT=rfc3339_nano k6 run \
  -e BASE_URL=https://app.neuroplan.cloud -e TEST_EMAILS="$TEST_EMAILS" \
  -e LOGIN_MODE=session -e NO_REUSE=true -e DURATION=8m \
  --out csv=k6_t7_$(date +%m%d-%H%M).csv /root/k6_rto_1007.js
unset TEST_PASSWORD
```
- `NO_REUSE=true` → 요청마다 새 TLS 연결 (기존 연결 유지로 교체가 가려지는 것 방지, 조건 e)
- `INSECURE`는 쓰지 않음 (기본 false = 인증서 검증)

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
| 창 1 | 두 호스트 모두 `200 0`, Issuer `Let's Encrypt` → `ZeroSSL`, 그 사이 `000`·`ssl_verify≠0` 없음 |
| 창 2 | k6 실패 없음 |
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

### 4.6 원복 확인·정리
```bash
# 실행 위치: Infra VM (root)
ssh root@192.168.14.31 "kubectl -n application get secret neuroplan-cloud-onprem-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -enddate"
curl -s -o /dev/null -w 'dr-health %{http_code} ssl_verify=%{ssl_verify_result}\n' --max-time 10 \
  --resolve dr-health.neuroplan.cloud:443:192.168.24.100 https://dr-health.neuroplan.cloud/actuator/health/routing
# 확인 후 정리
rm -f /root/certbot-neuroplan/backup/onprem-le-secret.json
sed -i '/app.neuroplan.cloud # T7 임시/d' /etc/hosts && getent hosts app.neuroplan.cloud || echo "hosts 정리 완료"
```
- 기대: Issuer Let's Encrypt, 만료 2027-01-04, `200 ssl_verify=0`
- 백업 삭제는 **LE 원복 확인 뒤에만**

### 4.7 요약
```bash
# 실행 위치: Infra VM (root) — 창 1 Ctrl+C 후
LOG="$(ls -t ~/t7_tls_*.log | head -1)"
awk '{n++; if ($3!="200" || $4!="0") bad++; if ($5!=prev[$2]) {print "Issuer 변경", $1, $2, prev[$2], "→", $5; prev[$2]=$5}}
     END {printf "총 %d건, 실패(HTTP≠200 또는 ssl_verify≠0) %d건\n", n, bad}' "$LOG"
python3 /root/k6_rto_summary_1007.py "$(ls -t k6_t7_*.csv | head -1)" --t0 "<T_switch 시각>" --mode continuity
```
- 기록: T_switch·T_restore, Issuer 변경 시각(반영 지연), TLS 실패 건수, k6 실패 수·PASS 여부

## 5. 범위 밖
- ROSA Secret 교체 (#62 4.6): 운영 중 Route 영향 위험이 있어 이번 시연에서 제외
- CA 장애 자동 감지·자동 교체: #63 A안 근거로 하지 않음
- 이미 맺어진 TLS 연결: 교체 후에도 기존 인증서로 유지되는 것이 정상 → 측정은 새 연결 기준

## 6. 발표 증적 (발표증적 2.x, 부록)
- 창 1 로그의 Issuer 전환 구간 캡처 (LE → ZeroSSL → LE, 그 사이 `200 0` 연속)
- k6 summary (continuity, 실패 0건 여부)
- 설명 문장: "넘어갈 인증서는 미리 받아 두고, 교체는 사람이 판단한다. 교체해도 사용자 요청은 끊기지 않는다."

## 7. 실행 기록

| 일시 | 단계 | 결과 | 비고 |
|---|---|---|---|
| | 3.3 Argo CD 재확인 | | |
| | 3.4 app 라우팅 | | 404면 k6 생략 |
| | 4.3 T_switch | | 반영 지연 __초 |
| | 4.5 T_restore | | |
| | 4.7 요약 | | TLS 실패 __건 / k6 실패 __건 |
