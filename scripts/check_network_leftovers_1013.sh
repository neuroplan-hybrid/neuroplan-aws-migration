#!/bin/bash
# check_network_leftovers_1013.sh — destroy 전·후 네트워크 과금 리소스 잔존 확인 (읽기 전용)
#
# 목적: 10/16 destroy 전후로 "무엇이 남아 있고 돈이 나가는지"를 한 화면에 확인 (rosa_p0_execution_1012 "destroy 후 잔존 리소스 확인")
#   - 과금: NLB(ROSA Router·DR), NAT GW, 퍼블릭 IPv4(EIP·ENI), VPN Connection, Route 53 헬스체크
#   - 무료지만 정리 대상 확인: Target Group, SG(neuroplan-*), 남은 ENI, VPC Endpoint
#   - 유지 설계(무료): VPC·서브넷·RT, VGW·CGW (hybrid 모듈: VPN Connection만 ON/OFF)
#   - Infra VM firewalld: rosa-to-maxscale·aws-to-mgmt policy (ROSA 삭제 후 남아 있으면 remove)
# 실행 위치: Infra VM (root, AWS CLI = IAM user heejae), ap-northeast-2
#   bash check_network_leftovers_1013.sh            # 전체 조회
# 변경 명령 없음 (describe/list/firewall-cmd --get-policies만)
set -uo pipefail
R=ap-northeast-2
log()  { printf '%s\n' "$*"; }
sec()  { printf '\n== %s\n' "$*"; }
cnt()  { local n; n="$(grep -cv '^[[:space:]]*$' <<<"$1" || true)"; printf '%s' "${n:-0}"; }

command -v aws >/dev/null || { echo "aws CLI 없음" >&2; exit 1; }
aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 || { echo "AWS 자격 증명 확인 실패" >&2; exit 1; }
log "== 네트워크 잔존 리소스 점검 · $(date '+%F %T') · ${R} (읽기 전용)"

VPC="$(aws ec2 describe-vpcs --region $R --filters Name=tag:Name,Values=neuroplan-vpc --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
[[ "$VPC" == "None" || -z "$VPC" ]] && VPC=""
log "VPC: ${VPC:-없음}"

sec "[과금] Load Balancer (ROSA Router NLB·DR NLB)"
o="$(aws elbv2 describe-load-balancers --region $R --query 'LoadBalancers[].[LoadBalancerName,Type,State.Code]' --output text 2>/dev/null)"
[[ -n "$o" ]] && sed 's/^/  /' <<<"$o"; log "  → $(cnt "$o")개 (ROSA·DR NLB 모두 삭제했다면 0)"

sec "[과금] NAT Gateway (available·pending)"
o="$(aws ec2 describe-nat-gateways --region $R --filter Name=state,Values=available,pending --query 'NatGateways[].[NatGatewayId,State,SubnetId]' --output text 2>/dev/null)"
[[ -n "$o" ]] && sed 's/^/  /' <<<"$o"; log "  → $(cnt "$o")개 (enable_nat=false 이후 0)"

sec "[과금] 퍼블릭 IPv4 — Elastic IP"
o="$(aws ec2 describe-addresses --region $R --query 'Addresses[].[PublicIp,AllocationId,AssociationId||`"미연결"`,Tags[?Key==`"Name"`]|[0].Value]' --output text 2>/dev/null)"
[[ -n "$o" ]] && sed 's/^/  /' <<<"$o"; log "  → $(cnt "$o")개 (미연결 EIP도 과금)"

sec "[과금] 퍼블릭 IPv4 — ENI에 붙은 공인 IP (NLB·NAT 포함)"
if [[ -n "$VPC" ]]; then
    o="$(aws ec2 describe-network-interfaces --region $R --filters Name=vpc-id,Values="$VPC" --query 'NetworkInterfaces[?Association.PublicIp!=`null`].[NetworkInterfaceId,InterfaceType,Association.PublicIp,Description]' --output text 2>/dev/null)"
    [[ -n "$o" ]] && sed 's/^/  /' <<<"$o"; log "  → $(cnt "$o")개"
else log "  VPC 없음 → 건너뜀"; fi

