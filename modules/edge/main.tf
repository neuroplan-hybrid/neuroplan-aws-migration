# edge — DR NLB(IP target), Route 53 Routing(Weighted / Failover) + Health Check
# 담당: 희재
# - DR 경로: Route 53 → DR NLB(Public 3AZ) → VGW → S2S VPN → Infra VM → VIP 192.168.24.100:443 (2차 시나리오 4.1)
#   · Public RT의 192.168.24.0/24 → VGW 경로는 hybrid 모듈(onprem_cidrs)이 관리
#   · 온프렘 허용: Infra policy aws-to-dmz (Public 서브넷 /24 3개 → 24.100:443, PR #25)
# - ROSA Ingress LB는 ROSA가 생성·관리 → 이 모듈은 DNS 이름만 입력받아 Alias로 가리킴 (생성·수정 안 함)
# - Hosted Zone은 bootstrap/dns 소관 → zone ID·도메인은 입력값 (모듈 안에서 조회하지 않음)
# - 운영 단계도 Weighted 유지(ROSA 1 / 온프렘 0, B안) → 정책 전환 없음 (README 라우팅 단계)
#   · failover는 모듈 호환용. Route 53은 같은 이름에 Weighted와 Failover를 함께 둘 수 없어 쓰려면 "none"을 거쳐야 함

locals {
  domain = var.domain_name == null ? null : trimsuffix(lower(var.domain_name), ".")

  create_dr_nlb      = var.enable_dr_nlb
  create_dr_dns      = var.enable_route53_routing && var.enable_dr_nlb
  create_primary_dns = var.enable_route53_routing && var.primary_lb_dns_name != null

  app_fqdn            = var.enable_route53_routing ? "${var.app_record_name}.${local.domain}" : null
  primary_health_fqdn = var.enable_route53_routing ? "${var.primary_health_record_name}.${local.domain}" : null
  dr_health_fqdn      = var.enable_route53_routing ? "${var.dr_health_record_name}.${local.domain}" : null

  # ROSA Ingress LB의 Alias Hosted Zone ID: 입력이 없으면 리전의 NLB 고정값
  primary_lb_zone_id = coalesce(var.primary_lb_zone_id, data.aws_lb_hosted_zone_id.nlb.id)

  # app 레코드 대상. 없는 사이트는 enabled = false로 걸러냄
  # (조건식 `a ? {...} : {}`는 객체 타입 불일치 오류가 나므로 for 필터 사용)
  app_site_candidates = {
    rosa = {
      enabled         = local.create_primary_dns
      alias_name      = var.primary_lb_dns_name
      alias_zone_id   = local.primary_lb_zone_id
      health_check_id = try(aws_route53_health_check.primary[0].id, null)
      weight          = var.rosa_weight
      failover        = "PRIMARY"
    }
    onprem = {
      enabled         = local.create_dr_dns
      alias_name      = try(aws_lb.dr[0].dns_name, null)
      alias_zone_id   = try(aws_lb.dr[0].zone_id, null)
      health_check_id = try(aws_route53_health_check.dr[0].id, null)
      weight          = var.onprem_weight
      failover        = "SECONDARY"
    }
  }
  app_sites = { for k, v in local.app_site_candidates : k => v if v.enabled }
}

# 리전별 NLB Alias Hosted Zone ID (API 호출 없음, 리전 고정값)
data "aws_lb_hosted_zone_id" "nlb" {
  load_balancer_type = "network"
}

# ---------- DR NLB (IP target → 온프렘 VIP, VPN 경유) ----------

resource "aws_security_group" "dr_nlb" {
  count = local.create_dr_nlb ? 1 : 0

  name        = "${var.project_name}-dr-nlb-sg"
  description = "DR NLB - HTTPS from internet, TCP to on-prem VIP via VPN"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.project_name}-dr-nlb-sg"
  })
}

# 인바운드: 사용자 + Route 53 헬스체커 (둘 다 인터넷 출발)
resource "aws_vpc_security_group_ingress_rule" "dr_nlb" {
  for_each = local.create_dr_nlb ? toset(var.dr_nlb_ingress_cidrs) : toset([])

  security_group_id = aws_security_group.dr_nlb[0].id
  description       = "HTTPS from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = var.dr_listener_port
  to_port           = var.dr_listener_port
  ip_protocol       = "tcp"
}

# 아웃바운드: 온프렘 VIP 한 곳만 (트래픽 + NLB 타깃 헬스체크)
resource "aws_vpc_security_group_egress_rule" "dr_nlb_to_onprem" {
  count = local.create_dr_nlb ? 1 : 0

  security_group_id = aws_security_group.dr_nlb[0].id
  description       = "TCP to on-prem VIP ${var.dr_target_ip} via VPN"
  cidr_ipv4         = "${var.dr_target_ip}/32"
  from_port         = var.dr_target_port
  to_port           = var.dr_target_port
  ip_protocol       = "tcp"
}

