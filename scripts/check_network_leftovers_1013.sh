#!/bin/bash
# check_network_leftovers_1013.sh — destroy 전·후 네트워크 과금 리소스 잔존 확인 (읽기 전용)
#
# 목적: 10/16 destroy 전후로 "무엇이 남아 있고 돈이 나가는지"를 한 화면에 확인 (rosa_p0_execution_1012 "destroy 후 잔존 리소스 확인")
#   - 과금: NLB(ROSA Router·DR), NAT GW, 퍼블릭 IPv4(EIP·ENI), VPN Connection, Route 53 헬스체크
#   - 무료지만 정리 대상 확인: Target Group, SG(neuroplan-*), 남은 ENI, VPC Endpoint
#   - 유지 설계(무료): VPC·서브넷·RT, VGW·CGW (hybrid 모듈: VPN Connection만 ON/OFF)
#   - Infra VM firewalld: rosa-to-maxscale·aws-to-mgmt policy (ROSA 삭제 후 남아 있으면 remove)
# 실행 위치: Infra VM (root, AWS CLI = IAM user heejae), ap-northeast-2
#   bash check_network_leftovers_1013.sh                   # 조회만 (destroy 전)
#   bash check_network_leftovers_1013.sh --after-destroy   # destroy 후 증적: 과금 항목이 1개라도 있으면 exit 1
#   KEEP_VPN=1 bash check_network_leftovers_1013.sh --after-destroy   # VPN을 일부러 유지한 경우 VPN은 판정에서 제외
# 변경 명령 없음 (describe/list/firewall-cmd --get-policies만)
#
# 조회 실패 처리 (#107 리뷰): 권한 오류·API 오류·일시 장애는 "0개"로 세지 않고 [UNKNOWN]으로 표시, 오류 첫 줄 출력
# 종료 코드: 0 = 모든 조회 성공 (+ --after-destroy면 과금 항목 0)
#            1 = --after-destroy인데 과금 항목 남음
#            2 = 조회 실패(UNKNOWN) 1건 이상 → 잔존 0 증적으로 사용 금지 (1보다 우선)
set -uo pipefail
R=ap-northeast-2
AFTER=0
case "${1:-}" in
    "") ;;
    --after-destroy) AFTER=1 ;;
    *) echo "사용법: $0 [--after-destroy]" >&2; exit 64 ;;
esac
KEEP_VPN="${KEEP_VPN:-0}"
unk=0; billed=0
log()  { printf '%s\n' "$*"; }
sec()  { printf '\n== %s\n' "$*"; }
cnt()  { local n; n="$(grep -cv '^[[:space:]]*$' <<<"$1" || true)"; printf '%s' "${n:-0}"; }

# q <변수명> <명령...> — 성공하면 출력을 변수에 넣고 0, 실패하면 [UNKNOWN] 출력·unk 증가·1
q() {
    local __var=$1; shift
    local __err __out __rc
    __err="$(mktemp)"
    __out="$("$@" 2>"$__err")"; __rc=$?
    if (( __rc != 0 )); then
        printf '  [UNKNOWN] 조회 실패 (rc=%s): %s\n' "$__rc" "$(grep -m1 -v '^[[:space:]]*$' "$__err" || echo '오류 메시지 없음')"
        unk=$((unk+1)); rm -f "$__err"; printf -v "$__var" '%s' ""; return 1
    fi
    rm -f "$__err"; printf -v "$__var" '%s' "$__out"; return 0
}

# item <과금|정리> <제목> <힌트> <명령...> — 목록·개수 출력, 과금이면 billed에 합산
item() {
    local kind=$1 title=$2 hint=$3 o n; shift 3
    sec "[${kind}] ${title}"
    q o "$@" || { log "  → 개수 알 수 없음 (위 오류 해결 후 재실행)"; return 0; }
    [[ -n "$o" ]] && sed 's/^/  /' <<<"$o"
    n="$(cnt "$o")"; log "  → ${n}개 (${hint})"
    [[ "$kind" == 과금 ]] && billed=$((billed+n))
    return 0
}

