# Managed Grafana(AMG) 네트워크 (#98) — 담당: 희재 (데이터 소스·대시보드·Monitoring VM 방화벽은 정현)
# 경로: AMG ENI(Private ROSA 서브넷) → VGW → S2S VPN → Infra VM(aws-vpn → nw-mgmt, policy aws-to-mgmt) → Monitoring VM 192.168.14.73:9090
# 범위 제한: Mgmt 대역 전체가 아니라 Monitoring VM /32·TCP 9090만 (정현 #98 합의)
# Thanos Querier·CloudWatch는 기존 NAT(ROSA RT 0.0.0.0/0)로 443 → 이 SG egress 443
# 새 NAT·Endpoint·VPN 없음. VPN 정적 경로·RT 경로는 무료

locals {
  amg_prometheus_cidr = "192.168.14.73/32"
  amg_prometheus_port = 9090

  # modules/hybrid onprem_cidrs 기본값과 같은 2개 + (켜면) Monitoring VM /32
  # for_each 키가 CIDR 값이라 기존 경로는 교체되지 않고 /32 관련 경로만 추가·삭제됨
  hybrid_onprem_cidrs = concat(
    ["192.168.24.0/24", "192.168.44.0/24"],
    var.enable_amg_onprem_prometheus ? [local.amg_prometheus_cidr] : []
  )
}

resource "aws_security_group" "amg" {
  count = var.enable_amg_onprem_prometheus ? 1 : 0

  name        = "neuroplan-amg-sg"
  description = "Managed Grafana VPC connection - onprem Prometheus 9090, Thanos/CloudWatch 443"
  vpc_id      = module.network.vpc_id

  tags = {
    Name  = "neuroplan-amg-sg"
    Owner = "heejae"
  }
}

# Ingress 없음 (AMG ENI는 나가는 연결만 사용, 응답은 SG stateful)

resource "aws_vpc_security_group_egress_rule" "amg_prometheus" {
  count = var.enable_amg_onprem_prometheus ? 1 : 0

  security_group_id = aws_security_group.amg[0].id
  description       = "Onprem Prometheus (Monitoring VM) via VPN"
  ip_protocol       = "tcp"
  from_port         = local.amg_prometheus_port
  to_port           = local.amg_prometheus_port
  cidr_ipv4         = local.amg_prometheus_cidr
}

resource "aws_vpc_security_group_egress_rule" "amg_https" {
  count = var.enable_amg_onprem_prometheus ? 1 : 0

  security_group_id = aws_security_group.amg[0].id
  description       = "ROSA Thanos Querier Route and CloudWatch API via NAT"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
