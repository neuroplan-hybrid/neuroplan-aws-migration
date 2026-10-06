#!/bin/bash
# setup_dr_health_1006.sh — 온프렘 dr-health 호스트 구성 (작업일지 1006 4.2·6.5)
#
# Route 53 HC 경로: https://dr-health.neuroplan.cloud/actuator/health/routing
#   Route 53 → DR NLB → S2S VPN → Infra VM → VIP 192.168.24.100:443 → HAProxy(TCP) → NGF(NodePort 30443, TLS 종료)
#   → HTTPRoute dr-health → Service neuroplan-backend-health(publishNotReadyAddresses) → Backend Pod
# 실행 위치: 온프렘 cp1 (root, kubectl). 단계별로 실행한다
#   bash setup_dr_health_1006.sh <단계>            # dry-run (기본, 변경 없음: 서버 dry-run + 계획 출력)
#   bash setup_dr_health_1006.sh <단계> --apply    # 적용
# 단계 (순서대로)
#   service  Health 전용 Service 생성 → ClusterIP로 /actuator/health/liveness 확인 (인증서 불필요, 지금 가능)
#   gateway  Gateway listener 2개 추가: https-public-app(app.neuroplan.cloud), https-dr-health(dr-health.neuroplan.cloud)
#            전제: 온프렘 인증서 Secret(TLS_SECRET)이 있고 SAN에 두 이름이 모두 있음
#   route    HTTPRoute dr-health: GET + Exact /actuator/health/routing → neuroplan-backend-health:8080
#   verify   읽기만. Service·listener·Route 상태 + VIP로 SNI 요청 (routing 200, 그 외 actuator 404)
#   rollback route → listener → Service 순서로 제거 (--apply 필요)
#
# 하는 일 (여러 번 실행해도 결과 동일)
#   - 없으면 만들고, 있으면 기대값과 비교만 한다. 값이 다르면 자동 보정하지 않고 중단
#   - Gateway는 kubectl patch(JSON add)로 listener만 추가. 기존 listener(https, grafana-https)·인증서는 건드리지 않음
# 하지 않는 일
#   - 인증서 발급·Secret 생성 (인증서 작업 1번, 별도)
#   - app.neuroplan.cloud HTTPRoute hostname 추가 (Argo CD 관리 neuroplan-login-mvp → GitOps PR)
#   - Backend routing health group 추가 (Application Repository, 정현) — 배포 전에는 /routing이 404
#   - Gateway kubectl apply (last-applied가 nplan-tls-v1이라 apply하면 인증서가 되돌아감)
# 결정 근거: Route 53 HC = /actuator/health/routing (DB 제외, 1006 6.5)
#   K8s readinessProbe가 DB 포함 → DB 장애 시 Pod가 기존 Service Endpoint에서 빠짐
#   → Health 전용 Service는 publishNotReadyAddresses: true로 NotReady Pod도 포함 (DB 장애로 Route 53이 전환되지 않게)
# 주의: "명령 | grep -q"·"| head" 같은 조기 종료 파이프를 쓰지 않는다 (pipefail 거짓 실패, 작업일지 0930 3.9)
set -euo pipefail

NS="application"
GW="neuroplan-gateway"
BACKEND_SVC="neuroplan-backend"
HEALTH_SVC="neuroplan-backend-health"
SELECTOR_KEY="app.kubernetes.io/name"
SELECTOR_VAL="neuroplan-backend"
PORT=8080
ROUTE="dr-health"
APP_HOST="app.neuroplan.cloud"
DR_HOST="dr-health.neuroplan.cloud"
L_APP="https-public-app"
L_DR="https-dr-health"
TLS_SECRET="${TLS_SECRET:-neuroplan-cloud-onprem-tls}"
HC_PATH="/actuator/health/routing"
VERIFY_IP="${VERIFY_IP:-192.168.24.100}"   # 기본: DMZ VIP (실제 DR 경로와 같은 HAProxy → NGF)
VERIFY_PORT="${VERIFY_PORT:-443}"
LABEL_K="neuroplan.io/owner"
LABEL_V="heejae-dr-health"

usage() { echo "사용법: bash $0 <service|gateway|route|verify|rollback> [--apply]" >&2; exit 1; }
PHASE="${1:-}"
APPLY=0
case "${2:-}" in
    "")      ;;
    --apply) APPLY=1 ;;
    *)       usage ;;
