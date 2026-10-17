# ROSA HCP 플랫폼 구성

NeuroPlan 하이브리드 클라우드 프로젝트의 **AWS ROSA HCP 운영 환경**을 구성하는 Terraform 모듈입니다.

1차 프로젝트에서 구축한 온프레미스 Kubernetes 환경을 DR로 활용하고, AWS ROSA HCP를 주 운영 환경으로 구성하는 과정에서 사용했습니다. 네트워크 모듈이 생성한 서브넷을 전달받아 클러스터와 관련 IAM 역할, OIDC 구성을 생성합니다.

## 1. 주요 구성

이 모듈은 `terraform-redhat/rosa-hcp/rhcs` 모듈의 **1.7.5 버전**을 호출하는 래퍼 모듈입니다.

| 구성 항목 | 구현 내용 |
| --- | --- |
| ROSA HCP 클러스터 | 클러스터 이름과 OpenShift 버전을 입력받아 구성 |
| 네트워크 연결 | 기존 Public·Private Subnet ID와 Machine CIDR 전달 |
| Worker 구성 | 인스턴스 유형과 Worker 수 전달. Worker 수 기본값은 3 |
| Account IAM Roles | `create_account_roles = true`로 생성 활성화 |
| OIDC 구성 | `create_oidc = true`로 생성 활성화 |
| Operator IAM Roles | `create_operator_roles = true`로 생성 활성화 |
| 출력값 | 클러스터 ID·API URL·Console URL·상태·Worker IAM Role ARN 제공 |

Account Role과 Operator Role의 이름 접두사는 입력 변수로 관리합니다. 관련 리소스의 세부 생성 로직은 호출하는 상위 모듈에서 처리합니다.

## 2. 파일 구성

| 파일 | 역할 |
| --- | --- |
| [main.tf](./main.tf) | ROSA HCP 모듈 호출 및 클러스터·IAM·OIDC 생성 옵션 설정 |
| [variables.tf](./variables.tf) | 클러스터, 네트워크, Worker, IAM Role 접두사 입력 정의 |
| [outputs.tf](./outputs.tf) | 클러스터 정보와 Worker IAM Role ARN 출력 |
| [versions.tf](./versions.tf) | Terraform 및 Provider 버전 요구사항 정의 |

## 3. 버전 요구사항

아래 값은 현재 `versions.tf`와 `main.tf`에 선언된 요구사항입니다.

| 항목 | 버전 조건 |
| --- | --- |
| Terraform | `>= 1.10` |
| AWS Provider (`hashicorp/aws`) | `>= 6.44.0` |
| RHCS Provider (`terraform-redhat/rhcs`) | `~> 1.7.9` |
| ROSA HCP 모듈 (`terraform-redhat/rosa-hcp/rhcs`) | `1.7.5` |

Provider의 실제 선택 버전은 실행 루트의 `.terraform.lock.hcl`을 기준으로 확인합니다. Provider 인증과 실행 환경 설정은 이 모듈을 호출하는 루트에서 준비합니다.

## 4. 입력 변수

| 변수 | 타입 | 기본값 | 설명 |
| --- | --- | --- | --- |
| `cluster_name` | `string` | 필수 | ROSA HCP 클러스터 이름 |
| `openshift_version` | `string` | 필수 | 구성할 OpenShift 버전 |
| `aws_subnet_ids` | `list(string)` | 필수 | 클러스터 구성에 사용할 Public·Private Subnet ID 목록 |
| `machine_cidr` | `string` | 필수 | ROSA HCP Machine CIDR |
| `compute_machine_type` | `string` | `null` | Worker EC2 인스턴스 유형 |
| `replicas` | `number` | `3` | Worker 노드 수 |
| `account_role_prefix` | `string` | 필수 | Account IAM Role 이름 접두사 |
| `operator_role_prefix` | `string` | 필수 | Operator IAM Role 이름 접두사 |

`compute_machine_type`을 지정하지 않으면 `null`을 상위 모듈에 전달합니다. 프로젝트에서 사용할 값은 실행 루트의 변수 및 tfvars에서 관리합니다.

## 5. 출력값

