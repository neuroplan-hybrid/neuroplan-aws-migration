# Offline only: every AWS resource/data source is mocked; no credentials or AWS writes.
mock_provider "aws" {
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:ap-northeast-2:000000000000:test-rds-alarms"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
}

variables {
  enabled                              = true
  project_name                         = "neuroplan-test"
  environment                          = "test"
  rds_mode                             = "operation"
  identifier                           = "neuroplan-test"
  engine_version                       = "11.8.8"
  onprem_mariadb_version               = "11.8.8"
  instance_class                       = "db.t4g.micro"
  allocated_storage                    = 20
  master_username                      = "testadmin"
  db_subnet_ids                        = ["subnet-test-a", "subnet-test-c"]
  rds_security_group_ids               = ["sg-test"]
  multi_az                             = false
  backup_retention_days                = 7
  skip_final_snapshot                  = false
  final_snapshot_identifier            = "neuroplan-test-final"
  enable_cloudwatch_alarms             = true
  database_connections_alarm_threshold = 24
}

run "single_az_preserves_existing_events" {
  command = apply

  assert {
    condition     = toset(aws_db_event_subscription.rds_events[0].event_categories) == toset(["availability", "failure", "maintenance"])
    error_message = "Single-AZ must preserve the existing three event categories."
  }
  assert {
    condition     = aws_db_instance.mariadb[0].multi_az == false
    error_message = "Single-AZ must not enable Multi-AZ."
  }
}

run "multi_az_adds_failover_and_reuses_notifications" {
  command = apply
  variables {
    multi_az = true
  }

  assert {
    condition     = toset(aws_db_event_subscription.rds_events[0].event_categories) == toset(["availability", "failure", "maintenance", "failover"])
    error_message = "Multi-AZ must add failover without dropping existing categories."
  }
  assert {
    condition     = aws_db_instance.mariadb[0].multi_az && aws_db_instance.mariadb[0].backup_retention_period == 7 && aws_db_instance.mariadb[0].skip_final_snapshot == false
    error_message = "Multi-AZ must retain backup and final snapshot protections."
  }
  assert {
    condition     = aws_db_event_subscription.rds_events[0].sns_topic == aws_sns_topic.rds_alarms[0].arn && toset(aws_db_event_subscription.rds_events[0].source_ids) == toset(["neuroplan-test"])
    error_message = "Events must reuse the RDS SNS topic and DB source."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.rds_database_connections[0].threshold == 24 && aws_cloudwatch_metric_alarm.rds_free_storage[0].threshold == 4294967296
    error_message = "Existing alarm thresholds must not change."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.rds_database_connections[0].alarm_actions == toset([aws_sns_topic.rds_alarms[0].arn]) && aws_cloudwatch_metric_alarm.rds_database_connections[0].ok_actions == toset([aws_sns_topic.rds_alarms[0].arn])
    error_message = "Existing ALARM/OK notification actions must be retained."
  }
}

run "multi_az_does_not_enable_disabled_alarms" {
  command = plan
  variables {
    multi_az                 = true
    enable_cloudwatch_alarms = false
  }
  assert {
    condition     = length(aws_db_event_subscription.rds_events) == 0 && length(aws_sns_topic.rds_alarms) == 0 && length(aws_cloudwatch_metric_alarm.rds_database_connections) == 0 && length(aws_cloudwatch_metric_alarm.rds_free_storage) == 0
    error_message = "Multi-AZ must not bypass the alarm opt-in."
  }
}

run "disabled_module_creates_nothing" {
  command = plan
  variables {
    enabled  = false
    multi_az = true
  }
  assert {
    condition     = length(aws_db_instance.mariadb) == 0 && length(aws_db_event_subscription.rds_events) == 0 && length(aws_sns_topic.rds_alarms) == 0
    error_message = "Disabled data module must not create a DB or notifications."
  }
}
