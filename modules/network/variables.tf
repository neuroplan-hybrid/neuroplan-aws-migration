# network 입력 변수 (주소 계획: 2차 시나리오 4.5)

variable "project_name" {
  description = "리소스 Name 태그 접두사"
  type        = string
  default     = "neuroplan"
}

variable "vpc_cidr" {
  description = "VPC CIDR (ROSA machine_cidr와 같은 값, 온프렘 대역과 겹치지 않아야 함)"
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr는 올바른 CIDR 형식이어야 합니다."
  }
}

variable "public_subnets" {
  description = "Public 서브넷 (NAT, ROSA Ingress NLB, DR NLB). 키 = AZ 접미사"
  type = map(object({
    az   = string
    cidr = string
  }))
  default = {
    "2a" = { az = "ap-northeast-2a", cidr = "10.20.0.0/24" }
    "2b" = { az = "ap-northeast-2b", cidr = "10.20.1.0/24" }
    "2c" = { az = "ap-northeast-2c", cidr = "10.20.2.0/24" }
  }
}

variable "rosa_subnets" {
  description = "Private ROSA 서브넷 (워커 노드). 키 = AZ 접미사"
  type = map(object({
    az   = string
    cidr = string
  }))
  default = {
    "2a" = { az = "ap-northeast-2a", cidr = "10.20.16.0/20" }
    "2b" = { az = "ap-northeast-2b", cidr = "10.20.32.0/20" }
    "2c" = { az = "ap-northeast-2c", cidr = "10.20.48.0/20" }
  }
}

variable "db_subnets" {
  description = "Private DB 서브넷 (RDS DB Subnet Group). 키 = AZ 접미사"
  type = map(object({
    az   = string
    cidr = string
  }))
  default = {
    "2a" = { az = "ap-northeast-2a", cidr = "10.20.100.0/24" }
    "2c" = { az = "ap-northeast-2c", cidr = "10.20.101.0/24" }
  }

  validation {
    condition     = length(distinct([for s in values(var.db_subnets) : s.az])) >= 2
    error_message = "RDS DB Subnet Group은 서로 다른 AZ의 서브넷이 2개 이상 필요합니다."
  }
}

variable "enable_nat" {
  description = "NAT Gateway 생성 여부 (ROSA 워커 인터넷 egress). 비용 발생 → 단계별 tfvars로 전환"
  type        = bool
  default     = false
}

variable "nat_subnet_key" {
  description = "NAT Gateway를 둘 Public 서브넷 키 (NAT 1개 설계)"
  type        = string
  default     = "2a"

  validation {
    condition     = contains(keys(var.public_subnets), var.nat_subnet_key)
    error_message = "nat_subnet_key는 public_subnets의 키 중 하나여야 합니다."
  }
}

variable "db_port" {
  description = "RDS(MariaDB) 포트"
  type        = number
  default     = 3306
}

variable "rds_allow_from_rosa" {
  description = "Private ROSA 서브넷 CIDR → RDS 3306 허용 (ROSA Backend → RDS)"
  type        = bool
  default     = true
}

variable "rds_ingress_cidrs" {
  description = "ROSA 외 추가 허용 대역 (PoC: DevOps VM → RDS, 덤프·복제 설정)"
  type        = list(string)
  default     = ["192.168.44.21/32"]
}

variable "rds_egress_cidrs" {
  description = "RDS에서 나가는 접속 허용 대역 (PoC: RDS → 온프렘 db-primary, GTID 복제)"
  type        = list(string)
  default     = ["192.168.44.51/32"]
}

variable "tags" {
  description = "모든 리소스에 추가할 태그 (Project/Owner/Phase는 envs/prod provider default_tags 권장)"
  type        = map(string)
  default     = {}
}
