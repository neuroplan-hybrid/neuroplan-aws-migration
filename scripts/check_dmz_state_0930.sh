#!/bin/bash
# check_dmz_state_0930.sh — DMZ 경로 온프렘 구간 점검 (읽기 전용, 작업일지 0930 11장)
#
# 실행 위치: Infra VM, lb1, lb2 (root). 호스트 이름(hostname -s)으로 점검 항목을 고른다
#   bash check_dmz_state_0930.sh
# 점검
#   infra   : DMZ NIC(ens161)·MAC·주소, NM 프로필 dmz, zone nw-dmz, policy aws-to-dmz(permanent = runtime, nft 반영),
#             라우트(24.100 → ens161, default는 ens161 아님), VIP ping·TCP 443
#   lb1/lb2 : ens192 24.x 주소, 10.20 경로 → 192.168.24.62 dev ens192(런타임·NM), zone nw-dmz 443,
#             Infra DMZ ping, keepalived·haproxy
# 범위 밖: AWS 발 실제 트래픽(DR NLB PoC), VPN 터널·라우트(check_vpn_state_0930.sh)
# 종료 코드: 0 = 전부 OK, 1 = FAIL 1개 이상 ([WARN]은 종료 코드에 영향 없음)
# 주의: 조건문에 "명령 | grep -q"를 쓰지 않는다 (pipefail 거짓 FAIL, 작업일지 0930 3.9)
set -uo pipefail

VPC_CIDR="10.20.0.0/16"
NLB_SRC="10.20.0.0/22"
DMZ_CIDR="192.168.24.0/24"
INFRA_DMZ_IP="192.168.24.62"
VIP="192.168.24.100"
LB_IPS="192.168.24.11 192.168.24.12"
INFRA_DMZ_NIC="ens161"
INFRA_DMZ_MAC="00:0c:29:6f:69:03"
LB_DMZ_NIC="ens192"
ZONE="nw-dmz"
VPN_ZONE="aws-vpn"
POLICY="aws-to-dmz"
CONN="dmz"
ICMP_RULE="rule family=\"ipv4\" source address=\"${DMZ_CIDR}\" icmp-type name=\"echo-request\" accept"
POLICY_RULE="rule family=\"ipv4\" source address=\"${NLB_SRC}\" destination address=\"${VIP}\" port port=\"443\" protocol=\"tcp\" accept"
fail=0

ok() { printf '  [OK]   %s\n' "$1"; }
ng() { printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1)); }
wn() { printf '  [WARN] %s\n' "$1"; }
fwp() { firewall-cmd --permanent "$@"; }
# runtime/permanent 한 항목 정보 (정렬, active 표시·interfaces 줄 제거) — 인자: --info-zone=… 또는 --info-policy=… [--permanent]
#   interfaces 줄 제외 이유: firewalld 1.3.4 --permanent --info-zone은 NM connection.zone으로 묶인 인터페이스를
#   표시하지 않음 (runtime "interfaces: ens161" / permanent "interfaces: " 빈 값, 0930 Infra 확인).
#   인터페이스 바인딩은 check_infra의 --get-zone-of-interface와 NM connection.zone으로 따로 점검
fw_info() { firewall-cmd "$@" 2>/dev/null | sed -E -e 's/ \((active|default)\)//g' -e '/^[[:space:]]*interfaces:/d' | sort; }

