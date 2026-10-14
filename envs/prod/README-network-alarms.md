# VPN·NLB CloudWatch 이메일 알림

관련: #113(기존 온프렘 Grafana 통합), #114(AMG 비활성화).
**서울(ap-northeast-2)만 사용한다. Route 53 알람·버지니아 SNS·AMG는 만들지 않는다.**
Route 53 관측은 기존 HealthCheckStatus 지표를 Grafana에서 us-east-1로 조회하는 별도 작업이다.

## 추가 대상

| 대상 | 지표·조건 | 기본 판정 |
|---|---|---|
| VPN tunnel1 / tunnel2 | AWS/VPN TunnelState, 각 터널 Maximum < 1 | 60초 단위 2회 연속 |
| DR NLB target group | AWS/NetworkELB HealthyHostCount Maximum < 1 | 60초 단위 2회 연속 |
| ROSA NLB의 선택한 target group | 같은 조건, 실제 NLB·TG 입력 후 조회 검증 | 60초 단위 2회 연속 |

- VPN 한 터널 장애는 이중화 저하 경고이지 전체 VPN 단절 확정이 아니다.
- NLB 알림은 선택한 TG에서 보고된 정상 타깃이 전부 없을 때다. 일부 타깃 장애,
  TLS·로그인·DB·API 기능 성공 여부를 보장하거나 전부 검출하는 것은 아니다.
- NLB는 AWS 권고에 따라 Maximum을 사용한다. 전체 관측 구간에 정상 타깃이
  하나라도 있으면 경보 조건에서 벗어날 수 있다. 부분 AZ 장애는 별도 알림 범위다.
- 정상화(OK) 이메일도 보낸다. 누락 데이터는 missing으로 표시하고 정상으로 간주하지 않는다.
  INSUFFICIENT_DATA 이메일은 설정하지 않으므로 누락 지표는 대시보드에서도 확인한다.
- SNS Topic·Policy·이메일 구독은 기존 RDS 것을 재사용한다. 새 SNS·이메일 재구독 없음.
- 재부팅·승격·자동 복구·Route 53 변경 액션 없음. 알림은 감지/이메일 전달만 한다.

## 기본값과 운영 입력

`enable_network_cloudwatch_alarms=false`라 Merge·일반 Apply만으로 생성되지 않는다.
네트워크 담당과 조건 합의·Plan 확인 후 **기존 운영 tfvars 두 파일에 같은 입력**을 유지한다.
한 번 생성한 뒤 false로 돌리거나 입력을 빼면 알람 삭제 계획이 나오므로 주의한다.

```hcl
enable_network_cloudwatch_alarms = true
network_alarm_evaluation_periods = 2

# 기존 운영 true 값 유지: RDS/SNS, VPN, DR NLB
# enable_rds_cloudwatch_alarms=false로 바꾸지 않는다.
rosa_nlb_alarm_targets = {
  https = {
    load_balancer_arn = "실제-ROSA-NLB-ARN"
    target_group_arn  = "해당-NLB의-HTTPS-TG-ARN"
  }
}
```

위 문자열은 설명용 자리표시자이며 그대로 Plan하지 않는다.
ROSA 운영 중에는 실제 ROSA 대상 입력 없이 알림 활성화하면 중단한다.
여러 TG를 관측하려면 안정적인 키로 각각 추가하며 알람 수가 그만큼 늘어난다.
ROSA가 꺼진 단계에는 ROSA 알람 대상이 제외된다.
RDS/SNS·VPN·DR NLB가 없는 단계에서 이 스위치를 켜면 Plan을 거부한다.
단계 전환/destroy에서는 이 스위치도 함께 끄거나 전체 삭제 범위에 포함한다.

## ROSA NLB·TG 조회 — 변경 없는 명령

DevOps VM에서 실행자의 기존 인증 환경을 유지한다. 아래 예시는 AWS_PROFILE을
강제로 변경하지 않는다. 프로필 선택이 필요하면 본인에게 발급된 프로필을 사용한다.
먼저 아래 계정 조회가 성공하고 Account가 운영 계정 707191185613인지 확인한다.
다른 계정이거나 권한 오류가 나면 NLB 조회·Plan·Apply를 중단한다.

```bash
export AWS_PAGER=""

aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table

aws elbv2 describe-load-balancers --region ap-northeast-2 --query 'LoadBalancers[].{Name:LoadBalancerName,DNS:DNSName,Type:Type,ARN:LoadBalancerArn}' --output table
```

현재 운영 `primary_lb_dns_name`과 DNS가 정확히 같은 NLB를 선택한다.
그 ARN으로 다음을 조회하고 실제 Listener·포트에 맞는 TG를 선택한다.

