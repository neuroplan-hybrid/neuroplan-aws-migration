#!/bin/bash
# setup_onprem_app_listener_1008.sh — 온프렘 Gateway에 app.neuroplan.cloud HTTPS listener 추가 (#78, T5·T7 선행 조건)
#
# 배경 (10/8 예린 실측, #78)
#   - 온프렘 neuroplan-gateway listener: https(app.nplan.local, nplan-tls-v2), https-dr-health(dr-health.neuroplan.cloud)만 있음
#   - VIP로 app.neuroplan.cloud 접속 → TLS 단계 "unrecognized name" (000)
#   - T5에서 Route 53이 온프렘으로 넘어가면 사용자 app 요청이 모두 실패 → 10/12 전 필요
# 범위
#   - 이 스크립트: Gateway listener https-public-app 1개 + 소유 annotation (희재)
#   - HTTPRoute: GitOps overlays/onprem-dr (예린). neuroplan-login-mvp에 hostname app.neuroplan.cloud
#     + parentRefs에 sectionName https-public-app 추가 (기존 parentRef가 sectionName https로 고정이면 hostname만으로는 붙지 않음)
#   - dr-health(setup_dr_health_1006.sh)와 분리: 한쪽 rollback이 다른 쪽을 끊지 않게 (PR #40 리뷰 원칙)
# 실행 위치: 온프렘 cp1 (root, kubectl)
#   bash setup_onprem_app_listener_1008.sh <gateway|verify|verify-route|rollback> [--apply]   # 기본 dry-run
# 단계
#   gateway       listener 없으면 추가(+ annotation), 있으면 전체 기대값 비교만 (하나라도 다르면 중단)
#                 비교: hostname · port 443 · protocol HTTPS · tls.mode Terminate · certificateRefs(kind Secret, group "", name)
#                       · allowedRoutes.namespaces.from Same
#   verify        listener 단독 사전점검 (HTTPRoute 반영 전): listener 3개 상태 + SNI 인증서 SAN·검증(ssl_verify=0)
#                 HTTP 코드는 판정하지 않음 (HTTPRoute 반영 전 404가 정상)
#   verify-route  최종 라우팅 검증 (GitOps HTTPRoute 반영 후): / = 200, /api/learning/state(비인증) = 401,
#                 둘 다 ssl_verify=0. 000·404·502·503 등 그 외 모두 FAIL → 종료 코드 1
#   rollback      annotation이 있을 때만(이 스크립트가 만든 경우만) listener 제거
# 실패 시 종료 코드 1 (verify·verify-route 포함)
# 하지 않는 일: 인증서 발급·Secret 생성, HTTPRoute 변경, Gateway kubectl apply(last-applied가 nplan-tls-v1)
# 주의: "명령 | grep -q"·"| head" 같은 조기 종료 파이프를 쓰지 않는다 (pipefail 거짓 실패, 작업일지 0930 3.9)
set -euo pipefail

NS="application"
GW="neuroplan-gateway"
APP_HOST="app.neuroplan.cloud"
L_APP="https-public-app"
TLS_SECRET="${TLS_SECRET:-neuroplan-cloud-onprem-tls}"
VERIFY_IP="${VERIFY_IP:-192.168.24.100}"
VERIFY_PORT="${VERIFY_PORT:-443}"
OWNER_ANNO="neuroplan.io/app-public-listener"
OWNER_ANNO_PTR="neuroplan.io~1app-public-listener"
KEEP_LISTENERS=(https https-dr-health)   # 변경 전후 상태를 비교할 기존 listener

usage() { echo "사용법: bash $0 <gateway|verify|verify-route|rollback> [--apply]" >&2; exit 1; }
PHASE="${1:-}"
APPLY=0
case "${2:-}" in "") ;; --apply) APPLY=1 ;; *) usage ;; esac
case "$PHASE" in gateway|verify|verify-route|rollback) ;; *) usage ;; esac

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ⚠ %s → 중단 (변경 없음)\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
mode() { if [[ $APPLY -eq 1 ]]; then echo "APPLY"; else echo "DRY-RUN"; fi; }
for c in kubectl curl openssl base64 timeout; do command -v "$c" >/dev/null || die "$c 없음"; done

