# 런북 — 예비 CA(ZeroSSL) 인증서 전환 (#59)

> 리전 ap-northeast-2 · 작성 희재 10/7 · 대상: 온프렘 NGF / ROSA Route
> 인증서·개인 키·EAB·비밀번호는 이 문서, Git, 채팅, 메신저에 남기지 않는다.

## 0. 이 런북의 성격

- **CA 자동 Failover가 아니다.** "인증서 발급 경로 이중화 및 예비 인증서 Warm Standby"이며, 전환은 사람이 판단해 실행한다.
- 이유: CA 강제 폐기는 보통 수일의 유예를 두고 공지된다 → 초 단위 자동 전환이 필요한 장애가 아니고, 자동 판정은 오판 시 정상 인증서를 스스로 교체할 위험이 있다.
- 평소 운영 인증서: Let's Encrypt (만료 2027-01-04). 예비: ZeroSSL (Infra VM에만 보관, Secret 사전 배포 없음).

| 대상 | Secret | SAN | 사용처 | 원격 CLI 호스트 |
|---|---|---|---|---|
| 온프렘 | `application/neuroplan-cloud-onprem-tls` | `app`, `dr-health` | NGF Gateway listener | cp1 `root@192.168.14.31` (kubectl) |
| ROSA | `neuroplan/neuroplan-cloud-rosa-tls` | `app`, `primary-health` | Route `spec.tls.externalCertificate` (Route 3개) | DevOps VM `devops@192.168.14.21` (oc, 예린 로그인) |

## 1. 계정·보관 위치

