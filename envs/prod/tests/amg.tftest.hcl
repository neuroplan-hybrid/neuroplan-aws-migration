mock_provider "aws" {}
mock_provider "rhcs" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "null" {}

variables {
  enable_vpn    = false
  enable_dr_nlb = false
}

run "workspace_disabled_by_default" {
  command = plan
  assert {
    condition     = length(module.amg_workspace) == 0
    error_message = "Ordinary infrastructure plans must not create an AMG workspace."
  }
}

run "reject_vpc_without_network" {
  command = plan
  variables {
    enable_amg_workspace      = true
    amg_admin_user_ids        = ["11111111-1111-1111-1111-111111111111"]
    enable_amg_vpc_connection = true
  }
  expect_failures = [var.enable_amg_vpc_connection]
}
