#!/bin/bash
# check_morning_1006.sh — 10/12 아침 점검 (ROSA apply 전, 온프렘 3일 OFF 뒤 부팅 확인) — 읽기 전용 (작업일지 1006 1장 5번)
#
# 실행 위치: Infra VM (root). 같은 디렉터리에 check_vpn_state_0930.sh, check_dmz_state_0930.sh가 있으면 함께 실행
#   bash check_morning_1006.sh            # 화면 출력 + ~/check_morning_<MMDD-HHMM>.log 저장
# 점검 (위에서부터, 하나라도 FAIL이면 종료 코드 1 → 예린 rosa-on apply 전에 해결)
#   0. 부팅 시각·시간 동기화(chrony) — IPsec·TLS는 시계가 틀리면 실패
#   1. VPN: check_vpn_state_0930.sh --aws <자동 조회한 vpn-id> (터널 2개, vti 라우트, sysctl, AWS 텔레메트리)
#   2. DMZ: check_dmz_state_0930.sh (DMZ NIC, nw-dmz, aws-to-dmz, VIP 443)
#   3. DR NLB Target(neuroplan-dr-tg) healthy
#   4. DNS 위임: 공용 Resolver의 NS 4개 = Hosted Zone NS 4개
#   5. dr-health: Infra → VIP(SNI)와 인터넷 → DR NLB 두 경로 응답 코드(200 또는 404, 000이면 FAIL), 인증서 발급자·남은 일수
#   6. 정보: certbot 임시 Role 존재 여부(정리 대상), Infra VM 인증서 사본 존재 여부
# 하지 않는 일: 설정 변경, Terraform, ROSA 관련 확인(예린)
# 주의: 조건문에 "명령 | grep -q"를 쓰지 않는다 (pipefail 거짓 FAIL, 작업일지 0930 3.9). 네트워크 명령은 모두 타임아웃
set -uo pipefail

REGION="ap-northeast-2"
TG="neuroplan-dr-tg"
NLB="neuroplan-dr-nlb"
ZONE_ID="Z021384539IIHK7FGMEMN"
DOMAIN="neuroplan.cloud"
DR_HOST="dr-health.${DOMAIN}"
HC_PATH="/actuator/health/routing"
VIP="192.168.24.100"
ROLE="neuroplan-certbot-dns01"
CERT_DIR="/root/certbot-neuroplan/prod/config/live"
MIN_CERT_DAYS=14
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/check_morning_$(date +%m%d-%H%M).log"

