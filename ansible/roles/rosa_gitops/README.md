# ROSA OpenShift GitOps 구성 자동화

NeuroPlan의 **AWS ROSA HCP 환경에 OpenShift GitOps를 구성하는 Ansible Role**입니다.

Red Hat OpenShift GitOps Operator 설치부터 전용 Argo CD 인스턴스 생성, Git 저장소 인증 등록, Application 생성까지 초기 설정을 자동화합니다. 이후 애플리케이션의 지속적인 배포 동기화는 Argo CD가 담당합니다.

## 1. 주요 기능

| 기능 | 구현 내용 |
| --- | --- |
| 변수 검증 | 필수 설정값과 Application 활성화 시 SSH Key 존재 여부 확인 |
| 매니페스트 검증 | Jinja2 템플릿 렌더링 및 YAML 파싱 |
| Operator 설치 | Namespace·OperatorGroup·Subscription 적용 |
| 전용 Argo CD 구성 | 전용 Namespace와 ArgoCD 리소스 생성, 웹 콘솔 Route 활성화 |
| 배포 대상 준비 | 대상 Namespace 생성 및 `managed-by` Label 설정 |
| 구성요소 대기 | Argo CD CRD와 Server·Repo Server·Application Controller 준비 확인 |
| 저장소 인증 | SSH Private Key를 사용하는 Argo CD Repository Secret 등록 |
| Application 생성 | GitOps 저장소의 `overlays/rosa` 경로 연결 |
| Check Mode | 클러스터 변경 없이 변수·템플릿·YAML 확인 |

## 2. 파일 구성

| 파일 | 역할 |
| --- | --- |
| [defaults/main.yml](./defaults/main.yml) | Namespace, 저장소, Application 등 기본 변수 |
| [tasks/main.yml](./tasks/main.yml) | 검증·설치·상태 대기·Application 생성 작업 |
| [templates/operator-install.yaml.j2](./templates/operator-install.yaml.j2) | Operator Namespace·OperatorGroup·Subscription |
| [templates/argocd-instance.yaml.j2](./templates/argocd-instance.yaml.j2) | 전용 Argo CD와 배포 대상 Namespace |
| [templates/repository-secret.yaml.j2](./templates/repository-secret.yaml.j2) | Git 저장소 SSH 인증 Secret |
| [templates/application.yaml.j2](./templates/application.yaml.j2) | ROSA 배포용 Argo CD Application |

**호출 Playbook:** [`ansible/playbooks/rosa-gitops.yml`](../../playbooks/rosa-gitops.yml)

## 3. 실행 구조

Playbook은 `localhost`에서 `connection: local`로 실행됩니다. Role은 실행 호스트의 `oc` 명령과 현재 로그인된 클러스터 정보를 사용해 ROSA 리소스를 적용합니다.

| 구분 | 역할 |
| --- | --- |
| Terraform ROSA 모듈 | ROSA HCP 클러스터와 관련 IAM·OIDC 구성 |
| 현재 Ansible Role | OpenShift GitOps 초기 설치·연결 설정 |
| GitOps Repository | Deployment·Service·Route 등 애플리케이션 배포 설정 |
| Argo CD | 연결된 Git 경로를 기준으로 클러스터 동기화 |

이 Role에서 Jenkins 빌드나 ECR 이미지 Push, 온프레미스 Argo CD 구성을 수행하지는 않습니다.

## 4. 사전 준비

- 실행 호스트에 Ansible과 OpenShift CLI(`oc`)를 준비합니다.
- 대상 ROSA 클러스터에 로그인하고 현재 API 주소를 확인합니다.
- Namespace, Operator 설치 리소스, ArgoCD, Secret, Application을 생성·관리할 권한을 준비합니다.
- Playbook이 읽는 `ansible/group_vars/all.yml`과 `ansible/group_vars/vault.yml`을 준비합니다.
- Application을 활성화할 경우 저장소 SSH 인증 Key와 `overlays/rosa`의 실제 배포 설정을 준비합니다.
- 애플리케이션에서 필요한 Secret, ECR 접근 권한, TLS·DB 연결 등 배포 선행조건을 확인합니다.

Role은 `oc whoami`와 Namespace 생성 권한을 확인합니다. 다른 리소스에 대한 권한이나 애플리케이션의 모든 선행조건을 자동 검증하는 것은 아닙니다.