sec "[과금] S2S VPN Connection (deleted 제외)"
o="$(aws ec2 describe-vpn-connections --region $R --filters Name=state,Values=pending,available,deleting --query 'VpnConnections[].[VpnConnectionId,State]' --output text 2>/dev/null)"
[[ -n "$o" ]] && sed 's/^/  /' <<<"$o"; log "  → $(cnt "$o")개 (enable_vpn=false로 끈 뒤 0, 시간당 약 \$0.05)"

sec "[과금] Route 53 헬스체크"
o="$(aws route53 list-health-checks --query 'HealthChecks[].[Id,HealthCheckConfig.FullyQualifiedDomainName,HealthCheckConfig.Type]' --output text 2>/dev/null)"
[[ -n "$o" ]] && sed 's/^/  /' <<<"$o"; log "  → $(cnt "$o")개 (route53_routing_mode=off 이후 0)"

sec "[정리 확인] Target Group"
o="$(aws elbv2 describe-target-groups --region $R --query 'TargetGroups[].[TargetGroupName,Protocol,Port,length(LoadBalancerArns)]' --output text 2>/dev/null)"
[[ -n "$o" ]] && sed 's/^/  /' <<<"$o"; log "  → $(cnt "$o")개 (마지막 숫자 = 연결된 LB 수, 0이면 고아)"

if [[ -n "$VPC" ]]; then
    sec "[정리 확인] Security Group (default 제외)"
    o="$(aws ec2 describe-security-groups --region $R --filters Name=vpc-id,Values="$VPC" --query 'SecurityGroups[?GroupName!=`"default"`].[GroupId,GroupName]' --output text 2>/dev/null)"
    [[ -n "$o" ]] && sed 's/^/  /' <<<"$o"; log "  → $(cnt "$o")개 (neuroplan-rds-sg는 network 모듈 유지 설계, 나머지는 해당 기능 OFF 후 0)"

    sec "[정리 확인] ENI (VPC 안, 상태별)"
    o="$(aws ec2 describe-network-interfaces --region $R --filters Name=vpc-id,Values="$VPC" --query 'NetworkInterfaces[].[Status,InterfaceType,Description]' --output text 2>/dev/null)"
    [[ -n "$o" ]] && awk -F'\t' '{k=$1" / "$2; n[k]++} END{for (k in n) printf "  %-40s %d\n", k, n[k]}' <<<"$o"
    log "  → 전체 $(cnt "$o")개 (ROSA·NAT·NLB·RDS·AMG 삭제 후 남는 ENI가 있으면 Description 확인)"

    sec "[무료·유지 설계] VPC Endpoint·VGW·CGW"
    aws ec2 describe-vpc-endpoints --region $R --filters Name=vpc-id,Values="$VPC" --query 'VpcEndpoints[].[VpcEndpointId,VpcEndpointType,ServiceName,State]' --output text 2>/dev/null | sed 's/^/  /'
fi
aws ec2 describe-vpn-gateways --region $R --filters Name=state,Values=available --query 'VpnGateways[].[VpnGatewayId,State]' --output text 2>/dev/null | sed 's/^/  VGW /'
aws ec2 describe-customer-gateways --region $R --filters Name=state,Values=available --query 'CustomerGateways[].[CustomerGatewayId,State]' --output text 2>/dev/null | sed 's/^/  CGW /'
log "  (Gateway Endpoint·VGW·CGW는 시간 요금 없음)"

sec "[온프렘] Infra VM firewalld 정책 (ROSA 삭제 후 정리 대상)"
if command -v firewall-cmd >/dev/null 2>&1; then
    pols=" $(firewall-cmd --permanent --get-policies 2>/dev/null) "
    for p in rosa-to-maxscale aws-to-mgmt; do
        if [[ "$pols" == *" $p "* ]]; then log "  $p : 있음 → ROSA·AMG 미사용이면 해당 스크립트 remove --apply"
        else log "  $p : 없음"; fi
    done
    for p in aws-to-dmz aws-to-data data-to-aws; do
        if [[ "$pols" == *" $p "* ]]; then log "  $p : 있음 (DR NLB·복제 경로, VPN 유지 동안 유지)"
        else log "  $p : 없음"; fi
    done
else
    log "  firewall-cmd 없음 → Infra VM에서 실행"
fi
log ""
log "== 끝 (변경 없음). 과금 항목 개수가 의도와 다르면 Terraform state 확인 후 Terraform으로만 정리 (콘솔 삭제 금지)"