exists() { kubectl -n "$NS" get "$1" "$2" >/dev/null 2>&1; }
listener_names() { kubectl -n "$NS" get gateway "$GW" -o jsonpath='{range .spec.listeners[*]}{.name}{"\n"}{end}'; }
has_listener() { local n; while IFS= read -r n; do [[ "$n" == "$1" ]] && return 0; done < <(listener_names); return 1; }
listener_index() {
    local i=0 n
    while IFS= read -r n; do [[ "$n" == "$1" ]] && { echo "$i"; return 0; }; i=$((i+1)); done < <(listener_names)
    return 1
}
listener_field() { kubectl -n "$NS" get gateway "$GW" -o jsonpath="{.spec.listeners[?(@.name==\"$1\")]$2}"; }
listener_status() {
    kubectl -n "$NS" get gateway "$GW" -o jsonpath="{range .status.listeners[?(@.name==\"$1\")].conditions[*]}{.type}={.status} {end}"
}
listener_spec() {  # $1 listener → 비교용 한 줄 (group이 생략되면 빈 값 = core)
    local q f
    q=".spec.listeners[?(@.name==\"$1\")]"
    f="{${q}"
    kubectl -n "$NS" get gateway "$GW" -o jsonpath="hostname=${f}.hostname} port=${f}.port} protocol=${f}.protocol} mode=${f}.tls.mode} certs={range ${q}.tls.certificateRefs[*]}x{end} kind=${f}.tls.certificateRefs[0].kind} group=${f}.tls.certificateRefs[0].group} cert=${f}.tls.certificateRefs[0].name} from=${f}.allowedRoutes.namespaces.from}" \
        | sed 's/certs=x /certs=1 /; s/certs=xx*/certs=n/'
}
owner_anno() { kubectl -n "$NS" get gateway "$GW" -o jsonpath="{.metadata.annotations['neuroplan\.io/app-public-listener']}"; }

check_secret() {
    exists secret "$TLS_SECRET" || die "Secret ${NS}/${TLS_SECRET} 없음"
    local t san
    t="$(kubectl -n "$NS" get secret "$TLS_SECRET" -o jsonpath='{.type}')"
    [[ "$t" == "kubernetes.io/tls" ]] || die "Secret type=${t} (기대 kubernetes.io/tls)"
    san="$(kubectl -n "$NS" get secret "$TLS_SECRET" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)"
    [[ "$san" == *"DNS:${APP_HOST}"* ]] || die "인증서 SAN에 ${APP_HOST}가 없음: ${san//$'\n'/ }"
    log "Secret ${TLS_SECRET} SAN 확인: ${san//$'\n'/ }"
}

phase_gateway() {
    exists gateway "$GW" || die "Gateway ${NS}/${GW} 없음"
    check_secret
    log "변경 전 listener: $(listener_names | tr '\n' ' ')"
    if has_listener "$L_APP"; then
        local got want
        got="$(listener_spec "$L_APP")"
        want="hostname=${APP_HOST} port=443 protocol=HTTPS mode=Terminate certs=1 kind=Secret group= cert=${TLS_SECRET} from=Same"
        [[ "$got" == "$want" ]] || die "listener ${L_APP}가 이미 있으나 값이 다름
    기대: ${want}
    현재: ${got}"
        log "listener ${L_APP} 이미 있음 (전체 기대값 일치, annotation='$(owner_anno)') → 건너뜀"
        return 0
    fi
    local value patch
    value="$(printf '{"name":"%s","hostname":"%s","port":443,"protocol":"HTTPS","allowedRoutes":{"namespaces":{"from":"Same"}},"tls":{"mode":"Terminate","certificateRefs":[{"group":"","kind":"Secret","name":"%s"}]}}' "$L_APP" "$APP_HOST" "$TLS_SECRET")"
    patch="[{\"op\":\"add\",\"path\":\"/spec/listeners/-\",\"value\":${value}},"
    patch+="{\"op\":\"add\",\"path\":\"/metadata/annotations/${OWNER_ANNO_PTR}\",\"value\":\"created-by=setup_onprem_app_listener_1008.sh $(date +%FT%T%z)\"}]"
    log "listener ${L_APP} (${APP_HOST}, ${TLS_SECRET}) + annotation ${OWNER_ANNO} 추가 예정 ($(mode))"
    if [[ $APPLY -eq 1 ]]; then
        kubectl -n "$NS" patch gateway "$GW" --type=json -p "$patch"
        sleep 5
        log "status ${L_APP}: $(listener_status "$L_APP")"
        for n in "${KEEP_LISTENERS[@]}"; do log "기존 ${n}: $(listener_status "$n")"; done
    else
        kubectl -n "$NS" patch gateway "$GW" --type=json -p "$patch" --dry-run=server \
            -o jsonpath='{range .spec.listeners[*]}{.name}{" "}{.hostname}{" "}{.tls.certificateRefs[0].name}{"\n"}{end}'
    fi
}