command -v aws >/dev/null || { echo "aws CLI 없음" >&2; exit 2; }
q me aws sts get-caller-identity --query Arn --output text || { echo "AWS 자격 증명 확인 실패 → 전체 UNKNOWN" >&2; exit 2; }
log "== 네트워크 잔존 리소스 점검 · $(date '+%F %T') · ${R} (읽기 전용$( ((AFTER)) && printf ', destroy 후 판정'))"

VPC=""; VPC_OK=1
if q VPC aws ec2 describe-vpcs --region $R --filters Name=tag:Name,Values=neuroplan-vpc --query 'Vpcs[0].VpcId' --output text; then
    [[ "$VPC" == "None" ]] && VPC=""
    log "VPC: ${VPC:-없음}"
else
    VPC_OK=0; log "VPC: 알 수 없음 → VPC 기준 항목은 UNKNOWN"
fi

item 과금 "Load Balancer (ROSA Router NLB·DR NLB)" "ROSA·DR NLB 모두 삭제했다면 0" \
    aws elbv2 describe-load-balancers --region $R --query 'LoadBalancers[].[LoadBalancerName,Type,State.Code]' --output text
item 과금 "NAT Gateway (available·pending)" "enable_nat=false 이후 0" \
    aws ec2 describe-nat-gateways --region $R --filter Name=state,Values=available,pending --query 'NatGateways[].[NatGatewayId,State,SubnetId]' --output text
item 과금 "퍼블릭 IPv4 — Elastic IP" "미연결 EIP도 과금" \
    aws ec2 describe-addresses --region $R --query 'Addresses[].[PublicIp,AllocationId,AssociationId||`"미연결"`,Tags[?Key==`"Name"`]|[0].Value]' --output text
if [[ -n "$VPC" ]]; then
    item 과금 "퍼블릭 IPv4 — ENI에 붙은 공인 IP (NLB·NAT 포함, 위 항목과 겹칠 수 있음)" "NLB·NAT 삭제 후 0" \
        aws ec2 describe-network-interfaces --region $R --filters Name=vpc-id,Values="$VPC" --query 'NetworkInterfaces[?Association.PublicIp!=`null`].[NetworkInterfaceId,InterfaceType,Association.PublicIp,Description]' --output text
elif (( VPC_OK )); then sec "[과금] 퍼블릭 IPv4 — ENI"; log "  VPC 없음 → 해당 없음"
else sec "[과금] 퍼블릭 IPv4 — ENI"; log "  [UNKNOWN] VPC 조회 실패로 확인 못 함"; fi

b0=$billed
item 과금 "S2S VPN Connection (deleted 제외)" "enable_vpn=false로 끈 뒤 0, 시간당 약 \$0.05" \
    aws ec2 describe-vpn-connections --region $R --filters Name=state,Values=pending,available,deleting --query 'VpnConnections[].[VpnConnectionId,State]' --output text
if [[ "$KEEP_VPN" == 1 ]] && (( billed > b0 )); then log "  (KEEP_VPN=1 → 판정에서 제외)"; billed=$b0; fi

item 과금 "Route 53 헬스체크" "route53_routing_mode=off 이후 0" \
    aws route53 list-health-checks --query 'HealthChecks[].[Id,HealthCheckConfig.FullyQualifiedDomainName,HealthCheckConfig.Type]' --output text
item 정리 "Target Group" "마지막 숫자 = 연결된 LB 수, 0이면 고아" \
    aws elbv2 describe-target-groups --region $R --query 'TargetGroups[].[TargetGroupName,Protocol,Port,length(LoadBalancerArns)]' --output text