## 5. 주요 변수

아래는 `defaults/main.yml`의 기본값입니다. 실제 실행값은 Group Vars와 추가 변수 등에 의해 변경될 수 있습니다.

### Operator 및 Argo CD

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `rosa_gitops_operator_namespace` | `openshift-gitops-operator` | Operator 설치 Namespace |
| `rosa_gitops_operator_channel` | `latest` | Subscription Channel |
| `rosa_gitops_namespace` | `neuroplan-gitops` | 전용 Argo CD Namespace |
| `rosa_gitops_instance_name` | `neuroplan` | ArgoCD 리소스 이름 |
| `rosa_gitops_target_namespace` | `neuroplan` | 애플리케이션 배포 Namespace |
| `rosa_gitops_wait_timeout` | `600s` | CRD Established 및 Rollout 대기 명령의 Timeout |

Operator Subscription은 `redhat-operators` Catalog를 사용하며, `installPlanApproval`은 `Automatic`입니다. 기본 Channel은 특정 버전을 고정하지 않으므로 설치된 버전은 실제 클러스터에서 확인합니다.

### 저장소 및 Application

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `rosa_gitops_repository_url` | `git@github.com:neuroplan-hybrid/neuroplan-gitops.git` | GitOps 저장소 SSH URL |
| `rosa_gitops_repository_revision` | `main` | 동기화할 Git Revision |
| `rosa_gitops_repository_path` | `overlays/rosa` | 배포 설정 경로 |
| `rosa_gitops_repository_secret_name` | `neuroplan-gitops-repo` | 저장소 인증 Secret 이름 |
| `rosa_gitops_repository_private_key` | `vault_jenkins_gitops_private_key` 참조, 미정의 시 빈 문자열 | 저장소 SSH Private Key |
| `rosa_gitops_application_name` | `neuroplan-rosa` | Application 이름 |
| `rosa_gitops_destination_server` | `https://kubernetes.default.svc` | 배포 대상 클러스터 API |
| `rosa_gitops_application_enabled` | `false` | 저장소 인증 및 Application 생성 작업 활성화 |
| `rosa_gitops_automated_sync` | `true` | Application 자동 동기화 설정 |

`rosa_gitops_application_enabled=false`이면 저장소 인증 Secret과 Application 생성 작업을 건너뜁니다. 기존에 생성된 Application을 삭제하거나 자동 동기화를 중지하는 설정은 아닙니다.

## 6. 작업 순서

1. 필수 변수와 조건부 SSH Key 값을 검증합니다.
2. Operator·Argo CD 템플릿을 렌더링하고 YAML을 파싱합니다.
3. Application 활성화 시 Repository Secret과 Application도 렌더링·파싱합니다.
4. 실제 실행 모드에서 `oc` 설치, 로그인, Namespace 생성 권한을 확인합니다.
5. Operator 리소스를 적용하고 Argo CD CRD의 생성 및 Established 상태를 기다립니다.
6. 전용 Argo CD와 Namespace를 적용합니다.
7. Server·Repo Server Deployment와 Application Controller StatefulSet의 Rollout을 확인합니다.
8. Application 활성화 시 Repository Secret과 Application을 적용합니다.
9. Application을 조회하거나, 생성이 비활성화되어 있음을 안내합니다.

## 7. 실행 방법

아래 명령은 저장소의 `ansible` 디렉터리를 기준으로 합니다. Vault 파일을 암호화해 사용하는 경우 `--ask-vault-pass` 또는 프로젝트에서 사용하는 Vault 인증 옵션을 지정합니다.

### 7.1 문법 검사

```bash
cd ansible
ansible-playbook playbooks/rosa-gitops.yml \
  --syntax-check --ask-vault-pass
```

### 7.2 Check Mode

```bash
ansible-playbook playbooks/rosa-gitops.yml \
  --check --ask-vault-pass
```

Check Mode에서는 `oc` 연결과 리소스 적용 작업을 건너뛰고 변수·템플릿·YAML을 확인합니다. Application 관련 템플릿까지 검사하려면 다음과 같이 활성화합니다. 이 경우 유효한 SSH Key 변수도 필요합니다.

