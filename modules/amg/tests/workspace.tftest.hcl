mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
}

variables {
  region         = "ap-northeast-2"
  admin_user_ids = ["11111111-1111-1111-1111-111111111111"]
}

run "cloudwatch_first" {
  command = plan
  assert {
    condition     = length(aws_grafana_workspace.this.vpc_configuration) == 0
    error_message = "CloudWatch-first setup must not create a VPC connection."
  }
  assert {
    condition     = aws_grafana_workspace.this.permission_type == "CUSTOMER_MANAGED" && toset(aws_grafana_workspace.this.authentication_providers) == toset(["AWS_SSO"])
    error_message = "Workspace must use customer-managed permissions and Identity Center authentication."
  }
  assert {
    condition     = aws_grafana_role_association.admin.role == "ADMIN"
    error_message = "Existing Identity Center users must receive workspace admin access."
  }
  assert {
    condition     = jsondecode(aws_iam_role.workspace.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "123456789012"
    error_message = "Trust policy must be restricted to the deployment account."
  }
  assert {
    condition     = !contains(jsondecode(aws_iam_role_policy.cloudwatch.policy).Statement[0].Action, "sns:Publish") && !contains(jsondecode(aws_iam_role_policy.cloudwatch.policy).Statement[0].Action, "cloudwatch:PutMetricData")
    error_message = "Workspace role must not write metrics or send SNS notifications."
  }
}

run "existing_vpc_connection" {
  command = plan
  variables {
    vpc_configuration = {
      subnet_ids         = ["subnet-11111111", "subnet-22222222"]
      security_group_ids = ["sg-11111111"]
    }
  }
  assert {
    condition     = length(aws_grafana_workspace.this.vpc_configuration) == 1
    error_message = "Explicit VPC setup must be attached to the workspace."
  }
}

run "reject_missing_admin" {
  command = plan
  variables {
    admin_user_ids = []
  }
  expect_failures = [var.admin_user_ids]
}

run "reject_single_subnet" {
  command = plan
  variables {
    vpc_configuration = {
      subnet_ids         = ["subnet-11111111"]
      security_group_ids = ["sg-11111111"]
    }
  }
  expect_failures = [var.vpc_configuration]
}
