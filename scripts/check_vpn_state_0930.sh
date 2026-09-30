#!/bin/bash
# check_vpn_state_0930.sh — Infra VM VPN 자동 복구 상태 점검 (읽기 전용, 작업일지 0930 9장)
#
# 실행 위치: Infra VM (root). 10/6·10/12 아침 부팅 후, 재부팅 검증 후 사용
#   bash check_vpn_state_0930.sh                  # 온프렘만
#   bash check_vpn_state_0930.sh --aws <vpn-id>   # + 해당 VPN Connection 텔레메트리 (AWS CLI, ap-northeast-2)
#     <vpn-id>: Terraform output vpn_connection_id (예: vpn-0123456789abcdef0)
#     - 텔레메트리 Outside IP 2개가 aws.conf aws-tun1/aws-tun2의 right=와 같은지도 대조
# 종료 코드: 0 = 전부 OK, 1 = FAIL 1개 이상 (preflight에서 그대로 사용)
# 주의: 조건문에 "명령 | grep -q"를 쓰지 않는다. pipefail에서 grep -q가 먼저 끝나면
#       앞 명령이 SIGPIPE(141)로 종료돼 값이 있어도 FAIL로 판정됨 (작업일지 0930 3.9)
#       → 출력을 변수에 담은 뒤 grep -q ... <<< "$변수"
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
# conn 블록 내용 출력: 'conn <이름>' 줄 다음 ~ 다음 섹션(들여쓰기 없는 줄) 직전
conn_block() {
    awk -v c="$1" '
        $0 ~ "^conn[[:space:]]+" c "[[:space:]]*$" { f = 1; next }
        f && /^[^[:space:]#]/ { exit }
        f' "$AWS_CONF" 2>/dev/null
}

AWS_MODE=0
VPN_ID=""
if [[ "${1:-}" == "--aws" ]]; then
    AWS_MODE=1
    VPN_ID="${2:-}"
fi

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
common_blk="$(conn_block aws-common)"
if grep -qE "^\s*leftupdown=${WRAPPER}\s*$" <<< "$common_blk"; then
    ok "conn aws-common leftupdown 설정"
else
    ng "conn aws-common leftupdown 없음"
fi

echo "[터널]"
esp="$(ipsec trafficstatus 2>/dev/null | grep -c 'type=ESP' || true)"
if [[ "$esp" == "2" ]]; then ok "ESP 2개"; else ng "ESP ${esp}개 (기대 2)"; fi

echo "[라우트 $VPC_CIDR]"
routes="$(ip -4 route show "$VPC_CIDR" 2>/dev/null)"
for pair in "vti1 100" "vti2 200"; do
    read -r dev metric <<< "$pair"
    if grep -qE "dev ${dev} .*metric ${metric}\b" <<< "$routes"; then
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

if (( AWS_MODE )); then
    echo "[AWS 텔레메트리 ($REGION, ${VPN_ID:-ID 없음})]"
    if [[ ! "$VPN_ID" =~ ^vpn-[0-9a-f]{8,17}$ ]]; then
        ng "VPN ID 필요: --aws <vpn-id> (Terraform output vpn_connection_id). 입력값: '${VPN_ID}'"
    else
        state="$(aws ec2 describe-vpn-connections --region "$REGION" --vpn-connection-ids "$VPN_ID" \
            --query 'VpnConnections[0].State' --output text 2>/dev/null || echo '조회 실패')"
        if [[ "$state" == "available" ]]; then ok "$VPN_ID available"; else ng "$VPN_ID 상태: $state"; fi

        tele="$(aws ec2 describe-vpn-connections --region "$REGION" --vpn-connection-ids "$VPN_ID" \
            --query 'VpnConnections[0].VgwTelemetry[].[OutsideIpAddress,Status]' --output text 2>/dev/null || true)"
        up="$(awk '$2 == "UP"' <<< "$tele" | grep -c . || true)"
        if [[ "$up" == "2" ]]; then ok "UP 2"; else ng "UP ${up} (반영까지 몇 분 걸릴 수 있음)"; fi

        aws_ips="$(awk 'NF { print $1 }' <<< "$tele" | sort | xargs)"
        conf_ips="$(for c in aws-tun1 aws-tun2; do conn_block "$c" | sed -nE 's/^\s*right=\s*([0-9.]+).*/\1/p'; done | sort | xargs)"
        if [[ -n "$aws_ips" && "$aws_ips" == "$conf_ips" ]]; then
            ok "Outside IP = aws.conf right= (${aws_ips})"
        else
            ng "Outside IP 불일치: AWS [${aws_ips:-없음}] / aws.conf [${conf_ips:-없음}] → 7단계 갱신 필요"
        fi
    fi
fi

echo "[참고: 이번 부팅 updown 로그]"
journalctl -b -t neuroplan-vti-updown -o short-precise --no-pager 2>/dev/null | tail -4 | sed 's/^/  /'

echo "== 결과: FAIL ${fail}건"
(( fail == 0 ))
