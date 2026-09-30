#!/bin/bash
# setup_dmz_nic_0930.sh — Infra VM DMZ NIC·firewalld + LB 반환 라우트 구성 (작업일지 0930 11장, DR NLB PoC 선수작업)
#
# DR 경로: Route 53 → DR NLB → S2S VPN → Infra VM(vti, aws-vpn) → DMZ NIC → VIP 192.168.24.100:443
# 실행 위치: Infra VM, lb1, lb2 (root). 호스트 이름(hostname -s)으로 할 일을 고른다
#   bash setup_dmz_nic_0930.sh            # dry-run (기본, 변경 없음)
#   bash setup_dmz_nic_0930.sh --apply    # 적용
# 순서: Infra 먼저 → lb1·lb2 (LB는 Infra DMZ 주소 ping이 되어야 진행)
#
# Infra (infra) — 하는 일 (여러 번 실행해도 결과 동일)
#   1) 전제 확인: DMZ NIC(ens161, MAC 일치), zone aws-vpn, firewalld runtime = permanent,
#      프로필 dmz가 없으면 ens161 미사용·192.168.24.62 주소 중복 없음 (arping -D) — 하나라도 어긋나면 아무것도 바꾸지 않고 중단
#   2) zone nw-dmz: target DROP, 192.168.24.0/24 ICMP echo만 허용 (서비스·포트 없음)
#   3) policy aws-to-dmz: aws-vpn → nw-dmz, target DROP, 10.20.0.0/22 → 192.168.24.100:443/tcp만
#   4) 2~3에서 permanent를 바꿨으면 firewall-cmd --reload (전후 ESP 수 출력)
#   5) NM 프로필 dmz: ens161, 192.168.24.62/24, 게이트웨이 없음, never-default, zone nw-dmz → con up
#      (zone을 먼저 만드는 이유: zone 없이 IP를 올리면 기본 zone public(ssh 허용)에 들어감)
# lb1·lb2 — 하는 일
#   1) 전제 확인: DMZ NIC(ens192) 24.x 주소, Infra DMZ(192.168.24.62) ping
#   2) 런타임 라우트 10.20.0.0/16 via 192.168.24.62 dev ens192 (ip route replace)
#   3) ens192의 NM 프로필(lb1 dmz / lb2 ens192)에 같은 라우트 영구 추가
#      (LB ens192는 rp_filter=1 → 10.20 반환 경로가 ens192가 아니면 DMZ로 들어온 요청을 버림)
# 하지 않는 일
#   - VMware NIC 추가 (콘솔 수동: Custom: VMnet0 Bridged)
#   - LB nmcli con up/reapply (Keepalived VIP가 빠질 수 있음), rp_filter·LB firewalld 변경
#   - VPN 설정(vti·aws.conf·updown·sysctl) 변경, sysctl --system (작업일지 0930 3.5)
#   - nw-dmz → aws-vpn 방향 policy (응답은 conntrack으로 통과)
#   - 기존 값이 다른 프로필·zone·policy 덮어쓰기 (중단하고 수동 확인)
# 확인: check_dmz_state_0930.sh
# 주의: "명령 | grep -q"·"| head" 같은 조기 종료 파이프를 쓰지 않는다 (pipefail 거짓 실패, 작업일지 0930 3.9)
set -euo pipefail

APPLY=0
case "${1:-}" in
    "")      ;;
    --apply) APPLY=1 ;;
    *)       echo "사용법: bash $0 [--apply]" >&2; exit 1 ;;
esac

VPC_CIDR="10.20.0.0/16"
NLB_SRC="10.20.0.0/22"               # DR NLB Public 서브넷 10.20.0~2.0/24
DMZ_CIDR="192.168.24.0/24"
INFRA_DMZ_IP="192.168.24.62"
VIP="192.168.24.100"
INFRA_DMZ_NIC="ens161"
INFRA_DMZ_MAC="00:0c:29:6f:69:03"    # VMware에서 추가한 NIC (0930)
LB_DMZ_NIC="ens192"
ZONE="nw-dmz"
VPN_ZONE="aws-vpn"
POLICY="aws-to-dmz"
CONN="dmz"
ICMP_RULE="rule family=\"ipv4\" source address=\"${DMZ_CIDR}\" icmp-type name=\"echo-request\" accept"
POLICY_RULE="rule family=\"ipv4\" source address=\"${NLB_SRC}\" destination address=\"${VIP}\" port port=\"443\" protocol=\"tcp\" accept"