```bash
ansible-playbook playbooks/rosa-gitops.yml \
  --check --ask-vault-pass \
  -e rosa_gitops_application_enabled=true
```

Check Mode 성공은 Kubernetes API 스키마 검증, 저장소 접속, 실제 Rollout 성공을 의미하지 않습니다.

### 7.3 Operator 및 전용 Argo CD 구성

먼저 대상 클러스터를 확인합니다.

```bash
oc whoami
oc whoami --show-server
```

Application 생성을 비활성화한 상태로 초기 구성을 적용합니다.

```bash
ansible-playbook playbooks/rosa-gitops.yml \
  --ask-vault-pass \
  -e rosa_gitops_application_enabled=false
```

### 7.4 저장소 연결 및 Application 생성

GitOps 배포 설정과 애플리케이션 선행조건을 확인한 뒤 실행합니다.

```bash
ansible-playbook playbooks/rosa-gitops.yml \
  --ask-vault-pass \
  -e rosa_gitops_application_enabled=true
```

기본값에서는 생성한 Application에 자동 동기화가 설정되어 배포가 시작될 수 있습니다. `automated` 설정에는 `prune: true`와 `selfHeal: true`가 포함되어 있으므로 Git 변경과 수동 클러스터 변경의 영향을 검토합니다.

## 8. 인증정보 처리

- 저장소 SSH Key는 `vault_jenkins_gitops_private_key` 변수에서 참조합니다.
- Repository Secret에는 `argocd.argoproj.io/secret-type: repository` Label을 설정합니다.
- 인증정보를 포함하는 변수 검증, 매니페스트 렌더링·파싱, Secret 적용 작업에는 `no_log: true`를 사용합니다.
- 매니페스트는 `oc apply -f -`의 표준입력으로 전달합니다.
- SSH Private Key와 애플리케이션 비밀번호·API Key는 평문으로 Git에 저장하지 않습니다.

`no_log`는 Ansible 로그 노출을 줄이는 설정입니다. 변수 파일의 암호화와 클러스터 Secret 접근 권한은 별도로 관리합니다.

## 9. 구성 결과 확인

다음 명령은 기본 Namespace와 리소스 이름 기준입니다.

```bash
# Operator 설치 상태
oc -n openshift-gitops-operator get subscription,csv

# 전용 Argo CD와 구성요소 상태
oc -n neuroplan-gitops get argocd neuroplan
oc -n neuroplan-gitops get deploy,statefulset,pod,route

# Application 활성화 후 동기화 및 Health 상태
oc -n neuroplan-gitops get application neuroplan-rosa \
  -o 'custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

# 실제 애플리케이션 리소스
oc -n neuroplan get deploy,pod,svc,route
```

Role은 Application 적용 후 조회까지 수행하며, 애플리케이션이 `Synced`·`Healthy` 상태가 될 때까지 기다리지는 않습니다. 설치 완료 후 별도로 다음 항목을 확인합니다.

- GitOps 저장소 연결 및 `overlays/rosa` 접근
- Application의 동기화·Health 상태와 오류 조건
- ECR 이미지 Pull 및 Frontend·Backend Pod Ready
- Route를 통한 접근과 로그인·조회·저장 등 서비스 동작

## 10. 현재 템플릿 확인 사항

`application.yaml.j2`의 `retry`는 현재 `spec.syncPolicy` 바깥에 작성되어 있습니다. 배포 전 사용 중인 Application CRD의 `syncPolicy.retry` 정의와 비교해 위치를 검토해야 합니다. YAML 파싱만으로는 이 구조의 유효성을 확인할 수 없으므로, 현재 템플릿의 재시도 설정이 적용된 것으로 간주하지 않습니다.

```bash
oc explain application.spec.syncPolicy.retry
```

## 11. 관련 코드 및 문서

- [ROSA Terraform 모듈](../../../modules/rosa)
- [GitOps Repository](https://github.com/neuroplan-hybrid/neuroplan-gitops)
- [ROSA 배포 Overlay](https://github.com/neuroplan-hybrid/neuroplan-gitops/tree/main/overlays/rosa)
- [AWS용 Jenkins 파이프라인](https://github.com/neuroplan-hybrid/neuroplan-application/blob/main/Jenkinsfile.aws)
- [프로젝트 운영 절차](../../../docs/runbooks)
