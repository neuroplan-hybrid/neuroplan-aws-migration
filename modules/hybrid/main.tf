# hybrid — S2S VPN, CGW/VGW (온프렘 libreswan 연동)
# 담당: 희재
# 수동 작업(작업일지_희재_0929 4.1 2~3번)과 1:1 대응
# - 항상 유지(무료): VGW + VPC attach, CGW, Log Group, 각 RT의 온프렘 대역 → VGW 경로
# - enable_vpn으로 ON/OFF(유료): VPN Connection, VPN Static Route

resource "aws_vpn_gateway" "main" {
  vpc_id = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.project_name}-vgw"
  })
}

resource "aws_customer_gateway" "onprem" {
  bgp_asn    = var.cgw_bgp_asn
  ip_address = var.cgw_ip_address
  type       = "ipsec.1"

  tags = merge(var.tags, {
    Name = "${var.project_name}-cgw"
  })
}

resource "aws_cloudwatch_log_group" "vpn" {
  name              = "/${var.project_name}/vpn"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# ---------- VPN Connection (유료, enable_vpn) ----------

resource "aws_vpn_connection" "main" {
  count = var.enable_vpn ? 1 : 0

  customer_gateway_id = aws_customer_gateway.onprem.id
  vpn_gateway_id      = aws_vpn_gateway.main.id
  type                = "ipsec.1"
  static_routes_only  = true

  tunnel1_inside_cidr   = var.tunnel1_inside_cidr
  tunnel2_inside_cidr   = var.tunnel2_inside_cidr
  tunnel1_preshared_key = var.tunnel1_preshared_key
  tunnel2_preshared_key = var.tunnel2_preshared_key
  tunnel1_ike_versions  = ["ikev2"]
  tunnel2_ike_versions  = ["ikev2"]

  # 수동 작업 5.1(Log ARN=None) 재발 방지: ARN을 리소스 참조로 넘김
  tunnel1_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.vpn.arn
      log_output_format = "json"
    }
  }

  tunnel2_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.vpn.arn
      log_output_format = "json"
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpn"
  })
}

resource "aws_vpn_connection_route" "onprem" {
  for_each = var.enable_vpn ? toset(var.onprem_cidrs) : toset([])

  vpn_connection_id      = aws_vpn_connection.main[0].id
  destination_cidr_block = each.value
}

# ---------- 라우팅 테이블 → VGW (무료, 항상 유지) ----------

locals {
  # 키 예: "db:192.168.44.0/24"
  vgw_routes = {
    for pair in setproduct(keys(var.route_table_ids), var.onprem_cidrs) :
    "${pair[0]}:${pair[1]}" => {
      route_table_id = var.route_table_ids[pair[0]]
      cidr           = pair[1]
    }
  }
}

resource "aws_route" "to_onprem" {
  for_each = local.vgw_routes

  route_table_id         = each.value.route_table_id
  destination_cidr_block = each.value.cidr
  gateway_id             = aws_vpn_gateway.main.id
}
