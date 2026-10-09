# Jenkins AWS CI accesses private ECR through an existing IAM user.
# Keep this permission in a separate bootstrap state: envs/prod is destroyed
# after the ROSA demo, but Jenkins and On-Prem ECR access must remain available.
#
# The existing user "jenkins-ecr" is NOT created or imported by this root.
# Only the single missing read action is managed here.

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "jenkins_ecr_describe_images" {
  statement {
    sid    = "DescribeNeuroPlanImages"
    effect = "Allow"

    actions = ["ecr:DescribeImages"]

    resources = [
      "arn:aws:ecr:ap-northeast-2:${data.aws_caller_identity.current.account_id}:repository/neuroplan-backend",
      "arn:aws:ecr:ap-northeast-2:${data.aws_caller_identity.current.account_id}:repository/neuroplan-frontend",
    ]
  }
}

resource "aws_iam_user_policy" "jenkins_ecr_describe_images" {
  name   = "NeuroPlanJenkinsECRDescribeImagesTF"
  user   = "jenkins-ecr"
  policy = data.aws_iam_policy_document.jenkins_ecr_describe_images.json

  # Independent bootstrap resource: never remove during the ROSA teardown.
  lifecycle {
    prevent_destroy = true
  }
}