| 항목 | 값 |
|---|---|
| ZeroSSL 계정 | 희재 개인 계정 (공용 메일 전환은 #59 정현 의견, 불가 시 아래 복구 절차로 대체) |
| 계정 접근 복구 | ZeroSSL 로그인 화면 비밀번호 재설정 → 계정 메일 수신 (희재) |
| EAB 재발급 | ZeroSSL 대시보드 → Developer → EAB Credentials → Generate (재사용 가능, 등록 후 Infra VM 파일은 삭제됨) |
| ACME 서버 | `https://acme.zerossl.com/v2/DV90` (staging 없음 → production 발급이 첫 검증) |
| 예비 인증서 | Infra VM `/root/certbot-neuroplan/zerossl/prod/config/live/{neuroplan-onprem,neuroplan-rosa}/` (디렉터리 700, 키 600) |
| 발급 스크립트 | `scripts/issue_cert_dns01_1006.sh --ca zerossl` |
| DNS-01 권한 | 임시 Role `neuroplan-certbot-dns01` (재발급할 때만 필요, 없으면 `setup_certbot_role_1006.sh create`·`verify`) |

## 2. 예비 인증서 발급 (사전, 1회)

```bash
# 실행 위치: Infra VM (root), ap-northeast-2
bash issue_cert_dns01_1006.sh status --ca zerossl
umask 077; install -d -m 700 /root/certbot-neuroplan /root/certbot-neuroplan/zerossl   # 최초 실행 시 디렉터리 없음 (예린 #60)
vi /root/certbot-neuroplan/zerossl/eab.ini      # eab-kid = …  / eab-hmac-key = …  (2줄, 값은 채팅·메신저·Git 금지)
bash issue_cert_dns01_1006.sh register --ca zerossl           # dry-run: 파일·권한 확인
bash issue_cert_dns01_1006.sh register --ca zerossl --apply   # 등록 성공 시 eab.ini 자동 삭제
bash issue_cert_dns01_1006.sh production --ca zerossl         # SAN 대조 + 발급 예정 확인
bash issue_cert_dns01_1006.sh production --ca zerossl --apply
bash issue_cert_dns01_1006.sh status --ca zerossl             # 기록: Issuer·SAN·만료·키 쌍·키 권한
```
- 발급 전 SAN 대조 (staging이 없으므로, 정현 #59): 스크립트는 정의값과 LE 로컬 사본(있으면)을 비교한다. LE 사본이 purge된 경우 **운영 Secret의 SAN과 직접 대조**한다.
```bash
# 실행 위치: Infra VM (root) — 운영 Secret SAN 조회 (키는 가져오지 않음)
ssh root@192.168.14.31 "kubectl -n application get secret neuroplan-cloud-onprem-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName"
ssh devops@192.168.14.21 "oc -n neuroplan get secret neuroplan-cloud-rosa-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName"
```
- 기존 CAA 확인 (신규 추가 없음): `dig +short CAA neuroplan.cloud` → 비어 있으면 그대로, 값이 있으면 `sectigo.com` 허용 여부만 확인

## 3. 전환 판단 기준

다음 중 하나이고, Let's Encrypt로 재발급이 불가능할 때 팀 채널에 공유한 뒤 전환한다.
- LE가 우리 인증서의 폐기(revocation) 또는 폐기 예정을 공지
- 운영 인증서가 폐기되어 브라우저·클라이언트가 거부
- 운영 인증서 갱신이 필요한데 LE 발급이 장시간 불가

## 4. 전환 절차 (온프렘 예시, ROSA는 4.6)

### 4.1 사전 점검
```bash
# 실행 위치: Infra VM (root)
D=/root/certbot-neuroplan/zerossl/prod/config/live/neuroplan-onprem
openssl x509 -in "$D/fullchain.pem" -noout -issuer -enddate -ext subjectAltName
[ "$(openssl x509 -in "$D/fullchain.pem" -noout -pubkey | openssl sha256)" = "$(openssl pkey -in "$D/privkey.pem" -pubout | openssl sha256)" ] && echo "키 쌍 일치"
openssl x509 -in "$D/fullchain.pem" -noout -checkend 1209600 && echo "만료 14일 이상"
```
- 기대: Issuer ZeroSSL, SAN = 운영 Secret과 동일(2장), 키 쌍 일치, 만료 14일 이상

### 4.2 현재 Secret 백업 (LE 복귀용)
LE 로컬 사본은 Secret 등록 후 purge되어 없으므로, **교체 전에 현재 Secret을 Infra VM으로 백업**한다.
```bash
# 실행 위치: Infra VM (root)
umask 077; mkdir -p /root/certbot-neuroplan/backup && chmod 700 /root/certbot-neuroplan/backup
ssh root@192.168.14.31 "kubectl -n application get secret neuroplan-cloud-onprem-tls -o json" \
  | jq '{data:{"tls.crt":.data["tls.crt"],"tls.key":.data["tls.key"]}}' \
  > /root/certbot-neuroplan/backup/onprem-le-secret.json
ls -l /root/certbot-neuroplan/backup/      # 600 root 확인
jq -r '.data["tls.crt"]' /root/certbot-neuroplan/backup/onprem-le-secret.json | base64 -d | openssl x509 -noout -issuer -enddate   # LE 확인
```

### 4.3 Secret 내용 교체 (삭제 후 재생성 금지)
삭제하면 Gateway가 참조하는 Secret이 사라져 TLS가 끊긴다 → `patch`로 **data만** 바꾼다 (라벨·annotation 유지).
키는 어떤 명령의 인자에도 넣지 않는다: `base64`가 파일을 직접 읽고, 패치는 stdin(`--patch-file /dev/stdin`)으로만 전달 → 로컬 `ps`·원격 디스크·명령줄에 키 없음.
```bash
# 실행 위치: Infra VM (root)
D=/root/certbot-neuroplan/zerossl/prod/config/live/neuroplan-onprem
{ printf '{"data":{"tls.crt":"'; base64 -w0 "$D/fullchain.pem"
  printf '","tls.key":"';        base64 -w0 "$D/privkey.pem"
  printf '"}}'; } \
  | ssh root@192.168.14.31 "kubectl -n application patch secret neuroplan-cloud-onprem-tls --type merge --patch-file /dev/stdin"
```
- 기대: `secret/neuroplan-cloud-onprem-tls patched`

### 4.4 외부 HTTPS 검증
```bash
# 실행 위치: Infra VM (root) — VIP 경유 (DMZ NIC)
for h in app.neuroplan.cloud dr-health.neuroplan.cloud; do
  echo | timeout 10 openssl s_client -connect 192.168.24.100:443 -servername "$h" 2>/dev/null \
    | openssl x509 -noout -issuer -ext subjectAltName -enddate
done
curl -s -o /dev/null -w 'dr-health %{http_code} ssl_verify=%{ssl_verify_result}\n' --max-time 10 \
  --resolve dr-health.neuroplan.cloud:443:192.168.24.100 https://dr-health.neuroplan.cloud/actuator/health/routing
```
- 기대: Issuer ZeroSSL, SAN 일치, `200 ssl_verify=0`
- 반영이 늦으면 NGF가 Secret 변경을 다시 읽을 때까지 수십 초 대기 후 재확인 (리허설에서 실측해 기록)

### 4.5 LE 복귀 (LE 재발급 가능 또는 원본 유효 시)
```bash
# 실행 위치: Infra VM (root)
ssh root@192.168.14.31 "kubectl -n application patch secret neuroplan-cloud-onprem-tls --type merge --patch-file /dev/stdin" \
  < /root/certbot-neuroplan/backup/onprem-le-secret.json
# 4.4와 같은 검증 → Issuer Let's Encrypt 확인 후 백업 삭제
rm -f /root/certbot-neuroplan/backup/onprem-le-secret.json
```
- 원본이 폐기된 상태라면 백업으로 돌아가지 않는다 → LE 재발급(`issue_cert_dns01_1006.sh staging`·`production`) 후 `deploy_cert_secret_1006.sh` 흐름으로 새 Secret 내용을 반영

### 4.6 ROSA
4.1~4.5와 같다. 바꿀 값만 정리한다.

| 항목 | 온프렘 | ROSA |
|---|---|---|
| 예비 인증서 디렉터리 | `live/neuroplan-onprem` | `live/neuroplan-rosa` |
| 원격 | `ssh root@192.168.14.31`, `kubectl` | `ssh devops@192.168.14.21`, `oc` (예린 `oc login` 상태) |
| Secret | `application/neuroplan-cloud-onprem-tls` | `neuroplan/neuroplan-cloud-rosa-tls` |
| 백업 파일 | `backup/onprem-le-secret.json` | `backup/rosa-le-secret.json` |
| 외부 검증 | VIP `192.168.24.100` | Router NLB (`oc -n openshift-ingress get svc router-default` 의 hostname), 호스트 `app`·`primary-health` (`/actuator/health/routing`) |

- ROSA Route는 `externalCertificate`로 같은 Secret을 참조하므로 Route YAML 수정은 없다. Router가 Secret 변경을 감지해 반영한다.

## 5. 정리 (10/26)

```bash
# 실행 위치: Infra VM (root)
bash issue_cert_dns01_1006.sh purge --ca zerossl            # dry-run
bash issue_cert_dns01_1006.sh purge --ca zerossl --apply    # 예비 인증서·키·ACME 계정 정보 삭제
rm -rf /root/certbot-neuroplan/backup
```
- ZeroSSL 대시보드에서 EAB credential 삭제 (계정 유지 여부는 희재 판단)
- 작업일지에 폐기 일시·결과 기록, #59 Close

## 6. 실행 기록

| 일시 | 단계 | 결과 | 비고 |
|---|---|---|---|
| 10/7 18:23 | 2. 사전 확인 | 스크립트 해시 `e6b22db6…` (#60 `0ad3509`), 임시 Role assume OK | |
| 10/7 18:23 | 2. CAA 조회 | `dig +short CAA neuroplan.cloud` 결과 없음 → 추가 조치 없음 | |
| 10/7 18:26 | 2. register | `Account registered.`, EAB 파일 자동 삭제 | `--config` EAB 전달·이메일 없이 등록 실제 동작 확인 |
| 10/7 18:29 | 2. SAN 대조 | 온프렘: 운영 Secret(LE YE2) SAN `app`, `dr-health` 일치 / ROSA: LE 사본과 자동 대조 ✅ | 정현 #60 비차단 |
| 10/7 18:29~18:31 | 2. production | 2개 발급, Issuer `ZeroSSL ECC DV SSL CA 2`, 만료 2027-01-05, 키 600 root, 키 쌍 일치 | 인증서당 약 1분 |
| 10/26 | 5. purge | | |

- 전환(4장) 리허설은 하지 않음: CA 장애는 초 단위 전환 대상이 아니라 "예비 인증서 확보"가 핵심 (#59). 실제 전환이 필요해지면 4장 순서대로 실행하고 이 표에 추가