esac
case "$PHASE" in service|gateway|route|verify|rollback) ;; *) usage ;; esac

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ⚠ %s → 중단 (변경 없음)\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
mode() { if [[ $APPLY -eq 1 ]]; then echo "APPLY"; else echo "DRY-RUN"; fi; }

need_cmds() { for c in kubectl curl openssl base64; do command -v "$c" >/dev/null || die "$c 없음"; done; }

# ---------- manifest ----------
health_svc_yaml() {
cat <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${HEALTH_SVC}
  namespace: ${NS}
  labels:
    ${LABEL_K}: ${LABEL_V}
  annotations:
    neuroplan.io/purpose: "Route 53 HC 전용 (dr-health). NotReady Pod 포함 — 작업일지 1006 6.5"
spec:
  type: ClusterIP
  selector:
    ${SELECTOR_KEY}: ${SELECTOR_VAL}
  publishNotReadyAddresses: true
  ports:
    - name: http
      port: ${PORT}
      targetPort: http
      protocol: TCP
EOF
}

route_yaml() {
cat <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${ROUTE}
  namespace: ${NS}
  labels:
    ${LABEL_K}: ${LABEL_V}
spec:
  parentRefs:
    - name: ${GW}
      sectionName: ${L_DR}
  hostnames:
    - ${DR_HOST}
  rules:
    - matches:
        - method: GET
          path:
            type: Exact
            value: ${HC_PATH}
      backendRefs:
        - name: ${HEALTH_SVC}
          port: ${PORT}
EOF
}

listener_json() {  # $1 name, $2 hostname
    printf '{"name":"%s","hostname":"%s","port":443,"protocol":"HTTPS","allowedRoutes":{"namespaces":{"from":"Same"}},"tls":{"mode":"Terminate","certificateRefs":[{"group":"","kind":"Secret","name":"%s"}]}}' "$1" "$2" "$TLS_SECRET"
}

# ---------- 조회 ----------
exists() { kubectl -n "$NS" get "$1" "$2" >/dev/null 2>&1; }
listener_names() { kubectl -n "$NS" get gateway "$GW" -o jsonpath='{range .spec.listeners[*]}{.name}{"\n"}{end}'; }
has_listener() { local n; while IFS= read -r n; do [[ "$n" == "$1" ]] && return 0; done < <(listener_names); return 1; }
listener_field() {  # $1 listener, $2 jsonpath 뒤부분
    kubectl -n "$NS" get gateway "$GW" -o jsonpath="{.spec.listeners[?(@.name==\"$1\")]$2}"
}
listener_index() {
    local i=0 n
    while IFS= read -r n; do [[ "$n" == "$1" ]] && { echo "$i"; return 0; }; i=$((i+1)); done < <(listener_names)
    return 1
}
listener_status() {  # $1 listener → "Accepted=True Programmed=True ResolvedRefs=True"
    kubectl -n "$NS" get gateway "$GW" -o jsonpath="{range .status.listeners[?(@.name==\"$1\")].conditions[*]}{.type}={.status} {end}"
}

