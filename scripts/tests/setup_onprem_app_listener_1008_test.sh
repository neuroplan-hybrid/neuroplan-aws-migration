#!/usr/bin/env bash
# setup_onprem_app_listener_1008.sh mock 테스트 (kubectl·curl·openssl 대체, 클러스터 변경 없음)
#   bash scripts/tests/setup_onprem_app_listener_1008_test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/setup_onprem_app_listener_1008.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
REAL_OPENSSL="$(command -v openssl)"

# 테스트 인증서 (SAN app.neuroplan.cloud)
"$REAL_OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$W/k.pem" -out "$W/c.pem" \
  -days 1 -subj /CN=test -addext "subjectAltName=DNS:app.neuroplan.cloud,DNS:dr-health.neuroplan.cloud" 2>/dev/null
export MOCK_CERT_B64; MOCK_CERT_B64="$(base64 -w0 "$W/c.pem")"; export MOCK_CERT="$W/c.pem"

cat > "$W/kubectl" <<'M'
#!/usr/bin/env bash
a="$*"
case "$a" in
  *"patch gateway"*) echo "PATCH" >>"$MOCK_DIR/patched"; exit 0 ;;
  *"get gateway neuroplan-gateway") exit 0 ;;
  *"get secret neuroplan-cloud-onprem-tls") exit 0 ;;
  *"jsonpath={.type}"*) printf kubernetes.io/tls ;;
  *"tls\.crt"*) printf '%s' "$MOCK_CERT_B64" ;;
  *"jsonpath=hostname="*) printf '%s' "$MOCK_SPEC" ;;
  *"{.name}{"*) printf 'https\nhttps-dr-health\n'; [[ "$MOCK_HAS" == 1 ]] && printf 'https-public-app\n'; true ;;
  *".status.listeners"*) printf 'Accepted=True Programmed=True ResolvedRefs=True ' ;;
  *"annotations"*) printf '' ;;
  *) echo "unexpected kubectl: $a" >&2; exit 1 ;;
esac
M
cat > "$W/curl" <<'M'
#!/usr/bin/env bash
for x in "$@"; do u="$x"; done
case "$u" in *"/api/learning/state") printf '%s' "$MOCK_API" ;; *) printf '%s' "$MOCK_ROOT" ;; esac
exit "${MOCK_CURL_RC:-0}"
M
cat > "$W/openssl" <<M
#!/usr/bin/env bash
if [[ "\$1" == s_client ]]; then cat >/dev/null; [[ "\$MOCK_TLS" == ok ]] && cat "\$MOCK_CERT"; exit 0; fi
exec "$REAL_OPENSSL" "\$@"
M
chmod +x "$W/kubectl" "$W/curl" "$W/openssl"
export MOCK_DIR="$W" PATH="$W:$PATH"

GOOD="hostname=app.neuroplan.cloud port=443 protocol=HTTPS mode=Terminate certs=1 kind=Secret group= cert=neuroplan-cloud-onprem-tls from=Same"
pass=0; fail=0
t() {  # $1 이름, $2 기대 종료코드, 나머지 = 실행 인자 (환경변수는 미리 export)
  local name="$1" want="$2"; shift 2
  bash "$SCRIPT" "$@" >"$W/out" 2>&1; local rc=$?
  if [[ $rc -eq $want ]]; then pass=$((pass+1)); echo "PASS $name (rc=$rc)"; else fail=$((fail+1)); echo "FAIL $name (rc=$rc, 기대 $want)"; cat "$W/out"; fi
}
export MOCK_TLS=ok MOCK_ROOT="200 0" MOCK_API="401 0"

export MOCK_HAS=1 MOCK_SPEC="$GOOD";                         t "기존 listener 전체 일치 → 건너뜀" 0 gateway --apply
[[ ! -f "$W/patched" ]] && { pass=$((pass+1)); echo "PASS 일치 시 patch 안 함"; } || { fail=$((fail+1)); echo "FAIL 일치인데 patch 호출"; }
export MOCK_SPEC="${GOOD/port=443/port=80}";                  t "기존 listener port 80 → 중단" 1 gateway --apply
export MOCK_SPEC="${GOOD/protocol=HTTPS/protocol=HTTP}";      t "기존 listener protocol HTTP → 중단" 1 gateway --apply
export MOCK_SPEC="${GOOD/mode=Terminate/mode=Passthrough}";   t "기존 listener TLS Passthrough → 중단" 1 gateway --apply
export MOCK_SPEC="${GOOD/from=Same/from=All}";                t "기존 listener allowedRoutes All → 중단" 1 gateway --apply
export MOCK_SPEC="${GOOD/kind=Secret/kind=ConfigMap}";        t "기존 listener cert kind 다름 → 중단" 1 gateway --apply
[[ ! -f "$W/patched" ]] && { pass=$((pass+1)); echo "PASS 거부 시 patch 안 함"; } || { fail=$((fail+1)); echo "FAIL 거부인데 patch 호출"; }

export MOCK_ROOT="404 0" MOCK_API="404 0";                    t "verify(사전점검): 404여도 인증서 OK면 통과" 0 verify
export MOCK_TLS=none;                                         t "verify: unrecognized name(인증서 없음) → 실패" 1 verify
export MOCK_TLS=ok MOCK_ROOT="000 -";                         t "verify: 전송 실패 → 실패" 1 verify

export MOCK_ROOT="200 0" MOCK_API="401 0";                    t "verify-route: 200/401 → 통과" 0 verify-route
export MOCK_ROOT="404 0";                                     t "verify-route: / 404 → 실패" 1 verify-route
export MOCK_ROOT="200 0" MOCK_API="503 0";                    t "verify-route: API 503 → 실패" 1 verify-route
export MOCK_API="502 0";                                      t "verify-route: API 502 → 실패" 1 verify-route
export MOCK_API="000 -";                                      t "verify-route: 전송 실패 → 실패" 1 verify-route
export MOCK_API="401 0" MOCK_ROOT="200 19";                   t "verify-route: ssl_verify≠0 → 실패" 1 verify-route

export MOCK_ROOT="200 0" MOCK_API="401 0" MOCK_CURL_RC=28;  t "verify-route: 200/401 출력 + curl exit 28 → 실패" 1 verify-route
export MOCK_ROOT="404 0";                                     t "verify: 출력 있어도 curl exit 28 → 실패" 1 verify
export MOCK_CURL_RC=0

echo "결과: PASS ${pass} / FAIL ${fail}"
[[ $fail -eq 0 ]]
