#!/usr/bin/env bash
# 0929 수동 생성한 RDS GTID PoC 네트워크 리소스 삭제 (작업일지_희재_0929 3장·9장 1단계)
# 실행 위치: Infra VM (AWS CLI), 리전 ap-northeast-2
# 대상: 태그 Project=NeuroPlan, Purpose=rds-gtid-poc 리소스 + DB Subnet Group + DB Parameter Group + Log Group
# 기본은 DRY-RUN(명령만 출력). 실제 삭제: bash cleanup_rds_poc_network_0930.sh --apply
# 전제: 정현 RDS PoC 종료 + PoC RDS 삭제 완료 (RDS가 남아 있으면 중단)
set -euo pipefail
export AWS_DEFAULT_REGION=ap-northeast-2
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
TAGF="Name=tag:Project,Values=NeuroPlan Name=tag:Purpose,Values=rds-gtid-poc"
SUBNET_GROUP=neuroplan-rds-poc-subnet-group
PARAM_GROUP=neuroplan-rds-poc-params   # 정현 수동 생성 (PoC RDS 삭제 후 정리)
LOG_GROUP=/neuroplan/vpn

run() { echo "+ $*"; if [ "$APPLY" = 1 ]; then "$@"; fi; }
q()   { aws "$@" --output text; }
need(){ [ -n "$2" ] && [ "$2" != "None" ] || { echo "⚠ $1 없음 (이미 삭제됐거나 태그 불일치) → 건너뜀"; return 1; }; }

echo "== 모드: $([ $APPLY = 1 ] && echo APPLY || echo DRY-RUN) =="
VPC=$(q ec2 describe-vpcs --filters $TAGF --query 'Vpcs[0].VpcId')
VPN=$(q ec2 describe-vpn-connections --filters $TAGF Name=state,Values=available,pending --query 'VpnConnections[0].VpnConnectionId')
VGW=$(q ec2 describe-vpn-gateways --filters $TAGF Name=state,Values=available --query 'VpnGateways[0].VpnGatewayId')
CGW=$(q ec2 describe-customer-gateways --filters $TAGF Name=state,Values=available --query 'CustomerGateways[0].CustomerGatewayId')
echo "VPC=$VPC VPN=$VPN VGW=$VGW CGW=$CGW"

# 0) 사전 확인: VPC 안에 RDS·ENI가 남아 있으면 중단
if need VPC "$VPC"; then
  RDS=$(q rds describe-db-instances --query "DBInstances[?DBSubnetGroup.VpcId=='$VPC'].DBInstanceIdentifier")
  [ -z "$RDS" ] || [ "$RDS" = None ] || { echo "✋ RDS가 남아 있음: $RDS → 정현 PoC 정리 후 다시 실행"; exit 1; }
  ENI=$(q ec2 describe-network-interfaces --filters Name=vpc-id,Values=$VPC --query 'NetworkInterfaces[].NetworkInterfaceId')
  [ -z "$ENI" ] || [ "$ENI" = None ] || { echo "✋ ENI가 남아 있음: $ENI → 확인 후 다시 실행"; exit 1; }
fi

# 1) VPN (유료) → Static Route(등록된 것 전부 조회), Connection 삭제
if need VPN "$VPN"; then
  for c in $(q ec2 describe-vpn-connections --vpn-connection-ids "$VPN" --query 'VpnConnections[0].Routes[].DestinationCidrBlock'); do
    run aws ec2 delete-vpn-connection-route --vpn-connection-id "$VPN" --destination-cidr-block "$c"; done
  run aws ec2 delete-vpn-connection --vpn-connection-id "$VPN"
  [ "$APPLY" = 1 ] && aws ec2 wait vpn-connection-deleted --vpn-connection-ids "$VPN" && echo "VPN 삭제 완료 (과금 종료)"
fi