run() {
    if (( APPLY )); then echo "  + $*"; "$@"; else echo "  [dry-run] $*"; fi
}
die() { echo "  ⚠ $* → 중단" >&2; exit 1; }
fwp() { firewall-cmd --permanent "$@"; }
# firewalld 전체 설정 덤프 (정렬, active/default 표시 제거) — 인자 --permanent 가능
fw_dump() {
    { firewall-cmd "$@" --list-all-zones; firewall-cmd "$@" --list-all-policies; } | sed -E 's/ \((active|default)\)//g' | sort
}
esp_count() { ipsec trafficstatus 2>/dev/null | grep -c 'type=ESP' || true; }

setup_infra() {
    echo "[1] 전제 확인"
    [[ -e "/sys/class/net/${INFRA_DMZ_NIC}" ]] || die "${INFRA_DMZ_NIC} 없음 (VMware에서 NIC 추가 먼저: Custom VMnet0 Bridged)"
    local mac; mac="$(cat "/sys/class/net/${INFRA_DMZ_NIC}/address")"
    [[ "$mac" == "$INFRA_DMZ_MAC" ]] || die "${INFRA_DMZ_NIC} MAC ${mac} ≠ ${INFRA_DMZ_MAC} (NIC 확인 후 스크립트 변수 수정)"
    echo "  ${INFRA_DMZ_NIC} MAC ${mac}"
    local zones policies
    zones=" $(fwp --get-zones) "
    policies=" $(fwp --get-policies) "
    [[ "$zones" == *" ${VPN_ZONE} "* ]] || die "zone ${VPN_ZONE} 없음 (VPN 구성 먼저)"
    if diff <(fw_dump) <(fw_dump --permanent) >/dev/null; then
        echo "  firewalld runtime = permanent (reload해도 사라지는 설정 없음)"
    else
        die "firewalld runtime ≠ permanent (reload하면 runtime 변경이 사라짐, 먼저 확인)"
    fi
    # 프로필을 새로 만들 경우의 전제는 firewalld를 바꾸기 전에 확인 (중간에 멈춰 일부만 적용되는 것 방지)
    local has_conn=0
    if nmcli -g connection.id con show "$CONN" >/dev/null 2>&1; then
        has_conn=1
        echo "  NM 프로필 ${CONN} 있음 → [5]에서 값 확인"
    else
        local cur
        cur="$(nmcli -g GENERAL.CONNECTION device show "$INFRA_DMZ_NIC" 2>/dev/null || true)"
        [[ -z "$cur" ]] || die "${INFRA_DMZ_NIC}에 다른 프로필(${cur})이 활성"
        if arping -D -q -c 2 -I "$INFRA_DMZ_NIC" "$INFRA_DMZ_IP"; then
            echo "  ${INFRA_DMZ_IP} 응답 없음 (주소 중복 없음)"
        else
            die "${INFRA_DMZ_IP}에 응답하는 장비 있음 (주소 중복)"
        fi
    fi

    local changed=0
    echo "[2] zone ${ZONE}"
    if [[ "$zones" == *" ${ZONE} "* ]]; then
        if [[ "$(fwp --zone="$ZONE" --get-target)" == "DROP" ]]; then echo "  이미 target DROP"
        else run firewall-cmd --permanent --zone="$ZONE" --set-target=DROP; changed=1; fi
        if fwp --zone="$ZONE" --query-rich-rule="$ICMP_RULE" >/dev/null; then echo "  이미 ICMP 규칙"
        else run firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$ICMP_RULE"; changed=1; fi
        local extra
        extra="$(fwp --zone="$ZONE" --list-services) $(fwp --zone="$ZONE" --list-ports) $(fwp --zone="$ZONE" --list-rich-rules | grep -vF "$ICMP_RULE" || true)"
        [[ -z "${extra//[[:space:]]/}" ]] || echo "  ⚠ 예상 밖 허용 (수동 확인): ${extra}"
    else
        run firewall-cmd --permanent --new-zone="$ZONE"
        run firewall-cmd --permanent --zone="$ZONE" --set-target=DROP
        run firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$ICMP_RULE"
        changed=1
    fi

    echo "[3] policy ${POLICY} (${VPN_ZONE} → ${ZONE})"
    if [[ "$policies" == *" ${POLICY} "* ]]; then
        if fwp --policy="$POLICY" --query-ingress-zone="$VPN_ZONE" >/dev/null; then echo "  이미 ingress ${VPN_ZONE}"
        else run firewall-cmd --permanent --policy="$POLICY" --add-ingress-zone="$VPN_ZONE"; changed=1; fi
        if fwp --policy="$POLICY" --query-egress-zone="$ZONE" >/dev/null; then echo "  이미 egress ${ZONE}"
        else run firewall-cmd --permanent --policy="$POLICY" --add-egress-zone="$ZONE"; changed=1; fi
        if [[ "$(fwp --policy="$POLICY" --get-target)" == "DROP" ]]; then echo "  이미 target DROP"
        else run firewall-cmd --permanent --policy="$POLICY" --set-target=DROP; changed=1; fi
        if fwp --policy="$POLICY" --query-rich-rule="$POLICY_RULE" >/dev/null; then echo "  이미 443 규칙"
        else run firewall-cmd --permanent --policy="$POLICY" --add-rich-rule="$POLICY_RULE"; changed=1; fi
        local pextra
        pextra="$(fwp --policy="$POLICY" --list-rich-rules | grep -vF "$POLICY_RULE" || true)"
        [[ -z "$pextra" ]] || echo "  ⚠ 예상 밖 규칙 (수동 확인): ${pextra}"
    else
        run firewall-cmd --permanent --new-policy="$POLICY"
        run firewall-cmd --permanent --policy="$POLICY" --add-ingress-zone="$VPN_ZONE"
        run firewall-cmd --permanent --policy="$POLICY" --add-egress-zone="$ZONE"
        run firewall-cmd --permanent --policy="$POLICY" --set-target=DROP
        run firewall-cmd --permanent --policy="$POLICY" --add-rich-rule="$POLICY_RULE"
        changed=1
    fi

    echo "[4] firewalld reload"
    if (( changed )); then
        local before after
        before="$(esp_count)"
        run firewall-cmd --reload
        if (( APPLY )); then
            sleep 2
            after="$(esp_count)"
            echo "  ESP ${before} → ${after}"
            [[ "$after" == "$before" ]] || echo "  ⚠ ESP 수가 바뀜 → check_vpn_state_0930.sh로 확인"
        fi
    else
        echo "  변경 없음 → reload 안 함"
    fi

    echo "[5] NM 프로필 ${CONN} (${INFRA_DMZ_NIC} ${INFRA_DMZ_IP}/24)"
    if (( has_conn )); then
        local ifn addr z gw nd st
        ifn="$(nmcli -g connection.interface-name con show "$CONN")"
        addr="$(nmcli -g ipv4.addresses con show "$CONN")"
        z="$(nmcli -g connection.zone con show "$CONN")"
        gw="$(nmcli -g ipv4.gateway con show "$CONN")"
        nd="$(nmcli -g ipv4.never-default con show "$CONN")"
        if [[ "$ifn" == "$INFRA_DMZ_NIC" && "$addr" == "${INFRA_DMZ_IP}/24" && "$z" == "$ZONE" && -z "$gw" && "$nd" == "yes" ]]; then
            echo "  이미 설정 (ifname ${ifn}, ${addr}, zone ${z}, gw 없음, never-default)"
        else
            die "기존 프로필 ${CONN} 값이 다름 (ifname=${ifn} addr=${addr} zone=${z} gw=${gw} never-default=${nd}, 수동 확인)"
        fi
        st="$(nmcli -g GENERAL.STATE con show "$CONN" 2>/dev/null || true)"
        if [[ "$st" == "activated" ]]; then echo "  이미 활성"; else run nmcli con up "$CONN"; fi
    else
        run nmcli con add type ethernet con-name "$CONN" ifname "$INFRA_DMZ_NIC" \
            connection.zone "$ZONE" connection.autoconnect yes \
            ipv4.method manual ipv4.addresses "${INFRA_DMZ_IP}/24" \
            ipv4.never-default yes ipv4.ignore-auto-dns yes ipv6.method disabled
        run nmcli con up "$CONN"
    fi

    echo "[6] 결과 (읽기 전용)"
    ip -br -4 addr show dev "$INFRA_DMZ_NIC" | sed 's/^/  /'
    echo "  zone: $(firewall-cmd --get-zone-of-interface="$INFRA_DMZ_NIC" 2>&1 || true)"
    echo "  $(ip route get "$VIP" 2>&1 || true)"
}

