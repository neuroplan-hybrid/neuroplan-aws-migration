# remote-state — S3 State Bucket (destroy 제외)
# 담당: 작성 희재 / 생성·실행 지정 실행자(예린)
# 기준: IaC 작업가이드 5.1 (State에 VPN PSK 평문 저장 → 암호화·버전·퍼블릭 차단·TLS 강제·접근 제한)
# Lock: envs/prod backend의 use_lockfile = true → 같은 버킷에 <key>.tflock 객체로 잠금 (DynamoDB 미사용)

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.bucket_prefix}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket        = local.bucket_name
  force_destroy = false # 객체(버전 포함)가 남아 있으면 삭제 불가

  lifecycle {
    prevent_destroy = true # terraform destroy로 지워지지 않게 막음
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced" # ACL 비활성화
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# ---------- Bucket Policy ----------
# 1) TLS가 아닌 요청 거부
# 2) state_access_principal_arns 외에는 State 객체(tfstate·tflock·과거 버전) 읽기·쓰기 거부
#    → 관리자 권한 IAM 사용자여도 명시적 Deny가 우선

data "aws_iam_policy_document" "state" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = length(var.state_access_principal_arns) > 0 ? [1] : []

    content {
      sid    = "DenyStateObjectAccessExceptExecutors"
      effect = "Deny"
      actions = [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
      ]
      resources = ["${aws_s3_bucket.state.arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnNotLike"
        variable = "aws:PrincipalArn"
        values   = var.state_access_principal_arns
      }
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}
