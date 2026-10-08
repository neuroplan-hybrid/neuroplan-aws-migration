# ROSA HCP Worker가 NeuroPlan Private ECR 이미지를 Pull하기 위한 최소 권한.
# ECR 인증 토큰 발급 권한은 기본 ROSAWorkerInstancePolicy에서 제공한다.

data "aws_iam_policy_document" "rosa_ecr_pull" {
  statement {
    sid    = "NeuroPlanECRPull"
    effect = "Allow"

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]

    resources = [
      "arn:aws:ecr:ap-northeast-2:707191185613:repository/neuroplan-backend",
      "arn:aws:ecr:ap-northeast-2:707191185613:repository/neuroplan-frontend",
    ]
  }
}

resource "aws_iam_policy" "rosa_ecr_pull" {
  count = var.enable_rosa ? 1 : 0

  name        = "neuroplan-rosa-ecr-pull"
  description = "Read-only ECR image pull access for NeuroPlan ROSA workers"
  policy      = data.aws_iam_policy_document.rosa_ecr_pull.json
}

resource "aws_iam_role_policy_attachment" "rosa_ecr_pull" {
  count = var.enable_rosa ? 1 : 0

  role       = element(reverse(split("/", module.rosa[0].worker_role_arn)), 0)
  policy_arn = aws_iam_policy.rosa_ecr_pull[0].arn
}