check_infra() {
    echo "[DMZ NIC ${INFRA_DMZ_NIC}]"
    if [[ -e "/sys/class/net/${INFRA_DMZ_NIC}" ]]; then
        local mac; mac="$(cat "/sys/class/net/${INFRA_DMZ_NIC}/address")"
        if [[ "$mac" == "$INFRA_DMZ_MAC" ]]; then ok "MAC ${mac}"; else ng "MAC ${mac} (기대 ${INFRA_DMZ_MAC})"; fi
    else
        ng "${INFRA_DMZ_NIC} 없음"
    fi
    local out; out="$(ip -4 -o addr show dev "$INFRA_DMZ_NIC" 2>/dev/null || true)"
    if [[ "$out" == *" ${INFRA_DMZ_IP}/24 "* ]]; then ok "${INFRA_DMZ_IP}/24"; else ng "${INFRA_DMZ_IP}/24 없음"; fi

    echo "[NM 프로필 ${CONN}]"
    local st ac nd gw z
    st="$(nmcli -g GENERAL.STATE con show "$CONN" 2>/dev/null || true)"
    ac="$(nmcli -g connection.autoconnect con show "$CONN" 2>/dev/null || true)"
    nd="$(nmcli -g ipv4.never-default con show "$CONN" 2>/dev/null || true)"
    gw="$(nmcli -g ipv4.gateway con show "$CONN" 2>/dev/null || true)"
    z="$(nmcli -g connection.zone con show "$CONN" 2>/dev/null || true)"
    if [[ "$st" == "activated" ]]; then ok "활성"; else ng "상태 '${st:-프로필 없음}'"; fi
    if [[ "$ac" == "yes" ]]; then ok "autoconnect yes (부팅 시 자동)"; else ng "autoconnect '${ac}'"; fi
    if [[ "$nd" == "yes" && -z "$gw" ]]; then ok "게이트웨이 없음·never-default"; else ng "gw '${gw}' never-default '${nd}'"; fi
    if [[ "$z" == "$ZONE" ]]; then ok "connection.zone ${ZONE}"; else ng "connection.zone '${z}' (기대 ${ZONE})"; fi

    echo "[firewalld]"
    z="$(firewall-cmd --get-zone-of-interface="$INFRA_DMZ_NIC" 2>/dev/null || echo none)"
    if [[ "$z" == "$ZONE" ]]; then ok "${INFRA_DMZ_NIC} → ${ZONE}"; else ng "${INFRA_DMZ_NIC} → ${z} (기대 ${ZONE})"; fi
    if [[ "$(fwp --zone="$ZONE" --get-target 2>/dev/null || true)" == "DROP" ]]; then ok "${ZONE} target DROP"; else ng "${ZONE} target DROP 아님"; fi
    if fwp --zone="$ZONE" --query-rich-rule="$ICMP_RULE" >/dev/null 2>&1; then ok "${ZONE} ICMP(24.0/24) 규칙"; else ng "${ZONE} ICMP 규칙 없음"; fi
    local extra
    extra="$(fwp --zone="$ZONE" --list-services 2>/dev/null) $(fwp --zone="$ZONE" --list-ports 2>/dev/null)"
    if [[ -z "${extra//[[:space:]]/}" ]]; then ok "${ZONE} 서비스·포트 없음"; else ng "${ZONE} 예상 밖 허용: ${extra}"; fi
    local p_ok=1
    fwp --policy="$POLICY" --query-ingress-zone="$VPN_ZONE" >/dev/null 2>&1 || p_ok=0
    fwp --policy="$POLICY" --query-egress-zone="$ZONE" >/dev/null 2>&1 || p_ok=0
    [[ "$(fwp --policy="$POLICY" --get-target 2>/dev/null || true)" == "DROP" ]] || p_ok=0
    if (( p_ok )); then ok "${POLICY}: ${VPN_ZONE} → ${ZONE}, target DROP"; else ng "${POLICY} zone/target 불일치 또는 없음"; fi
    if fwp --policy="$POLICY" --query-rich-rule="$POLICY_RULE" >/dev/null 2>&1; then ok "${POLICY}: ${NLB_SRC} → ${VIP}:443/tcp"; else ng "${POLICY} 443 규칙 없음"; fi
    local zr zp pr pp
    zr="$(fw_info --info-zone="$ZONE")";      zp="$(fw_info --permanent --info-zone="$ZONE")"
    pr="$(fw_info --info-policy="$POLICY")";  pp="$(fw_info --permanent --info-policy="$POLICY")"
    if [[ -n "$zr" && "$zr" == "$zp" && -n "$pr" && "$pr" == "$pp" ]]; then ok "runtime = permanent (${ZONE}, ${POLICY})"
    else ng "runtime ≠ permanent (${ZONE} 또는 ${POLICY}) → firewall-cmd --reload 필요 여부 확인"; fi
    local nft; nft="$(nft list ruleset 2>/dev/null || true)"
    if grep -qE "daddr ${VIP//./\\.} .*saddr ${NLB_SRC//./\\.} .*dport 443 accept|saddr ${NLB_SRC//./\\.} .*daddr ${VIP//./\\.} .*dport 443 accept" <<< "$nft"; then
        ok "nft 규칙 반영 (443 accept)"
    else
        ng "nft에 443 accept 규칙 없음"
    fi

    echo "[라우트]"
    local g; g="$(ip route get "$VIP" 2>/dev/null || true)"
    if [[ "$g" == *"dev ${INFRA_DMZ_NIC} "* ]]; then ok "${VIP} → dev ${INFRA_DMZ_NIC}"; else ng "${VIP} 경로: ${g}"; fi
    local d; d="$(ip -4 route show default 2>/dev/null || true)"
    if [[ -n "$d" && "$d" != *"dev ${INFRA_DMZ_NIC}"* ]]; then ok "default는 ${INFRA_DMZ_NIC} 아님"; else ng "default 경로 확인: '${d}'"; fi

    echo "[도달성 (Infra 출발, INPUT/OUTPUT — policy forward는 거치지 않음)]"
    local ip
    for ip in $LB_IPS; do
        if ping -c 2 -W 1 -I "$INFRA_DMZ_NIC" "$ip" >/dev/null 2>&1; then ok "ping ${ip}"; else wn "ping ${ip} 실패 (해당 LB 정지 여부 확인)"; fi
    done
    if ping -c 2 -W 1 -I "$INFRA_DMZ_NIC" "$VIP" >/dev/null 2>&1; then ok "ping VIP ${VIP}"; else ng "ping VIP ${VIP} 실패"; fi
    if timeout 3 bash -c "</dev/tcp/${VIP}/443" 2>/dev/null; then ok "TCP ${VIP}:443"; else ng "TCP ${VIP}:443 실패"; fi
    echo "  참고 VIP ARP: $(ip neigh show "$VIP" dev "$INFRA_DMZ_NIC" 2>/dev/null || true)"
}

