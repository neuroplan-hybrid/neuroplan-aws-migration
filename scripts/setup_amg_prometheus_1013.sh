#!/bin/bash
# setup_amg_prometheus_1013.sh — Managed Grafana(AMG) → 온프렘 Prometheus 경로 허용·제거 (#98)
#
# 경로: AMG ENI(Private ROSA 서브넷) → VGW → S2S VPN → Infra VM(aws-vpn → nw-mgmt 포워딩) → Monitoring VM 192.168.14.73:9090
#   AWS 쪽(VPN 정적 경로·RT 경로·AMG SG)은 Terraform envs/prod/amg.tf (enable_amg_onprem_prometheus)
#   이 스크립트는 Infra VM firewalld만: 새 policy aws-to-mgmt (ingress aws-vpn, egress nw-mgmt, target DROP)
#   + rich rule 3개 (ROSA /20 3개 → 192.168.14.73:9090). Mgmt 대역 전체가 아니라 /32·9090만 (정현 #98 합의)
# 실행 위치: Infra VM (root)
#   bash setup_amg_prometheus_1013.sh <단계>            # dry-run (기본, 변경 없음)
#   bash setup_amg_prometheus_1013.sh <단계> --apply    # 적용
# 단계
#   allow   policy 생성 + 규칙 3개 (새 policy는 permanent만 가능 → reload 1회, 전후 ESP 개수 확인)
#           이미 있으면 기대값과 비교만, 다르면 중단. --apply 끝에 verify 자동 실행
#   verify  읽기만: policy 속성·규칙 runtime=permanent·nft 반영 3개·ESP 2개 → 하나라도 어긋나면 종료 코드 1
#   remove  policy 삭제 + reload (속성이 기대값과 정확히 같을 때만). 10/16 이후 AMG 미유지 결정 시
# 하지 않는 일
#   - Monitoring VM firewalld·복귀 경로(10.20.0.0/16 via 192.168.14.62), AMG 데이터 소스·대시보드 (정현)
#   - 기존 policy(aws-to-data·data-to-aws·aws-to-dmz·rosa-to-maxscale) 변경
# 참고: ROSA 서브넷에는 Worker도 있어 Worker → 9090도 허용됨. AMG ENI IP가 정해지면 /32로 좁힐 수 있음
set -euo pipefail

POLICY="aws-to-mgmt"
PRIORITY=-1
SRCS="10.20.16.0/20 10.20.32.0/20 10.20.48.0/20"   # modules/network rosa_subnets (AMG ENI 서브넷 후보)
DEST_IP="192.168.14.73"
PORT=9090

usage() { echo "사용법: bash $0 <allow|verify|remove> [--apply]" >&2; exit 1; }
PHASE="${1:-}"
APPLY=0
case "${2:-}" in "") ;; --apply) APPLY=1 ;; *) usage ;; esac
case "$PHASE" in allow|verify|remove) ;; *) usage ;; esac

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ⚠ %s → 중단\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
mode() { if [[ $APPLY -eq 1 ]]; then echo "APPLY"; else echo "DRY-RUN"; fi; }
[[ $EUID -eq 0 ]] || die "root로 실행"

rule() { printf 'rule family="ipv4" source address="%s" destination address="%s" port port="%s" protocol="tcp" accept' "$1" "$DEST_IP" "$PORT"; }
expected_rules() { local c; for c in $SRCS; do rule "$c"; echo; done | sort; }
esp_count() { ipsec trafficstatus 2>/dev/null | grep -c 'type=ESP' || true; }
policy_exists() { local p; for p in $(firewall-cmd --permanent --get-policies); do [[ "$p" == "$POLICY" ]] && return 0; done; return 1; }
pf() { firewall-cmd --permanent --policy="$POLICY" "$1"; }
policy_mismatch() {  # 기대값과 다른 속성을 출력 (모두 같으면 빈 문자열)
    local d="" v
    v="$(pf --list-ingress-zones)"; [[ "$v" == "aws-vpn" ]]  || d+="ingress=${v} "
    v="$(pf --list-egress-zones)";  [[ "$v" == "nw-mgmt" ]]  || d+="egress=${v} "
    v="$(pf --get-priority)";       [[ "$v" == "$PRIORITY" ]] || d+="priority=${v} "
    v="$(pf --get-target)";         [[ "$v" == "DROP" ]]     || d+="target=${v} "
    [[ "$(pf --list-rich-rules | sort)" == "$(expected_rules)" ]] || d+="rich-rules 불일치 "
    printf '%s' "$d"
}
nft_count() {  # nft 렌더링 예: "ip daddr 192.168.14.73 ip saddr 10.20.16.0/20 tcp dport 9090 accept"
    nft list ruleset 2>/dev/null | grep -cE "ip daddr ${DEST_IP//./\\.} .*tcp dport ${PORT}( |$)" || true
}

