# edge 입력 변수 (설계: 2차 시나리오 4.1·4.7·4.8, 결정: docs/decisions/mentoring-feedback_0930.md B)

variable "project_name" {
  description = "리소스 Name 태그·이름 접두사"
  type        = string
  default     = "neuroplan"
}

variable "tags" {
  description = "모든 리소스에 추가할 태그 (Project/ManagedBy는 envs/prod provider default_tags)"
  type        = map(string)
  default     = {}
}

# ---------- 기능 스위치 (envs/prod 단계별 tfvars와 연결) ----------

variable "enable_dr_nlb" {
  description = "DR NLB(SG, Target Group, Listener) 생성. 도메인이 없어도 생성 가능"
  type        = bool
  default     = true
}

variable "enable_route53_routing" {
  description = "Route 53 헬스체크·레코드 생성. true면 domain_name, hosted_zone_id 필수"
  type        = bool
  default     = false
}

# ---------- DR NLB ----------

variable "vpc_id" {
  description = "VPC ID (network.vpc_id)"
  type        = string
}

variable "public_subnet_ids" {
  description = "DR NLB를 둘 Public 서브넷 ID (network.public_subnet_ids). 온프렘 aws-to-dmz 허용 출발지와 같은 서브넷이어야 함"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "public_subnet_ids는 2개 이상(서로 다른 AZ)이어야 합니다."
  }
}

variable "dr_target_ip" {
  description = "온프렘 서비스 VIP (HAProxy + Keepalived, DMZ). VPN 너머 IP 타깃"
  type        = string
  default     = "192.168.24.100"

  validation {
    condition     = can(cidrhost("${var.dr_target_ip}/32", 0))
    error_message = "dr_target_ip는 IPv4 주소여야 합니다."
  }
}

variable "dr_target_port" {
  description = "온프렘 VIP 포트 (TCP 패스스루, TLS는 NGF 종료)"
  type        = number
  default     = 443
}

variable "dr_listener_port" {
  description = "DR NLB 리스너 포트"
  type        = number
  default     = 443
}

variable "dr_nlb_ingress_cidrs" {
  description = "DR NLB SG 인바운드 허용 대역 (사용자 + Route 53 헬스체커)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "dr_deregistration_delay" {
  description = "타깃 해제 대기(초). 기본 300 → DR 전환·정리 시간 단축"
  type        = number
  default     = 30
}

variable "dr_tg_health_check_interval" {
  description = "NLB 타깃 헬스체크 간격(초, TCP)"
  type        = number
  default     = 10
}

variable "dr_tg_healthy_threshold" {
  description = "NLB 타깃 healthy 판정 연속 성공 횟수"
  type        = number
  default     = 3
}

variable "dr_tg_unhealthy_threshold" {
  description = "NLB 타깃 unhealthy 판정 연속 실패 횟수"
  type        = number
  default     = 3
}

# ---------- Route 53 ----------

variable "domain_name" {
  description = "공인 도메인 (예: example.com). 도메인 확정 전에는 null"
  type        = string
  default     = null

  validation {
    condition     = !var.enable_route53_routing || try(trimspace(var.domain_name) != "" && trimspace(var.domain_name) == var.domain_name, false)
    error_message = "enable_route53_routing = true면 domain_name이 필요합니다 (null·빈 문자열·앞뒤 공백 불가)."
  }
}

variable "hosted_zone_id" {
  description = "domain_name의 Public Hosted Zone ID (bootstrap/dns)"
  type        = string
  default     = null

  validation {
    condition     = !var.enable_route53_routing || try(trimspace(var.hosted_zone_id) != "" && trimspace(var.hosted_zone_id) == var.hosted_zone_id, false)
    error_message = "enable_route53_routing = true면 hosted_zone_id가 필요합니다 (null·빈 문자열·앞뒤 공백 불가)."
  }
}

variable "app_record_name" {
  description = "서비스 레코드 이름 (GSLB 대상)"
  type        = string
  default     = "app"
}

variable "primary_health_record_name" {
  description = "ROSA 쪽 헬스체크 대상 이름 (ROSA Route host와 같아야 함)"
  type        = string
  default     = "primary-health"
}

variable "dr_health_record_name" {
  description = "온프렘 쪽 헬스체크 대상 이름 (온프렘 NGF HTTPRoute hostname과 같아야 함)"
  type        = string
  default     = "dr-health"
}

