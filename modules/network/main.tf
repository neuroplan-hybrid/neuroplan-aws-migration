# network — VPC, 3AZ Subnet(Public / Private ROSA / Private DB), IGW, NAT, RT, RDS SG
# 담당: 희재
# - 온프렘 대역 → VGW 경로는 hybrid 모듈에서 추가 (route_table_ids 입력)
# - DB Subnet Group은 data 모듈(정현)에서 db_subnet_ids로 생성 (소속 합의 필요)
# - S3 Gateway Endpoint는 다음 PR

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-igw"
  })
}

# ---------- Public Subnet (NAT, ROSA Ingress NLB, DR NLB) ----------

resource "aws_subnet" "public" {
  for_each = var.public_subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.value.az
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name                     = "${var.project_name}-public-${each.key}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1" # ROSA 인터넷 LB 배치 대상
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ---------- Private ROSA Subnet (워커 노드) ----------

resource "aws_subnet" "rosa" {
  for_each = var.rosa_subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.value.az
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name                              = "${var.project_name}-rosa-${each.key}"
    Tier                              = "rosa"
    "kubernetes.io/role/internal-elb" = "1" # ROSA 내부 LB 배치 대상
  })
}

resource "aws_route_table" "rosa" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-rosa-rt"
  })
}

resource "aws_route_table_association" "rosa" {
  for_each = aws_subnet.rosa

  subnet_id      = each.value.id
  route_table_id = aws_route_table.rosa.id
}

# NAT Gateway 1개 (비용 절감 설계). enable_nat=false면 생성하지 않음
# 한계: 단일 NAT는 SPOF이고 2b/2c 워커의 egress가 AZ를 넘어감 (cross-AZ 데이터 요금).
#       운영 전환 시 AZ별 NAT(3개)로 바꾸면 해소되지만 비용 3배 → 이번 프로젝트는 단일 NAT 유지

resource "aws_eip" "nat" {
  count  = var.enable_nat ? 1 : 0
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.project_name}-nat-eip"
  })
}

resource "aws_nat_gateway" "main" {
  count = var.enable_nat ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[var.nat_subnet_key].id

  tags = merge(var.tags, {
    Name = "${var.project_name}-nat"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route" "rosa_nat" {
  count = var.enable_nat ? 1 : 0

  route_table_id         = aws_route_table.rosa.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

# ---------- Private DB Subnet ----------

resource "aws_subnet" "db" {
  for_each = var.db_subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.value.az
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.project_name}-db-${each.key}"
    Tier = "db"
  })
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-db-rt"
  })
}

resource "aws_route_table_association" "db" {
  for_each = aws_subnet.db

  subnet_id      = each.value.id
  route_table_id = aws_route_table.db.id
}

# ---------- RDS Security Group ----------
# 역할 경계: RDS SG와 규칙은 network 모듈(희재)이 관리, data 모듈(정현)은 rds_security_group_id를 RDS에 연결만 함
# 규칙 추가·변경은 network 모듈 PR로 요청 (2차 시나리오 9.2 "SG 규칙 변경: 요청 → 희재 반영")
# Terraform은 SG 생성 시 AWS 기본 Egress(all)를 자동 제거한다 → 아래 규칙만 남음

locals {
  # key는 규칙 식별용 (for_each 키가 CIDR 값에 따라 바뀌지 않도록 이름으로 고정)
  rds_ingress = merge(
    { for k, s in var.rosa_subnets : "rosa-${k}" => s.cidr if var.rds_allow_from_rosa },
    { for c in var.rds_ingress_cidrs : "extra-${c}" => c }
  )
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "RDS MariaDB - ROSA app, on-prem replication, admin access"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-rds-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "rds" {
  for_each = local.rds_ingress

  security_group_id = aws_security_group.rds.id
  description       = "MariaDB from ${each.key} (${each.value})"
  ip_protocol       = "tcp"
  from_port         = var.db_port
  to_port           = var.db_port
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "rds" {
  for_each = toset(var.rds_egress_cidrs)

  security_group_id = aws_security_group.rds.id
  description       = "MariaDB replication to ${each.value}"
  ip_protocol       = "tcp"
  from_port         = var.db_port
  to_port           = var.db_port
  cidr_ipv4         = each.value
}
