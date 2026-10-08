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
#   bash setup_onprem_app_listener_1008.sh <gateway|verify|rollback> [--apply]   # 기본 dry-run
# 단계
#   gateway  listener 없으면 추가(+ annotation), 있으면 기대값 비교만 (다르면 중단)
#   verify   읽기만: listener 상태, SNI app.neuroplan.cloud 인증서·HTTP 코드
#   rollback annotation이 있을 때만(이 스크립트가 만든 경우만) listener 제거
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

usage() { echo "사용법: bash $0 <gateway|verify|rollback> [--apply]" >&2; exit 1; }
PHASE="${1:-}"
APPLY=0
case "${2:-}" in "") ;; --apply) APPLY=1 ;; *) usage ;; esac
case "$PHASE" in gateway|verify|rollback) ;; *) usage ;; esac

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
        local h c
        h="$(listener_field "$L_APP" '.hostname')"
        c="$(listener_field "$L_APP" '.tls.certificateRefs[0].name')"
        [[ "$h" == "$APP_HOST" && "$c" == "$TLS_SECRET" ]] || die "listener ${L_APP}가 이미 있으나 값이 다름 (hostname=${h}, cert=${c})"
        log "listener ${L_APP} 이미 있음 (기대값 일치, annotation='$(owner_anno)') → 건너뜀"
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

phase_verify() {
    local fail=0 st code route
    for n in "$L_APP" "${KEEP_LISTENERS[@]}"; do
        st="$(listener_status "$n")"
        log "listener ${n}: ${st:-없음}"
        [[ "$st" == *"Accepted=True"* && "$st" == *"Programmed=True"* && "$st" == *"ResolvedRefs=True"* ]] || { log "  [FAIL] ${n} 상태 이상"; fail=1; }
    done
    log "annotation: '$(owner_anno)'"
    log "SNI ${APP_HOST} → ${VERIFY_IP}:${VERIFY_PORT} 인증서:"
    timeout 10 openssl s_client -connect "${VERIFY_IP}:${VERIFY_PORT}" -servername "$APP_HOST" </dev/null 2>/dev/null \
        | openssl x509 -noout -issuer -enddate -ext subjectAltName 2>/dev/null || { log "  [FAIL] TLS 핸드셰이크 실패 (unrecognized name이면 listener 없음)"; fail=1; }
    code="$(curl -s -o /dev/null -w '%{http_code} ssl_verify=%{ssl_verify_result}' --max-time 5 \
        --resolve "${APP_HOST}:${VERIFY_PORT}:${VERIFY_IP}" "https://${APP_HOST}:${VERIFY_PORT}/" || true)"
    route="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        --resolve "${APP_HOST}:${VERIFY_PORT}:${VERIFY_IP}" "https://${APP_HOST}:${VERIFY_PORT}/api/learning/state" || true)"
    log "  /                    : ${code}   (HTTPRoute 반영 후 기대 200 ssl_verify=0, 반영 전 404)"
    log "  /api/learning/state  : ${route}   (HTTPRoute 반영 후 기대 401 = Backend 도달, 반영 전 404)"
    [[ $fail -eq 0 ]] || die "verify 실패 항목 있음"
    log "verify OK (HTTP 200/401은 HTTPRoute GitOps 반영 후 판단)"
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
"phase_${PHASE}"
log "완료 (${PHASE}, $(mode))"
