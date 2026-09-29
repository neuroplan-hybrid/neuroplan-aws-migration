# hybrid 입력 변수
# 설계: VGW·CGW·Log Group·VGW 경로는 무료라 항상 유지하고,
#       시간당 과금되는 VPN Connection만 enable_vpn으로 켜고 끈다.
#       터널 Inside CIDR과 PSK를 고정하면 다시 만들어도 libreswan 설정은 right(Outside IP)만 바뀐다.

variable "project_name" {
  description = "리소스 Name 태그 접두사"
  type        = string
  default     = "neuroplan"
}

variable "vpc_id" {
  description = "VGW를 붙일 VPC (network.vpc_id)"
  type        = string
}

variable "route_table_ids" {
  description = "온프렘 대역 → VGW 경로를 넣을 라우팅 테이블 (network.route_table_ids)"
  type        = map(string)
}

variable "enable_vpn" {
  description = "VPN Connection 생성 여부 (약 $0.05/h). false여도 VGW·CGW·경로는 유지"
  type        = bool
  default     = true
}

variable "cgw_ip_address" {
  description = "온프렘 CGW 공인 IP (학원 회선)"
  type        = string
  default     = "121.160.42.93"
}

variable "cgw_bgp_asn" {
  description = "CGW ASN (Static 라우팅이라 BGP는 쓰지 않지만 필수값)"
  type        = string
  default     = "65000"
}

variable "onprem_cidrs" {
  description = "VPN으로 보낼 온프렘 대역 (DMZ = 서비스 DR, Data = DB 복제)"
  type        = list(string)
  default     = ["192.168.24.0/24", "192.168.44.0/24"]
}

variable "tunnel1_inside_cidr" {
  description = "터널 1 Inside CIDR (/30, 169.254.0.0/16). 고정해야 재생성 후에도 leftvti가 그대로"
  type        = string
  default     = "169.254.189.112/30"
}

variable "tunnel2_inside_cidr" {
  description = "터널 2 Inside CIDR (/30, 169.254.0.0/16)"
  type        = string
  default     = "169.254.90.196/30"
}

variable "tunnel1_preshared_key" {
  description = "터널 1 PSK. null이면 AWS가 생성(재생성할 때마다 바뀜). 값은 코드·tfvars에 쓰지 말고 TF_VAR_로 전달"
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.tunnel1_preshared_key == null || can(regex("^[A-Za-z1-9._][A-Za-z0-9._]{7,63}$", var.tunnel1_preshared_key))
    error_message = "PSK는 8~64자, 영문·숫자·. _ 만 가능하고 0으로 시작할 수 없습니다."
  }
}

variable "tunnel2_preshared_key" {
  description = "터널 2 PSK. null이면 AWS가 생성"
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.tunnel2_preshared_key == null || can(regex("^[A-Za-z1-9._][A-Za-z0-9._]{7,63}$", var.tunnel2_preshared_key))
    error_message = "PSK는 8~64자, 영문·숫자·. _ 만 가능하고 0으로 시작할 수 없습니다."
  }
}

variable "log_retention_days" {
  description = "VPN 터널 로그 보관 일수"
  type        = number
  default     = 7
}

variable "tags" {
  description = "모든 리소스에 추가할 태그"
  type        = map(string)
  default     = {}
}