| 출력값 | 설명 |
| --- | --- |
| `cluster_id` | ROSA HCP 클러스터 ID |
| `cluster_api_url` | 클러스터 API 서버 URL |
| `cluster_console_url` | OpenShift 웹 콘솔 URL |
| `cluster_state` | 클러스터 상태 |
| `worker_role_arn` | `HCP-ROSA-Worker` Account IAM Role의 ARN |

`worker_role_arn`은 상위 모듈의 `account_roles_arn["HCP-ROSA-Worker"]` 값을 반환합니다.

## 6. 프로젝트 내 호출 방식

실행 루트인 [`envs/prod/main.tf`](../../envs/prod/main.tf)에서 다음과 같이 호출합니다.

```hcl
module "rosa" {
  count  = var.enable_rosa ? 1 : 0
  source = "../../modules/rosa"

  depends_on = [module.network]

  cluster_name = var.cluster_name
  aws_subnet_ids = concat(
    module.network.public_subnet_ids,
    module.network.private_rosa_subnet_ids
  )

  openshift_version    = var.openshift_version
  machine_cidr         = module.network.vpc_cidr
  compute_machine_type = var.compute_machine_type
  replicas             = var.rosa_replicas

  account_role_prefix  = var.account_role_prefix
  operator_role_prefix = var.operator_role_prefix
}
```

- `enable_rosa`는 실행 루트에서 모듈 포함 여부를 결정합니다.
- Public Subnet과 ROSA용 Private Subnet 목록을 합쳐 전달합니다.
- Machine CIDR에는 네트워크 모듈의 VPC CIDR을 사용합니다.
- 실행 루트의 `rosa_replicas` 값을 이 모듈의 `replicas`에 전달합니다.
- `count`를 사용하므로, 활성화된 모듈의 출력은 `module.rosa[0].cluster_id`와 같이 참조합니다. 비활성화 상태에서는 인스턴스가 없으므로 조건부 처리가 필요합니다.

> 기존 클러스터가 관리 중인 상태에서 `enable_rosa`를 `false`로 변경하면 해당 모듈 리소스가 삭제 계획에 포함될 수 있습니다. 단계별 tfvars를 전환할 때에는 Plan의 생성·변경·삭제 대상을 확인합니다.

## 7. 구성 범위 및 다른 모듈과의 관계

| 영역 | 담당 코드 |
| --- | --- |
| VPC·서브넷 등 기반 네트워크 | [`modules/network`](../network) |
| ROSA HCP·Account Roles·OIDC·Operator Roles | 현재 모듈 |
| ECR 이미지 저장소 | [`modules/ecr`](../ecr) |
| Worker의 ECR 접근 정책 연계 | [`envs/prod/rosa-ecr-policy.tf`](../../envs/prod/rosa-ecr-policy.tf) |
| OpenShift GitOps 구성 | [`ansible/roles/rosa_gitops`](../../ansible/roles/rosa_gitops) |
| 애플리케이션 리소스 및 환경별 배포 설정 | [neuroplan-gitops](https://github.com/neuroplan-hybrid/neuroplan-gitops) |

이 모듈은 ROSA 플랫폼 구성에 집중합니다. 애플리케이션 이미지 빌드와 배포 버전 갱신은 Jenkins 파이프라인에서 수행하고, 클러스터 내부의 애플리케이션 배포 설정은 GitOps 저장소에서 관리합니다.

## 8. 검토 및 적용 흐름

변경사항은 실행 루트인 `envs/prod`에서 다른 모듈과 함께 검토합니다.

1. ROSA 모듈 또는 관련 변수 변경사항을 PR로 작성합니다.
2. Terraform 포맷과 구성 유효성을 확인합니다.
3. 대상 환경의 tfvars를 사용해 Plan을 생성합니다.
4. 클러스터·IAM 등 리소스의 생성·변경·삭제 내역을 검토합니다.
5. 팀 검토 후 지정 실행자가 승인된 Plan을 적용합니다.

클러스터 구성 후에는 출력된 API·Console 정보와 노드 상태를 확인하고, GitOps 및 애플리케이션 배포 검증을 이어서 수행합니다. 상세 실행 절차는 [프로젝트 README](../../README.md)와 [운영 문서](../../docs/runbooks)를 참고합니다.