preflight() {
    local z active
    firewall-cmd --state >/dev/null 2>&1 || die "firewalld 미실행"
    active="$(firewall-cmd --get-active-zones)"
    for z in aws-vpn nw-mgmt; do
        grep -qx "$z" <<<"$active" || die "zone ${z} 비활성"
    done
    ip route get "$DEST_IP" >/dev/null 2>&1 || die "Infra VM → ${DEST_IP} 경로 없음"
    log "전제 OK: zone aws-vpn·nw-mgmt 활성, ${DEST_IP} 경로 $(ip -o route get "$DEST_IP" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'), ESP $(esp_count)개"
}

phase_verify() {
    local fail=0 mm rt n esp
    log "[verify] ${POLICY}"
    if policy_exists; then
        mm="$(policy_mismatch)"
        if [[ -z "$mm" ]]; then log "  [OK]   ingress aws-vpn, egress nw-mgmt, priority ${PRIORITY}, target DROP, 규칙 3개"
        else log "  [FAIL] 기대값과 다름: ${mm}"; fail=$((fail+1)); fi
        rt="$(firewall-cmd --policy="$POLICY" --list-rich-rules 2>/dev/null | sort || true)"
        if [[ "$rt" == "$(expected_rules)" ]]; then log "  [OK]   runtime = permanent"
        else log "  [FAIL] runtime 규칙이 permanent와 다름 (reload 필요?)"; fail=$((fail+1)); fi
        n="$(nft_count)"
        if [[ "$n" == "3" ]]; then log "  [OK]   nft 반영 규칙 3개"
        else log "  [FAIL] nft 반영 규칙 ${n}개 (기대 3)"; fail=$((fail+1)); fi
    else
        log "  [FAIL] policy ${POLICY} 없음"; fail=$((fail+1))
    fi
    esp="$(esp_count)"
    if [[ "$esp" -ge 2 ]]; then log "  [OK]   ESP ${esp}개"; else log "  [FAIL] ESP ${esp}개 (기대 2)"; fail=$((fail+1)); fi
    log "  [INFO] Monitoring VM 쪽(9090 허용·10.20.0.0/16 복귀 경로)과 AMG 데이터 소스 연결은 정현 확인"
    [[ $fail -eq 0 ]] || { log "  verify FAIL ${fail}개"; return 1; }
    return 0
}

phase_allow() {
    preflight
    if policy_exists; then
        local mm
        mm="$(policy_mismatch)"
        [[ -z "$mm" ]] || die "policy ${POLICY}가 이미 있으나 기대값과 다름 (${mm}) → 수동 확인"
        log "policy ${POLICY} 이미 있음 (모든 속성 일치) → 건너뜀"
    else
        log "policy ${POLICY} 생성 예정: aws-vpn → nw-mgmt, priority ${PRIORITY}, target DROP ($(mode))"
        expected_rules | sed 's/^/     /'
        if [[ $APPLY -eq 1 ]]; then
            local before after c
            before="$(esp_count)"
            firewall-cmd --permanent --new-policy="$POLICY" >/dev/null
            firewall-cmd --permanent --policy="$POLICY" --add-ingress-zone=aws-vpn >/dev/null
            firewall-cmd --permanent --policy="$POLICY" --add-egress-zone=nw-mgmt >/dev/null
            firewall-cmd --permanent --policy="$POLICY" --set-priority="$PRIORITY" >/dev/null
            firewall-cmd --permanent --policy="$POLICY" --set-target=DROP >/dev/null
            for c in $SRCS; do firewall-cmd --permanent --policy="$POLICY" --add-rich-rule="$(rule "$c")" >/dev/null; done
            firewall-cmd --reload >/dev/null
            sleep 2; after="$(esp_count)"
            log "   생성·reload 완료, ESP ${before} → ${after}"
            [[ "$after" -ge "$before" ]] || log "   ⚠ ESP 감소 → ipsec trafficstatus 확인"
        fi
    fi
    if [[ $APPLY -eq 1 ]]; then phase_verify || die "allow 적용 후 검증 실패 (위 [FAIL] 확인)"; fi
    return 0
}

phase_remove() {
    preflight
    if ! policy_exists; then log "policy ${POLICY} 없음 → 건너뜀"; return 0; fi
    local mm
    mm="$(policy_mismatch)"
    [[ -z "$mm" ]] || die "policy ${POLICY}가 기대값과 다름 (${mm}) → 자동 삭제하지 않음"
    log "policy ${POLICY} 삭제 예정 ($(mode))"
    if [[ $APPLY -eq 1 ]]; then
        firewall-cmd --permanent --delete-policy="$POLICY" >/dev/null
        firewall-cmd --reload >/dev/null
        sleep 2
        policy_exists && die "삭제 후에도 policy가 남아 있음"
        log "[verify] policy 없음, nft 규칙 $(nft_count)개 (기대 0), ESP $(esp_count)개"
    fi
    return 0
}

log "단계=${PHASE} 모드=$(mode)"
case "$PHASE" in
    allow)  phase_allow ;;
    verify) phase_verify || die "verify 실패 (위 [FAIL] 확인)" ;;
    remove) phase_remove ;;
esac
log "완료 (${PHASE}, $(mode))"
