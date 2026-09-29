# hybrid 출력값 (온프렘 libreswan 설정용. 다른 Module과는 envs/prod에서만 연결)

output "vpn_gateway_id" {
  description = "VGW ID"
  value       = aws_vpn_gateway.main.id
}

output "customer_gateway_id" {
  description = "CGW ID"
  value       = aws_customer_gateway.onprem.id
}

output "vpn_connection_id" {
  description = "VPN Connection ID (enable_vpn=false면 null)"
  value       = try(aws_vpn_connection.main[0].id, null)
}

output "tunnels" {
  description = "libreswan aws.conf용 터널 정보 (right = outside_ip, leftvti = cgw_inside_ip/30)"
  value = var.enable_vpn ? {
    tunnel1 = {
      outside_ip    = aws_vpn_connection.main[0].tunnel1_address
      cgw_inside_ip = aws_vpn_connection.main[0].tunnel1_cgw_inside_address
      vgw_inside_ip = aws_vpn_connection.main[0].tunnel1_vgw_inside_address
    }
    tunnel2 = {
      outside_ip    = aws_vpn_connection.main[0].tunnel2_address
      cgw_inside_ip = aws_vpn_connection.main[0].tunnel2_cgw_inside_address
      vgw_inside_ip = aws_vpn_connection.main[0].tunnel2_vgw_inside_address
    }
  } : null
}

output "tunnel_preshared_keys" {
  description = "터널 PSK (sensitive). terraform output -json tunnel_preshared_keys 로만 조회, 화면·문서에 남기지 않음"
  value = var.enable_vpn ? {
    tunnel1 = aws_vpn_connection.main[0].tunnel1_preshared_key
    tunnel2 = aws_vpn_connection.main[0].tunnel2_preshared_key
  } : null
  sensitive = true
}
