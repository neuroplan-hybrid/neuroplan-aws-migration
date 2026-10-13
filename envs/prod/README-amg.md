# Amazon Managed Grafana 생성

기존 온프렘 Grafana를 유지하면서 AMG를 통합 조회 화면으로 추가한다.
관련: #98, #103(네트워크 코드), #111(네트워크 적용·검증).

## 이 코드가 생성하는 것

- AMG Workspace
- CloudWatch 메트릭 조회 전용 IAM Role·Inline Policy
- 기존 IAM Identity Center 사용자에 대한 Workspace ADMIN 연결
- 선택적으로 기존 ROSA Private 서브넷·AMG SG를 사용하는 outbound VPC 연결

기본값은 `enable_amg_workspace=false`, `enable_amg_vpc_connection=false`다.
기존 운영 tfvars·RDS·ROSA·Route 53·알람 설정은 변경하지 않는다.
Grafana 데이터 소스·대시보드, ROSA SA/RBAC·토큰, Monitoring VM 방화벽은 별도 구성한다.
`data_sources=["CLOUDWATCH"]`는 접근 대상 선언이지 데이터 소스 자동 등록이 아니다.

## 인증 선행조건

AMG 웹 로그인에는 IAM 사용자가 아닌 **IAM Identity Center 또는 SAML**이 필요하다.
이 코드는 Identity Center를 사용하며, 기존 사용자 ID를 입력받는다.
Identity Center 인스턴스·사용자 생성이나 학원 AWS 조직 설정 변경은 하지 않는다.
계정에 사용 가능한 Identity Center가 있는지와 실행자의 AMG/IAM/사용자 연결 권한을
플랫폼 담당과 먼저 확인한다. `kjh` 또는 IAM ARN은 사용자 ID가 아니다.
준비되지 않았다면 Apply하지 않는다. SAML이 필요하면 별도 변경으로 진행한다.

## 단계 1 — CloudWatch부터 구성

실행 위치: 기존 운영 Terraform 실행 환경의 `envs/prod`.
**현재 운영 State·backend·tfvars를 그대로 사용한다. 새 State나 다른 tfvars로 적용하지 않는다.**

기존 운영 tfvars에 아래 입력을 추가하거나, 검토용 로컬 tfvars 파일로 전달한다.
아래는 추가 입력 예시이며 전체 운영 tfvars를 대체하지 않는다.

```hcl
enable_amg_workspace      = true
amg_admin_user_ids        = ["실제-Identity-Center-사용자-ID"]
enable_amg_vpc_connection = false
```

- 운영 전체 Plan에서 AMG 관련 **4 add / 0 change / 0 destroy** 차이인지 검토한다.
- 기존 #103 네트워크 플래그는 실제 배포 상태와 맞춰 유지한다.
  아직 미적용인 네트워크를 같이 켜면 별도로 7 add가 추가될 수 있다.
- 예상 외 기존 리소스 변경·삭제가 있으면 중단한다. `-target`으로 숨기지 않는다.
- 승인된 saved Plan으로만 Apply한다. 코드 승인·Merge는 운영 Apply 승인이 아니다.
- Apply 후 `terraform output amg_workspace_url`에서 주소 확인 → Identity Center 로그인.
- AMG에서 CloudWatch 데이터 소스를 추가하고 Workspace IAM Role 인증 및
  기본 Region `ap-northeast-2` 설정 후 Save & Test·RDS 지표 조회를 확인한다.
  Access Key·Secret Key는 입력하지 않는다.

## 단계 2 — 온프렘·ROSA 통합

#111 네트워크 적용과 Monitoring VM 수신·방화벽·복귀 경로 검증 이후:

```hcl
enable_amg_workspace         = true
amg_admin_user_ids           = ["실제-Identity-Center-사용자-ID"]
enable_amg_vpc_connection    = true
enable_amg_onprem_prometheus = true
# 기존 운영 enable_nat=true, enable_vpn=true 유지
```

- 기존 Private ROSA 서브넷 3개(서로 다른 AZ)와 #103의 SG를 재사용한다.
  적용 전에 각 서브넷의 여유 IP 15개 이상을 확인한다.
- VPC 연결 이후 **모든 데이터 소스 트래픽**이 VPC를 경유한다.
  현재 설계는 기존 NAT로 CloudWatch·Thanos HTTPS에 접근하므로 NAT/VPN이 꺼지면
  해당 경로가 깨진다. 새 NAT·Endpoint는 생성하지 않는다.
- 네트워크가 먼저 적용된 상태라면 Workspace VPC 설정 업데이트가 예상되며,
  Stage 1의 4 add만 나오는 것은 아니다. 실제 전체 Plan을 다시 승인받는다.
- 서비스 연결 역할이 처음 필요한 계정에서는 AMG가 AWSServiceRoleForAmazonGrafana를
  생성할 수 있으므로 실행자의 `iam:CreateServiceLinkedRole` 권한도 사전 확인한다.
- 온프렘 Prometheus 데이터 소스: `http://192.168.14.73:9090`, `up` 조회.
- ROSA Prometheus 데이터 소스: Thanos Querier Route + 조회 전용 SA 토큰.
  관리자 토큰 사용 금지, 토큰 만료·갱신 및 RBAC는 별도 준비.
- VPC 연결 후 CloudWatch Save & Test도 다시 확인한다.
- 기존 대시보드 JSON을 가져오고 데이터 소스 UID·패널 쿼리를 맞춘다.

## 운영·종료

- 무료 체험 적용 여부는 별도 확인한다. 사용자 라이선스·CloudWatch 조회·NAT/전송
  비용이 있을 수 있으며 이 PR은 무료 적용을 보장하지 않는다.
- 자동 갱신·Alert Rule·사용자 수는 비용을 확인하며 정한다.
- 10/16 ROSA·NAT·VPN 제거 전 AMG 유지/삭제 여부를 함께 결정한다.
  이 코드에 `prevent_destroy`를 두지 않았으므로 운영 전체 destroy에 AMG도 포함된다.
- Workspace 비활성화는 삭제 계획을 만들므로 대시보드 JSON을 먼저 내보내 보관한다.
- 데이터 소스·대시보드 자동화(Grafana Provider)는 후속 작업이며 이 PR에 토큰을 저장하지 않는다.

## 검증

```bash
terraform fmt -check -recursive
terraform -chdir=modules/amg init -backend=false
terraform -chdir=modules/amg validate
terraform -chdir=modules/amg test
terraform -chdir=envs/prod init -backend=false
terraform -chdir=envs/prod validate
terraform -chdir=envs/prod test
```

모듈·운영 루트 테스트는 mock Provider로 실제 AWS 생성 없이 CloudWatch-only/VPC 연결,
관리자 입력 누락·단일 서브넷 거부, 기본 비활성화·네트워크 입력 누락 차단을 확인한다. 실제 운영 Plan·로그인·지표 조회는
배포 환경에서 별도로 검증해야 한다.

공식 문서:
- https://docs.aws.amazon.com/grafana/latest/userguide/authentication-in-AMG.html
- https://docs.aws.amazon.com/grafana/latest/userguide/AMG-configure-vpc.html
- https://docs.aws.amazon.com/grafana/latest/userguide/AMG-manage-permissions.html