if [[ -n "$VPC" ]]; then
    item 정리 "Security Group (default 제외)" "neuroplan-rds-sg는 network 모듈 유지 설계, 나머지는 해당 기능 OFF 후 0" \
        aws ec2 describe-security-groups --region $R --filters Name=vpc-id,Values="$VPC" --query 'SecurityGroups[?GroupName!=`"default"`].[GroupId,GroupName]' --output text

    sec "[정리] ENI (VPC 안, 상태별)"
    if q o aws ec2 describe-network-interfaces --region $R --filters Name=vpc-id,Values="$VPC" --query 'NetworkInterfaces[].[Status,InterfaceType,Description]' --output text; then
        [[ -n "$o" ]] && awk -F'\t' '{k=$1" / "$2; n[k]++} END{for (k in n) printf "  %-40s %d\n", k, n[k]}' <<<"$o"
        log "  → 전체 $(cnt "$o")개 (ROSA·NAT·NLB·RDS·AMG 삭제 후 남는 ENI가 있으면 Description 확인)"
    fi

    sec "[무료·유지 설계] VPC Endpoint"
    q o aws ec2 describe-vpc-endpoints --region $R --filters Name=vpc-id,Values="$VPC" --query 'VpcEndpoints[].[VpcEndpointId,VpcEndpointType,ServiceName,State]' --output text && { [[ -n "$o" ]] && sed 's/^/  /' <<<"$o"; log "  → $(cnt "$o")개"; }
elif (( ! VPC_OK )); then
    sec "[정리] SG·ENI·VPC Endpoint"; log "  [UNKNOWN] VPC 조회 실패로 확인 못 함"
fi
sec "[무료·유지 설계] VGW·CGW"
q o aws ec2 describe-vpn-gateways --region $R --filters Name=state,Values=available --query 'VpnGateways[].[VpnGatewayId,State]' --output text && { [[ -n "$o" ]] && sed 's/^/  VGW /' <<<"$o"; log "  → VGW $(cnt "$o")개"; }
q o aws ec2 describe-customer-gateways --region $R --filters Name=state,Values=available --query 'CustomerGateways[].[CustomerGatewayId,State]' --output text && { [[ -n "$o" ]] && sed 's/^/  CGW /' <<<"$o"; log "  → CGW $(cnt "$o")개"; }
log "  (Gateway Endpoint·VGW·CGW는 시간 요금 없음)"

sec "[온프렘] Infra VM firewalld 정책 (ROSA 삭제 후 정리 대상)"
if command -v firewall-cmd >/dev/null 2>&1; then
    if q pols firewall-cmd --permanent --get-policies; then
    pols=" ${pols} "
    for p in rosa-to-maxscale aws-to-mgmt; do
        if [[ "$pols" == *" $p "* ]]; then log "  $p : 있음 → ROSA·AMG 미사용이면 해당 스크립트 remove --apply"
        else log "  $p : 없음"; fi
    done
    for p in aws-to-dmz aws-to-data data-to-aws; do
        if [[ "$pols" == *" $p "* ]]; then log "  $p : 있음 (DR NLB·복제 경로, VPN 유지 동안 유지)"
        else log "  $p : 없음"; fi
    done
    fi
else
    log "  [UNKNOWN] firewall-cmd 없음 → Infra VM에서 실행"; unk=$((unk+1))
fi
log ""
log "== 요약: 과금 항목 ${billed}개$( [[ "$KEEP_VPN" == 1 ]] && printf ' (VPN 제외)'), 조회 실패(UNKNOWN) ${unk}건 — 변경 없음"
if (( unk > 0 )); then
    log "== 결과: UNKNOWN — 조회 실패가 있어 잔존 0 증적으로 사용 불가 (권한·네트워크 확인 후 재실행)"; exit 2
fi
if (( AFTER && billed > 0 )); then
    log "== 결과: FAIL — destroy 후 과금 리소스 남음. Terraform state 확인 후 Terraform으로만 정리 (콘솔 삭제 금지)"; exit 1
fi
if (( AFTER )); then log "== 결과: OK — 모든 조회 성공, 과금 항목 0"
else log "== 결과: 조회 완료. 과금 항목 개수가 의도와 다르면 Terraform state 확인 후 Terraform으로만 정리 (콘솔 삭제 금지)"; fi
exit 0