check_lb() {
    echo "[DMZ NIC ${LB_DMZ_NIC}]"
    local out addr conn
    out="$(ip -4 -o addr show dev "$LB_DMZ_NIC" 2>/dev/null || true)"
    addr="$(awk '$4 ~ /^192\.168\.24\./ { print $4; exit }' <<< "$out")"
    if [[ -n "$addr" ]]; then ok "${addr}"; else ng "${DMZ_CIDR} 주소 없음"; fi
    if [[ "$out" == *" ${VIP}/"* ]]; then echo "  참고: VIP ${VIP} 보유 (MASTER)"; else echo "  참고: VIP 미보유"; fi

    echo "[라우트 ${VPC_CIDR}]"
    local g; g="$(ip route get 10.20.0.10 2>/dev/null || true)"
    if [[ "$g" == *"via ${INFRA_DMZ_IP} dev ${LB_DMZ_NIC} "* ]]; then ok "런타임 → via ${INFRA_DMZ_IP} dev ${LB_DMZ_NIC}"; else ng "런타임 경로: ${g}"; fi
    conn="$(nmcli -g GENERAL.CONNECTION device show "$LB_DMZ_NIC" 2>/dev/null || true)"
    local r; r="$(nmcli -g ipv4.routes con show "$conn" 2>/dev/null || true)"
    if [[ -n "$conn" && "$r" == *"${VPC_CIDR} ${INFRA_DMZ_IP}"* ]]; then ok "NM ${conn} ipv4.routes (재부팅 후 유지)"; else ng "NM ${conn:-프로필 없음} ipv4.routes '${r}'"; fi
    echo "  참고 rp_filter: all=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null) ${LB_DMZ_NIC}=$(sysctl -n "net.ipv4.conf.${LB_DMZ_NIC}.rp_filter" 2>/dev/null)"

    echo "[firewalld]"
    local z; z="$(firewall-cmd --get-zone-of-interface="$LB_DMZ_NIC" 2>/dev/null || echo none)"
    if [[ "$z" == "$ZONE" ]]; then ok "${LB_DMZ_NIC} → ${ZONE}"; else ng "${LB_DMZ_NIC} → ${z} (기대 ${ZONE})"; fi
    if firewall-cmd --zone="$z" --query-port=443/tcp >/dev/null 2>&1; then ok "${z} 443/tcp 허용"; else ng "${z} 443/tcp 없음"; fi

    echo "[도달성·서비스]"
    if ping -c 2 -W 1 -I "$LB_DMZ_NIC" "$INFRA_DMZ_IP" >/dev/null 2>&1; then ok "ping Infra DMZ ${INFRA_DMZ_IP}"; else ng "ping Infra DMZ ${INFRA_DMZ_IP} 실패"; fi
    local s st
    for s in keepalived haproxy; do
        st="$(systemctl is-active "$s" 2>/dev/null || true)"
        if [[ "$st" == "active" ]]; then ok "$s active"; else ng "$s ${st}"; fi
    done
}

HOST="$(hostname -s)"
echo "== 호스트: ${HOST}"
case "$HOST" in
    infra)   check_infra ;;
    lb1|lb2) check_lb ;;
    *)       echo "대상 호스트 아님(${HOST}): infra, lb1, lb2에서만 실행" >&2; exit 1 ;;
esac
echo "== 결과: FAIL ${fail}건"
(( fail == 0 ))