# ---------- 단계 ----------
phase_service() {
    exists deploy "$BACKEND_SVC" || die "Deployment ${NS}/${BACKEND_SVC} 없음"
    local sel
    sel="$(kubectl -n "$NS" get deploy "$BACKEND_SVC" -o jsonpath="{.spec.selector.matchLabels['app\.kubernetes\.io/name']}")"
    [[ "$sel" == "$SELECTOR_VAL" ]] || die "Deployment selector ${SELECTOR_KEY}=${sel} (기대 ${SELECTOR_VAL})"
    local tp
    tp="$(kubectl -n "$NS" get svc "$BACKEND_SVC" -o jsonpath='{.spec.ports[0].targetPort}')"
    [[ "$tp" == "http" ]] || die "기존 Service targetPort=${tp} (기대 http)"

    if exists svc "$HEALTH_SVC"; then
        local pna s
        pna="$(kubectl -n "$NS" get svc "$HEALTH_SVC" -o jsonpath='{.spec.publishNotReadyAddresses}')"
        s="$(kubectl -n "$NS" get svc "$HEALTH_SVC" -o jsonpath="{.spec.selector['app\.kubernetes\.io/name']}")"
        [[ "$pna" == "true" && "$s" == "$SELECTOR_VAL" ]] || die "${HEALTH_SVC}가 이미 있으나 값이 다름 (publishNotReadyAddresses=${pna}, selector=${s}) → 수동 확인"
        log "Service ${HEALTH_SVC} 이미 있음 (기대값 일치) → 건너뜀"
    else
        log "Service ${HEALTH_SVC} 생성 예정 ($(mode))"
        health_svc_yaml
        if [[ $APPLY -eq 1 ]]; then
            health_svc_yaml | kubectl apply -f -
        else
            health_svc_yaml | kubectl apply --dry-run=server -f -
            return 0
        fi
    fi

    local cip ep_count
    cip="$(kubectl -n "$NS" get svc "$HEALTH_SVC" -o jsonpath='{.spec.clusterIP}')"
    sleep 2
    ep_count="$(kubectl -n "$NS" get endpointslices -l "kubernetes.io/service-name=${HEALTH_SVC}" -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}' | grep -c . || true)"
    log "ClusterIP ${cip}, Endpoint ${ep_count}개 (Backend Pod 수와 같아야 함)"
    log "liveness: $(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${cip}:${PORT}/actuator/health/liveness")"
    log "routing : $(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${cip}:${PORT}${HC_PATH}") (routing group 배포 전이면 404가 정상)"
}

check_secret() {
    exists secret "$TLS_SECRET" || die "Secret ${NS}/${TLS_SECRET} 없음 (인증서 작업 먼저)"
    local t san
    t="$(kubectl -n "$NS" get secret "$TLS_SECRET" -o jsonpath='{.type}')"
    [[ "$t" == "kubernetes.io/tls" ]] || die "Secret type=${t} (기대 kubernetes.io/tls)"
    san="$(kubectl -n "$NS" get secret "$TLS_SECRET" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)"
    [[ "$san" == *"DNS:${APP_HOST}"* && "$san" == *"DNS:${DR_HOST}"* ]] || die "인증서 SAN에 ${APP_HOST}·${DR_HOST}가 모두 있어야 함: ${san//$'\n'/ }"
    log "Secret ${TLS_SECRET} 확인: ${san//$'\n'/ }"
    kubectl -n "$NS" get secret "$TLS_SECRET" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -enddate
}