setup_lb() {
    echo "[1] 전제 확인"
    local out addr conn
    out="$(ip -4 -o addr show dev "$LB_DMZ_NIC" 2>/dev/null || true)"
    addr="$(awk '$4 ~ /^192\.168\.24\./ { print $4; exit }' <<< "$out")"
    [[ -n "$addr" ]] || die "${LB_DMZ_NIC}에 ${DMZ_CIDR} 주소 없음"
    conn="$(nmcli -g GENERAL.CONNECTION device show "$LB_DMZ_NIC" 2>/dev/null || true)"
    [[ -n "$conn" ]] || die "${LB_DMZ_NIC}의 NM 프로필 없음"
    echo "  ${LB_DMZ_NIC} ${addr}, 프로필 ${conn}"
    ping -c 2 -W 1 -I "$LB_DMZ_NIC" "$INFRA_DMZ_IP" >/dev/null || die "Infra DMZ ${INFRA_DMZ_IP} ping 실패 (Infra 먼저)"
    echo "  Infra DMZ ${INFRA_DMZ_IP} ping OK"

    echo "[2] 런타임 라우트 ${VPC_CIDR} via ${INFRA_DMZ_IP} dev ${LB_DMZ_NIC}"
    local rt
    rt="$(ip -4 route show "$VPC_CIDR" 2>/dev/null || true)"
    if [[ "$rt" == *"via ${INFRA_DMZ_IP} dev ${LB_DMZ_NIC}"* ]]; then echo "  이미 있음"
    else run ip route replace "$VPC_CIDR" via "$INFRA_DMZ_IP" dev "$LB_DMZ_NIC"; fi

    echo "[3] NM 프로필 ${conn} ipv4.routes (con up 안 함)"
    local r
    r="$(nmcli -g ipv4.routes con show "$conn")"
    if [[ "$r" == *"${VPC_CIDR} ${INFRA_DMZ_IP}"* ]]; then echo "  이미 있음: ${r}"
    else run nmcli con mod "$conn" +ipv4.routes "${VPC_CIDR} ${INFRA_DMZ_IP}"; fi

    echo "[4] 결과 (읽기 전용)"
    echo "  $(ip route get 10.20.0.10 2>&1 || true)"
    echo "  NM routes: $(nmcli -g ipv4.routes con show "$conn")"
    out="$(ip -4 -o addr show dev "$LB_DMZ_NIC" 2>/dev/null || true)"
    if [[ "$out" == *" ${VIP}/"* ]]; then echo "  VIP ${VIP} 보유 (MASTER)"; else echo "  VIP ${VIP} 미보유"; fi
    echo "  keepalived/haproxy: $(systemctl is-active keepalived haproxy 2>/dev/null | xargs || true)"
}

(( EUID == 0 )) || { echo "root로 실행해야 합니다" >&2; exit 1; }
HOST="$(hostname -s)"
echo "== 호스트: ${HOST} · 모드: $( (( APPLY )) && echo APPLY || echo DRY-RUN )"
case "$HOST" in
    infra)   setup_infra ;;
    lb1|lb2) setup_lb ;;
    *)       echo "대상 호스트 아님(${HOST}): infra, lb1, lb2에서만 실행" >&2; exit 1 ;;
esac
echo "== 완료. 확인: bash check_dmz_state_0930.sh"
