output "alarm_names" {
  value = concat(
    [for alarm in aws_cloudwatch_metric_alarm.vpn_tunnel_down : alarm.alarm_name],
    [for alarm in aws_cloudwatch_metric_alarm.nlb_no_healthy_targets : alarm.alarm_name],
  )
}