fail=0; warn=0
ok()   { printf '  [OK]   %s\n' "$1"; }
ng()   { printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1)); }
wn()   { printf '  [WARN] %s\n' "$1"; warn=$((warn + 1)); }
info() { printf '  [INFO] %s\n' "$1"; }
hdr()  { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$1"; }

main() {
    echo "=== 10/12 아침 점검 $(date '+%F %T') ($(hostname -s)) ==="
    [[ $EUID -eq 0 ]] || { echo "root로 실행"; exit 1; }

    hdr "0. 부팅·시간"
    info "부팅: $(uptime -s 2>/dev/null) ($(uptime -p 2>/dev/null))"
    local sync
    sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '?')"
    if [[ "$sync" == "yes" ]]; then ok "시간 동기화 (NTPSynchronized=yes)"; else ng "시간 동기화 안 됨 (${sync}) → chronyc sources 확인"; fi

    hdr "1. VPN (check_vpn_state_0930.sh)"
    local vpn_ids n
    vpn_ids="$(timeout 20 aws ec2 describe-vpn-connections --region "$REGION" \
        --filters Name=state,Values=available --query 'VpnConnections[].VpnConnectionId' --output text 2>&1)" || vpn_ids="ERR:${vpn_ids}"
    n="$(wc -w <<<"${vpn_ids/ERR:*/}")"
    if [[ "$vpn_ids" == ERR:* ]]; then ng "VPN 조회 실패: ${vpn_ids#ERR:}"
    elif [[ "$n" -ne 1 ]]; then ng "available VPN Connection ${n}개 (기대 1): ${vpn_ids}"
    else ok "VPN Connection 1개 available"; fi
    if [[ -f "${HERE}/check_vpn_state_0930.sh" ]]; then
        if [[ "$n" -eq 1 ]]; then bash "${HERE}/check_vpn_state_0930.sh" --aws "$vpn_ids"; else bash "${HERE}/check_vpn_state_0930.sh"; fi
        [[ $? -eq 0 ]] && ok "check_vpn_state_0930.sh 전부 OK" || ng "check_vpn_state_0930.sh FAIL 있음 (위 출력)"
    else
        wn "check_vpn_state_0930.sh 없음 (${HERE}) → VPN 상세 점검 생략"
    fi

    hdr "2. DMZ (check_dmz_state_0930.sh)"
    if [[ -f "${HERE}/check_dmz_state_0930.sh" ]]; then
        bash "${HERE}/check_dmz_state_0930.sh"
        [[ $? -eq 0 ]] && ok "check_dmz_state_0930.sh 전부 OK" || ng "check_dmz_state_0930.sh FAIL 있음 (위 출력)"
    else
        wn "check_dmz_state_0930.sh 없음 (${HERE}) → DMZ 상세 점검 생략"
    fi

    hdr "3. DR NLB Target"
    local tg_arn th
    tg_arn="$(timeout 20 aws elbv2 describe-target-groups --region "$REGION" --names "$TG" \
        --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)" || tg_arn=""
    if [[ "$tg_arn" == arn:* ]]; then
        th="$(timeout 20 aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$tg_arn" \
            --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output text 2>&1)" || true
        if [[ "$th" == *"${VIP}"*"healthy"* && "$th" != *unhealthy* ]]; then ok "Target ${th//$'\t'/ }"
        else ng "Target 상태: ${th//$'\t'/ } (부팅 직후면 30초 뒤 재실행)"; fi
    else
        ng "Target Group ${TG} 조회 실패"
    fi

    hdr "4. DNS 위임"
    local zone_ns pub_ns
    zone_ns="$(timeout 20 aws route53 get-hosted-zone --id "$ZONE_ID" --query 'DelegationSet.NameServers' --output text 2>/dev/null \
        | tr '\t' '\n' | sed 's/\.$//' | sort | paste -sd' ')"
    pub_ns="$(timeout 10 dig +short NS "$DOMAIN" @8.8.8.8 2>/dev/null | sed 's/\.$//' | sort | paste -sd' ')"
    if [[ -n "$zone_ns" && "$zone_ns" == "$pub_ns" ]]; then ok "NS 4개 일치 (${pub_ns})"
    else ng "NS 불일치 — Zone: '${zone_ns}' / 8.8.8.8: '${pub_ns}'"; fi

    hdr "5. dr-health (${HC_PATH})"
    local c_vip nlb_dns c_nlb
    c_vip="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 --resolve "${DR_HOST}:443:${VIP}" "https://${DR_HOST}${HC_PATH}" 2>/dev/null)"
    judge_code "Infra → VIP" "$c_vip"
    nlb_dns="$(timeout 20 aws elbv2 describe-load-balancers --region "$REGION" --names "$NLB" \
        --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)" || nlb_dns=""
    if [[ "$nlb_dns" == *.elb.amazonaws.com || "$nlb_dns" == *.amazonaws.com ]]; then
        c_nlb="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --connect-to "${DR_HOST}:443:${nlb_dns}:443" "https://${DR_HOST}${HC_PATH}" 2>/dev/null)"
        if [[ "$c_nlb" == "000" || -z "$c_nlb" ]]; then
            wn "인터넷 → DR NLB: 연결 실패 (000) — Infra VM에서 자기 자신을 거쳐 돌아오는 경로라 실패할 수 있음 → 학원 PC에서 curl.exe --connect-to로 재확인"
        else judge_code "인터넷 → DR NLB → VPN → VIP" "$c_nlb"; fi
    else
        ng "DR NLB DNS 조회 실패"
    fi
    local cert end days
    cert="$(timeout 10 openssl s_client -connect "${VIP}:443" -servername "$DR_HOST" </dev/null 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null)"
    if [[ -n "$cert" ]]; then
        end="$(sed -n 's/^notAfter=//p' <<<"$cert")"
        days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
        if [[ "$cert" == *STAGING* ]]; then ng "인증서가 staging: ${cert//$'\n'/ }"
        elif [[ $days -lt $MIN_CERT_DAYS ]]; then ng "인증서 만료 ${days}일 남음"
        else ok "인증서 $(sed -n 's/^issuer=//p' <<<"$cert" | sed 's/.*CN *= *//'), 남은 ${days}일"; fi
    else
        ng "인증서 조회 실패 (VIP:443 SNI ${DR_HOST})"
    fi

    hdr "6. 정리 대상 (정보)"
    local gr
    gr="$(timeout 20 aws iam get-role --role-name "$ROLE" 2>&1)" || true
    if [[ "$gr" == *NoSuchEntity* ]]; then info "임시 Role ${ROLE}: 정리됨"
    elif [[ "$gr" == *"$ROLE"* ]]; then info "임시 Role ${ROLE}: 남아 있음 (ROSA 인증서 배포 후 setup_certbot_role_1006.sh cleanup)"
    else info "임시 Role 조회 불가: ${gr:0:120}"; fi
    local c
    for c in neuroplan-onprem neuroplan-rosa; do
        if [[ -e "${CERT_DIR}/${c}/privkey.pem" ]]; then info "Infra VM 사본 ${c}: 있음 (Secret 등록·검증 후 deploy_cert_secret_1006.sh purge)"
        else info "Infra VM 사본 ${c}: 없음"; fi
    done

    printf '\n=== 결과: FAIL %d / WARN %d — %s ===\n' "$fail" "$warn" \
        "$([[ $fail -eq 0 ]] && echo '온프렘·VPN·DR 경로 정상 → 예린에게 rosa-on apply 진행 공유' || echo 'FAIL 해결 후 재실행, apply 보류')"
    [[ $fail -eq 0 ]]
}

judge_code() {  # $1 경로 이름, $2 HTTP 코드
    case "$2" in
        200) ok "$1: 200" ;;
        404) wn "$1: 404 (경로·TLS 정상, Backend routing group 미배포면 404 — 배포 후엔 200이어야 함)" ;;
        000|"") ng "$1: 연결 실패 (000)" ;;
        *) ng "$1: $2" ;;
    esac
}

main 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
echo "로그: ${LOG}"
exit "$rc"