https_probe() {  # $1 path → "HTTP코드 ssl_verify" (curl 비정상 종료·전송 실패면 "000 -")
    local r
    # curl 종료 코드가 0이 아니면(타임아웃·전송 오류 등) 출력이 남아 있어도 실패값으로 본다
    if r="$(curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}' --max-time 5 \
        --resolve "${APP_HOST}:${VERIFY_PORT}:${VERIFY_IP}" "https://${APP_HOST}:${VERIFY_PORT}$1" 2>/dev/null)"; then
        echo "${r:-000 -}"
    else
        echo "000 -"
    fi
}

check_listeners() {  # 반환: 실패 수
    local n st f=0
    for n in "$L_APP" "${KEEP_LISTENERS[@]}"; do
        st="$(listener_status "$n")"
        log "listener ${n}: ${st:-없음}"
        [[ "$st" == *"Accepted=True"* && "$st" == *"Programmed=True"* && "$st" == *"ResolvedRefs=True"* ]] || { log "  [FAIL] ${n} 상태 이상"; f=$((f+1)); }
    done
    return "$f"
}

phase_verify() {  # listener 단독 사전점검 (HTTPRoute 반영 전)
    local fail=0 san r
    check_listeners || fail=1
    log "annotation: '$(owner_anno)'"
    san="$(timeout 10 openssl s_client -connect "${VERIFY_IP}:${VERIFY_PORT}" -servername "$APP_HOST" </dev/null 2>/dev/null \
        | openssl x509 -noout -issuer -enddate -ext subjectAltName 2>/dev/null || true)"
    log "SNI ${APP_HOST} 인증서: ${san//$'\n'/ }"
    [[ "$san" == *"DNS:${APP_HOST}"* ]] || { log "  [FAIL] TLS 핸드셰이크 실패 또는 SAN에 ${APP_HOST} 없음 (unrecognized name이면 listener 없음)"; fail=1; }
    r="$(https_probe /)"
    log "  / : ${r}   (인증서 검증만 판정: ssl_verify=0, HTTP 코드는 HTTPRoute 반영 전이라 판정 안 함)"
    [[ "${r#* }" == "0" && "${r%% *}" != "000" ]] || { log "  [FAIL] 인증서 검증 실패 또는 전송 실패"; fail=1; }
    [[ $fail -eq 0 ]] || die "verify 실패 항목 있음"
    log "verify OK (listener 사전점검). HTTPRoute 반영 후 verify-route 실행"
}

phase_verify_route() {  # 최종 라우팅 검증 (GitOps HTTPRoute 반영 후)
    local fail=0 r1 r2
    check_listeners || fail=1
    r1="$(https_probe /)"
    r2="$(https_probe /api/learning/state)"
    log "  /                    : ${r1}   (기대 200 0 = Frontend)"
    log "  /api/learning/state  : ${r2}   (기대 401 0 = Backend 도달, 비인증)"
    [[ "$r1" == "200 0" ]] || { log "  [FAIL] / 기대 200 0, 실제 ${r1}"; fail=1; }
    [[ "$r2" == "401 0" ]] || { log "  [FAIL] /api/learning/state 기대 401 0, 실제 ${r2}"; fail=1; }
    [[ $fail -eq 0 ]] || die "verify-route 실패 항목 있음"
    log "verify-route OK (Frontend 200, Backend 401, 인증서 검증 통과)"
}

phase_rollback() {
    local idx
    idx="$(listener_index "$L_APP")" || { log "listener ${L_APP} 없음 → 할 일 없음"; return 0; }
    [[ "$(owner_anno)" == created-by=setup_onprem_app_listener_1008.sh* ]] \
        || die "listener ${L_APP}에 이 스크립트의 annotation이 없음 → 다른 곳에서 만든 것으로 보고 제거하지 않음"
    log "listener ${L_APP}(index ${idx}) + annotation 제거 예정 ($(mode))"
    [[ $APPLY -eq 1 ]] || { log "DRY-RUN: 실행은 --apply"; return 0; }
    kubectl -n "$NS" patch gateway "$GW" --type=json -p \
        "[{\"op\":\"test\",\"path\":\"/spec/listeners/${idx}/name\",\"value\":\"${L_APP}\"},{\"op\":\"remove\",\"path\":\"/spec/listeners/${idx}\"},{\"op\":\"remove\",\"path\":\"/metadata/annotations/${OWNER_ANNO_PTR}\"}]"
    log "남은 listener: $(listener_names | tr '\n' ' ')"
}

log "단계=${PHASE} 모드=$(mode) namespace=${NS}"
"phase_${PHASE//-/_}"
log "완료 (${PHASE}, $(mode))"