variable "primary_lb_dns_name" {
  description = "ROSA Ingress LB DNS 이름 (ROSA가 생성). null이면 ROSA 쪽 헬스체크·레코드를 만들지 않음"
  type        = string
  default     = null

  validation {
    condition     = var.primary_lb_dns_name == null || try(trimspace(var.primary_lb_dns_name) != "" && trimspace(var.primary_lb_dns_name) == var.primary_lb_dns_name, false)
    error_message = "primary_lb_dns_name은 null 또는 앞뒤 공백 없는 비어 있지 않은 값이어야 합니다."
  }
}

variable "primary_lb_zone_id" {
  description = "ROSA Ingress LB의 Alias Hosted Zone ID. null이면 리전 NLB 값 (LB 종류가 NLB가 아니면 지정)"
  type        = string
  default     = null

  validation {
    condition     = var.primary_lb_zone_id == null || try(trimspace(var.primary_lb_zone_id) != "" && trimspace(var.primary_lb_zone_id) == var.primary_lb_zone_id, false)
    error_message = "primary_lb_zone_id는 null 또는 앞뒤 공백 없는 비어 있지 않은 값이어야 합니다."
  }
}

variable "app_routing_policy" {
  description = "app 레코드 정책: weighted(이관·운영, B안) / failover(모듈 호환용, 사용 계획 없음) / none(레코드 없음)"
  type        = string
  default     = "weighted"

  validation {
    condition     = contains(["weighted", "failover", "none"], var.app_routing_policy)
    error_message = "app_routing_policy는 weighted, failover, none 중 하나여야 합니다."
  }

  validation {
    condition = (
      !var.enable_route53_routing || var.app_routing_policy != "failover" ||
      (var.primary_lb_dns_name != null && var.enable_dr_nlb)
    )
    error_message = "failover는 Primary(ROSA LB, primary_lb_dns_name)와 Secondary(DR NLB, enable_dr_nlb)가 모두 있어야 합니다."
  }
}

variable "rosa_weight" {
  description = "Weighted: ROSA 가중치 (0~255). 전환 검증 0 → 10 → 50, 운영 1"
  type        = number
  default     = 0

  validation {
    condition     = var.rosa_weight >= 0 && var.rosa_weight <= 255 && floor(var.rosa_weight) == var.rosa_weight
    error_message = "rosa_weight는 0~255 정수여야 합니다."
  }
}

variable "onprem_weight" {
  description = "Weighted: 온프렘(DR NLB) 가중치 (0~255). 전환 검증 100 → 90 → 50, 운영 0 (ROSA 레코드가 모두 unhealthy일 때만 응답)"
  type        = number
  default     = 100

  validation {
    condition     = var.onprem_weight >= 0 && var.onprem_weight <= 255 && floor(var.onprem_weight) == var.onprem_weight
    error_message = "onprem_weight는 0~255 정수여야 합니다."
  }
}

variable "health_check_path" {
  description = "Route 53 헬스체크 경로. Spring Boot routing health group(livenessState, deploymentSafety, DB 제외) — DB 장애만으로 DR 전환하지 않음 (#34)"
  type        = string
  default     = "/actuator/health/routing"
}

variable "health_check_request_interval" {
  description = "Route 53 헬스체크 간격(초): 10(fast) 또는 30. 생성 후 변경 시 재생성"
  type        = number
  default     = 10

  validation {
    condition     = contains([10, 30], var.health_check_request_interval)
    error_message = "health_check_request_interval은 10 또는 30이어야 합니다."
  }
}

variable "health_check_failure_threshold" {
  description = "Route 53 헬스체크 실패 판정 연속 횟수 (Control RTO ≈ 간격 × 횟수)"
  type        = number
  default     = 3
}

variable "health_check_regions" {
  description = "헬스체커 리전 (Route 53 헬스체커 리전 중 서로 다른 3개 이상, 서울 ap-northeast-2는 없음). null이면 Route 53 기본값(전체 8개)"
  type        = list(string)
  default     = null

  validation {
    condition     = var.health_check_regions == null || try(length(distinct(var.health_check_regions)) >= 3, false)
    error_message = "health_check_regions는 null 또는 서로 다른 리전 3개 이상이어야 합니다 (Route 53 최소 3개)."
  }

  # Route 53 API HealthCheckConfig.Regions 허용값 — 빈 문자열·공백·오타도 여기서 중단
  validation {
    condition = var.health_check_regions == null || try(alltrue([
      for r in var.health_check_regions : contains([
        "us-east-1", "us-west-1", "us-west-2", "eu-west-1",
        "ap-southeast-1", "ap-southeast-2", "ap-northeast-1", "sa-east-1",
      ], r)
    ]), false)
    error_message = "health_check_regions 값은 us-east-1, us-west-1, us-west-2, eu-west-1, ap-southeast-1, ap-southeast-2, ap-northeast-1, sa-east-1 중에서만 고를 수 있습니다."
  }
}