resource "aws_lb" "dr" {
  count = local.create_dr_nlb ? 1 : 0

  name               = "${var.project_name}-dr-nlb"
  load_balancer_type = "network"
  internal           = false
  ip_address_type    = "ipv4"
  subnets            = var.public_subnet_ids

  # NLB SG는 생성 시에만 붙일 수 있음 (나중에 추가 불가) → 처음부터 연결
  security_groups = [aws_security_group.dr_nlb[0].id]

  enable_deletion_protection = false # destroy는 Terraform으로 (시나리오 10.3)

  tags = merge(var.tags, {
    Name = "${var.project_name}-dr-nlb"
    Role = "dr-entry"
  })
}

# TLS는 온프렘 NGF가 종료 (NLB·HAProxy 모두 TCP 패스스루, 시나리오 4.9)
# 타깃 헬스체크는 TCP만 — NLB HTTPS 헬스체크는 Host/SNI를 지정할 수 없음 (시나리오 4.8)
resource "aws_lb_target_group" "dr" {
  count = local.create_dr_nlb ? 1 : 0

  name        = "${var.project_name}-dr-tg"
  port        = var.dr_target_port
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  # VPC 밖(VPN 너머) IP 타깃은 Client IP 보존 불가 → 명시적으로 끔 (출발지 = NLB 사설 IP, 온프렘 aws-to-dmz 허용 대역)
  preserve_client_ip   = false
  deregistration_delay = var.dr_deregistration_delay

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = var.dr_tg_health_check_interval
    healthy_threshold   = var.dr_tg_healthy_threshold
    unhealthy_threshold = var.dr_tg_unhealthy_threshold
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-dr-tg"
  })
}

# VPC 밖 IP 타깃은 availability_zone = "all" 필수
resource "aws_lb_target_group_attachment" "dr_onprem_vip" {
  count = local.create_dr_nlb ? 1 : 0

  target_group_arn  = aws_lb_target_group.dr[0].arn
  target_id         = var.dr_target_ip
  port              = var.dr_target_port
  availability_zone = "all"
}

resource "aws_lb_listener" "dr" {
  count = local.create_dr_nlb ? 1 : 0

  load_balancer_arn = aws_lb.dr[0].arn
  port              = var.dr_listener_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dr[0].arn
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-dr-listener"
  })
}

# ---------- Route 53 Health Check (HTTPS + FQDN + SNI, /health/ready) ----------
# 헬스체크 대상 이름은 app 레코드와 분리 (primary-health / dr-health, 시나리오 4.8)
# Route 53은 인증서를 검증하지 않음 → 인증서 발급 전에도 동작. 단 Host 라우팅 대상(ROSA Route, NGF HTTPRoute)은 필요

resource "aws_route53_health_check" "primary" {
  count = local.create_primary_dns ? 1 : 0

  type              = "HTTPS"
  fqdn              = local.primary_health_fqdn
  port              = 443
  resource_path     = var.health_check_path
  enable_sni        = true
  request_interval  = var.health_check_request_interval
  failure_threshold = var.health_check_failure_threshold
  regions           = var.health_check_regions

  tags = merge(var.tags, {
    Name = "${var.project_name}-primary-health"
    Site = "rosa"
  })
}

resource "aws_route53_health_check" "dr" {
  count = local.create_dr_dns ? 1 : 0

  type              = "HTTPS"
  fqdn              = local.dr_health_fqdn
  port              = 443
  resource_path     = var.health_check_path
  enable_sni        = true
  request_interval  = var.health_check_request_interval
  failure_threshold = var.health_check_failure_threshold
  regions           = var.health_check_regions

  tags = merge(var.tags, {
    Name = "${var.project_name}-dr-health"
    Site = "onprem"
  })
}

# ---------- Route 53 레코드: 헬스체크 대상 이름 (Simple Alias) ----------

resource "aws_route53_record" "primary_health" {
  count = local.create_primary_dns ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = local.primary_health_fqdn
  type    = "A"

  alias {
    name                   = var.primary_lb_dns_name
    zone_id                = local.primary_lb_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "dr_health" {
  count = local.create_dr_dns ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = local.dr_health_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.dr[0].dns_name
    zone_id                = aws_lb.dr[0].zone_id
    evaluate_target_health = false
  }
}

# ---------- Route 53 레코드: app (GSLB) ----------
# Weighted(이관·운영, B안)와 Failover(모듈 호환용)는 리소스를 분리 → plan에서 어느 정책인지 바로 보임
# Alias 레코드라 TTL 없음 (ELB Alias 60초)

resource "aws_route53_record" "app_weighted" {
  for_each = { for k, v in local.app_sites : k => v if var.app_routing_policy == "weighted" }

  zone_id         = var.hosted_zone_id
  name            = local.app_fqdn
  type            = "A"
  set_identifier  = each.key
  health_check_id = each.value.health_check_id

  weighted_routing_policy {
    weight = each.value.weight
  }

  alias {
    name                   = each.value.alias_name
    zone_id                = each.value.alias_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "app_failover" {
  for_each = { for k, v in local.app_sites : k => v if var.app_routing_policy == "failover" }

  zone_id         = var.hosted_zone_id
  name            = local.app_fqdn
  type            = "A"
  set_identifier  = each.key
  health_check_id = each.value.health_check_id

  failover_routing_policy {
    type = each.value.failover
  }

  alias {
    name                   = each.value.alias_name
    zone_id                = each.value.alias_zone_id
    evaluate_target_health = true
  }
}
