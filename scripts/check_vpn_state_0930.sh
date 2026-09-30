#!/bin/bash
# check_vpn_state_0930.sh — Infra VM VPN 자동 복구 상태 점검 (읽기 전용, 작업일지 0930 9장)
#
# 실행 위치: Infra VM (root). 10/6·10/12 아침 부팅 후, 재부팅 검증 후 사용
#   bash check_vpn_state_0930.sh          # 온프렘만
#   bash check_vpn_state_0930.sh --aws    # + VGW 텔레메트리 (AWS CLI, ap-northeast-2)
# 종료 코드: 0 = 전부 OK, 1 = FAIL 1개 이상 (preflight에서 그대로 사용)
set -uo pipefail

VPC_CIDR="10.20.0.0/16"
REGION="ap-northeast-2"
WRAPPER="/usr/local/sbin/neuroplan-vti-updown"
AWS_CONF="/etc/ipsec.d/aws.conf"
fail=0

ok() { printf '  [OK]   %s\n' "$1"; }
ng() { printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1)); }
expect_sysctl() {
    local cur; cur="$(sysctl -n "$1" 2>/dev/null || echo '?')"
    if [[ "$cur" == "$2" ]]; then ok "$1 = $2"; else ng "$1 = $cur (기대 $2)"; fi
}

echo "== 부팅 시각: $(uptime -s)"

echo "[서비스]"
for s in ipsec named node_exporter; do
    st="$(systemctl is-active "$s" 2>/dev/null || true)"
    if [[ "$st" == "active" ]]; then ok "$s active"; else ng "$s $st"; fi
done
st="$(systemctl is-enabled ipsec 2>/dev/null || true)"
if [[ "$st" == "enabled" ]]; then ok "ipsec enabled"; else ng "ipsec $st (부팅 시 자동 시작 안 됨)"; fi

echo "[updown 훅]"
if [[ -x "$WRAPPER" ]]; then ok "$WRAPPER 실행 가능"; else ng "$WRAPPER 없음/실행 불가"; fi
if grep -qE "^\s*leftupdown=${WRAPPER}\s*$" "$AWS_CONF"; then ok "aws.conf leftupdown 설정"; else ng "aws.conf leftupdown 없음"; fi

echo "[터널]"
esp="$(ipsec trafficstatus 2>/dev/null | grep -c 'type=ESP' || true)"
if [[ "$esp" == "2" ]]; then ok "ESP 2개"; else ng "ESP ${esp}개 (기대 2)"; fi

echo "[라우트 $VPC_CIDR]"
for pair in "vti1 100" "vti2 200"; do
    read -r dev metric <<< "$pair"
    if ip -4 route show "$VPC_CIDR" | grep -qE "dev ${dev} .*metric ${metric}\b"; then
        ok "dev $dev metric $metric"
    else
        ng "dev $dev metric $metric 없음"
    fi
done

echo "[sysctl]"
expect_sysctl net.ipv4.ip_forward 1
expect_sysctl net.ipv4.conf.all.rp_filter 0
for i in vti1 vti2; do
    expect_sysctl "net.ipv4.conf.${i}.rp_filter" 2
    expect_sysctl "net.ipv4.conf.${i}.disable_policy" 1
done

echo "[firewalld]"
for i in vti1 vti2; do
    z="$(firewall-cmd --get-zone-of-interface="$i" 2>/dev/null || echo none)"
    if [[ "$z" == "aws-vpn" ]]; then ok "$i → aws-vpn"; else ng "$i → $z (기대 aws-vpn)"; fi
done

if [[ "${1:-}" == "--aws" ]]; then
    echo "[AWS 텔레메트리 ($REGION, state=available VPN)]"
    tele="$(aws ec2 describe-vpn-connections --region "$REGION" \
        --filters Name=state,Values=available \
        --query 'VpnConnections[].VgwTelemetry[].Status' --output text 2>/dev/null || true)"
    up="$(tr '\t' '\n' <<< "$tele" | grep -c '^UP$' || true)"
    if [[ "$up" == "2" ]]; then ok "UP 2"; else ng "UP ${up} (조회값: ${tele:-없음}. 반영까지 몇 분 걸릴 수 있음)"; fi
fi

echo "[참고: 이번 부팅 updown 로그]"
journalctl -b -t neuroplan-vti-updown -o short-precise --no-pager 2>/dev/null | tail -4 | sed 's/^/  /'

echo "== 결과: FAIL ${fail}건"
(( fail == 0 ))