phase_gateway() {
    exists gateway "$GW" || die "Gateway ${NS}/${GW} 없음"
    check_secret
    local ops=() name host
    for pair in "${L_APP}|${APP_HOST}" "${L_DR}|${DR_HOST}"; do
        name="${pair%%|*}"; host="${pair##*|}"
        if has_listener "$name"; then
            local h c
            h="$(listener_field "$name" '.hostname')"
            c="$(listener_field "$name" '.tls.certificateRefs[0].name')"
            [[ "$h" == "$host" && "$c" == "$TLS_SECRET" ]] || die "listener ${name}가 이미 있으나 값이 다름 (hostname=${h}, cert=${c}) → 수동 확인"
            log "listener ${name} 이미 있음 (기대값 일치) → 건너뜀"
        else
            ops+=("{\"op\":\"add\",\"path\":\"/spec/listeners/-\",\"value\":$(listener_json "$name" "$host")}")
            log "listener ${name} (${host}) 추가 예정"
        fi
    done
    log "변경 전 listener: $(listener_names | tr '\n' ' ')"
    [[ ${#ops[@]} -eq 0 ]] && { log "추가할 listener 없음"; return 0; }
    local patch
    patch="[$(IFS=,; echo "${ops[*]}")]"
    if [[ $APPLY -eq 1 ]]; then
        kubectl -n "$NS" patch gateway "$GW" --type=json -p "$patch"
        sleep 5
        for name in "$L_APP" "$L_DR"; do log "status ${name}: $(listener_status "$name")"; done
        for name in https grafana-https; do log "기존 ${name}: $(listener_status "$name")"; done
    else
        kubectl -n "$NS" patch gateway "$GW" --type=json -p "$patch" --dry-run=server -o jsonpath='{range .spec.listeners[*]}{.name}{" "}{.hostname}{" "}{.tls.certificateRefs[0].name}{"\n"}{end}'
    fi
}

phase_route() {
    has_listener "$L_DR" || die "listener ${L_DR} 없음 (gateway 단계 먼저)"
    exists svc "$HEALTH_SVC" || die "Service ${HEALTH_SVC} 없음 (service 단계 먼저)"
    if exists httproute "$ROUTE"; then
        local h p b
        h="$(kubectl -n "$NS" get httproute "$ROUTE" -o jsonpath='{.spec.hostnames[*]}')"
        p="$(kubectl -n "$NS" get httproute "$ROUTE" -o jsonpath='{.spec.rules[*].matches[*].path.value}')"
        b="$(kubectl -n "$NS" get httproute "$ROUTE" -o jsonpath='{.spec.rules[*].backendRefs[*].name}')"
        [[ "$h" == "$DR_HOST" && "$p" == "$HC_PATH" && "$b" == "$HEALTH_SVC" ]] || die "HTTPRoute ${ROUTE}가 이미 있으나 값이 다름 (host=${h}, path=${p}, backend=${b})"
        log "HTTPRoute ${ROUTE} 이미 있음 (기대값 일치) → 건너뜀"
        return 0
    fi
    log "HTTPRoute ${ROUTE} 생성 예정 ($(mode))"
    route_yaml
    if [[ $APPLY -eq 1 ]]; then
        route_yaml | kubectl apply -f -
        sleep 3
        log "Route 상태: $(kubectl -n "$NS" get httproute "$ROUTE" -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {end}')"
    else
        route_yaml | kubectl apply --dry-run=server -f -
    fi
}

sni_code() {  # $1 path → HTTP 코드
    curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
        --resolve "${DR_HOST}:${VERIFY_PORT}:${VERIFY_IP}" "https://${DR_HOST}:${VERIFY_PORT}$1"
}

phase_verify() {
    log "Service ${HEALTH_SVC}: $(kubectl -n "$NS" get svc "$HEALTH_SVC" -o jsonpath='{.spec.clusterIP} pna={.spec.publishNotReadyAddresses}' 2>/dev/null || echo 없음)"
    for name in "$L_APP" "$L_DR" https grafana-https; do
        log "listener ${name}: $(listener_status "$name")"
    done
    log "HTTPRoute ${ROUTE}: $(kubectl -n "$NS" get httproute "$ROUTE" -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {end}' 2>/dev/null || echo 없음)"
    log "SNI ${DR_HOST} → ${VERIFY_IP}:${VERIFY_PORT}"
    log "  ${HC_PATH}                 : $(sni_code "$HC_PATH")   (기대 200, routing group 배포 전이면 404)"
    log "  /actuator/health/readiness       : $(sni_code /actuator/health/readiness)   (기대 404, 노출 안 함)"
    log "  /actuator                        : $(sni_code /actuator)   (기대 404)"
    log "  /api                             : $(sni_code /api)   (기대 404)"
    log "인증서 (SNI ${DR_HOST}):"
    openssl s_client -connect "${VERIFY_IP}:${VERIFY_PORT}" -servername "$DR_HOST" </dev/null 2>/dev/null \
        | openssl x509 -noout -subject -issuer -enddate 2>/dev/null || log "  인증서 조회 실패"
}

phase_rollback() {
    [[ $APPLY -eq 1 ]] || { log "DRY-RUN: 제거 대상 — HTTPRoute ${ROUTE}, listener ${L_DR}·${L_APP}, Service ${HEALTH_SVC} (실행은 --apply)"; return 0; }
    if exists httproute "$ROUTE"; then kubectl -n "$NS" delete httproute "$ROUTE"; fi
    local name idx
    for name in "$L_DR" "$L_APP"; do
        if idx="$(listener_index "$name")"; then
            kubectl -n "$NS" patch gateway "$GW" --type=json \
                -p "[{\"op\":\"test\",\"path\":\"/spec/listeners/${idx}/name\",\"value\":\"${name}\"},{\"op\":\"remove\",\"path\":\"/spec/listeners/${idx}\"}]"
        fi
    done
    if exists svc "$HEALTH_SVC"; then kubectl -n "$NS" delete svc "$HEALTH_SVC"; fi
    log "남은 listener: $(listener_names | tr '\n' ' ')"
}

need_cmds
log "단계=${PHASE} 모드=$(mode) namespace=${NS}"
"phase_${PHASE}"
log "완료 (${PHASE}, $(mode))"