# 2) VPC 모든 RT에서 VGW로 향하는 경로 삭제(대역 하드코딩 없음) → VGW detach·삭제 → CGW 삭제
ALL_RTB=""; RTB=""
if [ -n "$VPC" ] && [ "$VPC" != None ]; then
  ALL_RTB=$(q ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC --query 'RouteTables[].RouteTableId')
  RTB=$(q ec2 describe-route-tables --filters $TAGF Name=vpc-id,Values=$VPC --query 'RouteTables[].RouteTableId'); fi
if [ -n "$VGW" ] && [ "$VGW" != None ]; then
  for r in $ALL_RTB; do
    for c in $(q ec2 describe-route-tables --route-table-ids "$r" --query "RouteTables[0].Routes[?GatewayId=='$VGW'].DestinationCidrBlock"); do
      run aws ec2 delete-route --route-table-id "$r" --destination-cidr-block "$c"; done
  done
fi
if need VGW "$VGW"; then
  need VPC "$VPC" && run aws ec2 detach-vpn-gateway --vpn-gateway-id "$VGW" --vpc-id "$VPC"
  if [ "$APPLY" = 1 ]; then
    for i in $(seq 1 30); do
      S=$(q ec2 describe-vpn-gateways --vpn-gateway-ids "$VGW" --query 'VpnGateways[0].VpcAttachments[0].State')
      [ "$S" = detached ] || [ "$S" = None ] && break; echo "VGW 분리 대기($S)"; sleep 10
    done
  fi
  run aws ec2 delete-vpn-gateway --vpn-gateway-id "$VGW"
fi
need CGW "$CGW" && run aws ec2 delete-customer-gateway --customer-gateway-id "$CGW"

# 3) DB Subnet Group·Parameter Group → SG → RT → Subnet → VPC
if aws rds describe-db-subnet-groups --db-subnet-group-name "$SUBNET_GROUP" >/dev/null 2>&1; then
  run aws rds delete-db-subnet-group --db-subnet-group-name "$SUBNET_GROUP"; fi
if aws rds describe-db-parameter-groups --db-parameter-group-name "$PARAM_GROUP" >/dev/null 2>&1; then
  run aws rds delete-db-parameter-group --db-parameter-group-name "$PARAM_GROUP"; fi
if need VPC "$VPC"; then
  for sg in $(q ec2 describe-security-groups --filters $TAGF Name=vpc-id,Values=$VPC --query 'SecurityGroups[].GroupId'); do
    run aws ec2 delete-security-group --group-id "$sg"; done
  for r in $RTB; do
    MAIN=$(q ec2 describe-route-tables --route-table-ids "$r" --query 'length(RouteTables[0].Associations[?Main])')
    [ "$MAIN" = 0 ] || { echo "Main RT $r → 삭제하지 않음 (VPC 삭제 시 함께 삭제)"; continue; }
    for a in $(q ec2 describe-route-tables --route-table-ids "$r" --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId'); do
      run aws ec2 disassociate-route-table --association-id "$a"; done
    run aws ec2 delete-route-table --route-table-id "$r"; done
  for s in $(q ec2 describe-subnets --filters Name=vpc-id,Values=$VPC --query 'Subnets[].SubnetId'); do
    run aws ec2 delete-subnet --subnet-id "$s"; done
  run aws ec2 delete-vpc --vpc-id "$VPC"
fi

# 4) Log Group (Terraform이 같은 이름으로 다시 만듦)
if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query 'logGroups[0].logGroupName' --output text | grep -qx "$LOG_GROUP"; then
  run aws logs delete-log-group --log-group-name "$LOG_GROUP"; fi

# 5) 잔존 확인
echo "== 잔존 확인 =="
q ec2 describe-vpn-connections --filters $TAGF Name=state,Values=available,pending --query 'length(VpnConnections)'
q ec2 describe-vpcs --filters $TAGF --query 'length(Vpcs)'
echo "※ 온프렘(Infra VM libreswan, 라우트)은 건드리지 않음 → Terraform apply 후 작업일지 9장 3~6단계"