```bash
ROSA_NLB_ARN='위에서-확인한-실제-NLB-ARN'

aws elbv2 describe-listeners --region ap-northeast-2 --load-balancer-arn "$ROSA_NLB_ARN" --query 'Listeners[].{Port:Port,Protocol:Protocol,Actions:DefaultActions}' --output table

aws elbv2 describe-target-groups --region ap-northeast-2 --load-balancer-arn "$ROSA_NLB_ARN" --query 'TargetGroups[].{Name:TargetGroupName,Port:Port,Protocol:Protocol,ARN:TargetGroupArn}' --output table
```

Terraform은 NLB가 현재 primary_lb_dns_name과 일치하고 TG가 그 NLB에 연결됐는지
읽기 전용 Data Source로 검사한다. ROSA 소유 NLB/TG는 Import·수정·삭제하지 않는다.
DR NLB/TG·VPN ID/터널 IP·SNS ARN은 기존 모듈 Output으로 자동 연결한다.

## Plan·Apply·확인

- 기존 운영 계정·S3 State·default workspace·최신 코드로 전체 Plan을 새로 만든다.
- #114가 병합된 최신 main과 수정한 PR HEAD를 대조한다. 먼저 기본 OFF에서
  rosa-on.tfvars·operation.tfvars 각각 전체 Plan이 0 add / 0 change / 0 destroy인지
  플랫폼 실행 환경에서 확인한다. 로컬 mock/CI PASS를 운영 Plan 증적으로 대신하지 않는다.
- ROSA TG 1개면 **CloudWatch 알람 4 add** 예상(터널 2 + DR 1 + ROSA 1).
  ROSA TG N개면 3+N개, ROSA 없이 DR/VPN만이면 3개다.
- SNS 추가·구독 추가·기존 RDS/VPN/NLB/Route 53/IAM 변경·삭제는 없어야 한다.
- #114와 AMG 설정 정리가 아직 반영되지 않았다면 미적용 AMG 플래그를 false로
  유지해야 한다. AMG=true 이전 saved Plan은 적용하지 않는다.
- 변경·교체·삭제가 예상과 다르면 중단하고 담당자와 확인한다. -target으로 숨기지 않는다.
- 명시적 GO 후 승인된 saved Plan **하나만** 적용한다.
- 서울에서 알람 dimensions와 상태·SNS action ARN을 확인한다. 초기에는
  INSUFFICIENT_DATA일 수 있으며 실제 지표가 도착해 OK가 되는지 확인해야 한다.
- 기존 SNS 테스트 메일 수신 PASS가 새 알람의 실제 발화·복구 메일 PASS를 뜻하지 않는다.
  실제 데이터 기반 발화·복구 또는 제한된 알림 테스트를 별도 기록한다.

## T4·T5와의 관계

- 28초처럼 짧은 T4 터널 Down은 60초 Maximum·2개 연속 구간을 만족하지 않아
  메일이 오지 않을 수 있다. 알림 확인 때문에 장애 주입을 임의로 늘리지 않는다.
- T5는 primary HC inverted로 DNS 판정을 바꾸는 것이므로 NLB 타깃이 정상인 채
  전환될 수 있다. 이 경우 NLB 알람 메일이 오지 않아도 정상이며 Route 53 알람은
  이번 범위가 아니다.
- 장애 주입 시간·예상 알림·복구 시간을 수신자와 공유한다. 메일 도착 시간은
  1초 probe/k6 RTO 측정 기준이 아니다.
- 테스트용 판정 기간 단축이 필요하면 사전 합의하고 운영 tfvars를 원복한다.
- 이 PR은 ROSA Pod/API·RDS CPU·NAT·S3 알림 구현을 포함하지 않는다.
  ROSA Prometheus 수집/알림은 #113의 별도 GitOps 작업이다.

## 로컬/CI 검증

```bash
terraform fmt -check -recursive
terraform -chdir=modules/network-alarms init -backend=false
terraform -chdir=modules/network-alarms validate
terraform -chdir=modules/network-alarms test
terraform -chdir=envs/prod init -backend=false
terraform -chdir=envs/prod validate
terraform -chdir=envs/prod test
```

Mock 테스트는 AWS 리소스를 생성하지 않는다. 실제 운영 Plan·지표·메일 검증은 별도다.
CloudWatch 알람·조회와 SNS 이메일에 과금이 발생할 수 있으므로 무료라고 단정하지 않는다.

공식 지표 문서:
- https://docs.aws.amazon.com/vpn/latest/s2svpn/monitoring-cloudwatch-vpn.html
- https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-cloudwatch-metrics.html
