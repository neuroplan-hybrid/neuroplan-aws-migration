# Jenkins ECR DescribeImages 권한 — 독립 Bootstrap State

## 배경
2026-10-09 제공된 `neuroplan-aws-ci` 실패 로그에서 Application `a4d120f`의
Maven 테스트(8/8), Docker Build, ECR Push는 성공했다. 이후
`Verify ECR Images`의 `ecr:DescribeImages` 호출이
`arn:aws:iam::707191185613:user/jenkins-ecr` 권한 부족으로 실패해,
GitOps 갱신과 On-Prem Argo CD Auto-Sync는 실행되지 않았다.

## 소유 경계
- AWS IAM 정책: **Terraform**. 기존 `jenkins-ecr` 사용자에
  `ecr:DescribeImages`만 추가한다. Backend/Frontend ECR 두 저장소만 허용.
- Jenkins Job, Credentials, On-Prem `ecr-pull-secret` RBAC: **기존 Ansible**.
  이 변경은 Ansible 작업을 대체하거나 수정하지 않는다.
- 애플리케이션 파이프라인: 기존 `Jenkinsfile.aws` 사용.
  ECR 조회 시 `AccessDenied`를 `ImageNotFound`로 오판하는 로직은
  **후속 개선 PR**에서 별도 수정할 수 있다.

`envs/prod` State는 10/16 ROSA 환경 정리 시 destroy 대상이므로 이 IAM
권한을 거기에 포함하지 않는다. `bootstrap/jenkins-iam`은 별도의 S3
State를 사용하고 **destroy 대상에서 제외**한다.
이 루트는 사용자 자체를 생성/관리하지 않으므로 기존 사용자와 기존 Push
권한에는 변경을 가하지 않는다.

## 사전 확인 (읽기 전용)
지정 실행자 AWS 프로필로 수행한다. 어떤 출력에도 Access Key를 노출하지 않는다.

```bash
aws sts get-caller-identity
aws iam get-user --user-name jenkins-ecr --query 'User.Arn' --output text
aws iam list-user-policies --user-name jenkins-ecr --output table
```

- 대상 계정이 `707191185613`인지 확인한다.
- 이름 `NeuroPlanJenkinsECRDescribeImagesTF`인 기존 inline policy가 있다면
  새로 덮어쓰지 말고 State/소유권을 먼저 확인한다.
- `aws iam put-user-policy`로 콘솔·CLI에서 중복 수동 변경하지 않는다.

## Terraform 확인 및 승인 후 적용
저장소 최신 `main`에 PR을 리뷰·Merge한 뒤 **별도 승인**을 받아 지정
실행자가 수행한다. 기존 S3 State Bucket(기본
`neuroplan-tfstate-707191185613`)과 State 접근 권한이 있어야 한다.
이 Bucket은 기존 `bootstrap/remote-state`에서 관리한다.

```bash
cd bootstrap/jenkins-iam

terraform fmt -check
terraform init -backend-config="bucket=neuroplan-tfstate-707191185613"
terraform validate
terraform plan -out=jenkins-iam.tfplan

# Plan 예상: aws_iam_user_policy.jenkins_ecr_describe_images 1개 신규 생성
# IAM 사용자 생성·삭제·교체 및 다른 환경 리소스 변경은 허용하지 않는다.
# 리뷰/별도 승인 후에만:
terraform apply jenkins-iam.tfplan
```

`terraform init`에서 기존 State가 발견되거나 Plan이 예상과 다르면
진행을 중단하고 원인을 확인한다. `*.tfplan` 및 State 파일은 커밋하지 않는다.

## Jenkins → GitOps → On-Prem 실측 게이트

- [ ] 적용 직후 ECR 이미지 `a4d120f` 조회를 **Jenkins의 동일 IAM 자격증명**으로 확인 (단순 정책 JSON 출력만으로 PASS 선언 금지)
- [ ] On-Prem 서비스 이용자·담당자에게 재배포 영향을 사전 공지하고 실행 승인
- [ ] 기존 On-Prem Backend/Frontend Ready, `ecr-pull-secret` 갱신 Job 성공 확인
- [ ] Jenkins `neuroplan-aws-ci` 실행: `BACKEND_CHANGED`, `IMAGE_TAG`, ECR 캐시 hit 또는 Build/Push, `Verify ECR Images` 단계별 로그 기록
- [ ] Jenkins `Update/Validate/Commit GitOps` PASS 및 `main` 새 GitOps 커밋 SHA 기록 (직접 Push됨)
- [ ] ROSA/On-Prem GitOps Backend 태그가 실제로 같아졌는지, ECR 다이제스트가 같은지 검증
- [ ] On-Prem Argo CD `Synced/Healthy`, Backend 신규 Pod `Ready`, 실제 Pod 이미지/다이제스트 확인
- [ ] 희재 담당: `dr-health` 200, Infra VM VIP HTTPS `/` 200, 비인증 `/api/learning/state` 401, TLS 검증 0 재확인
- [ ] 로그인 → 조회 → 저장을 실제 서비스 계정으로 검증
- [ ] Jenkins 빌드 번호·콘솔 로그(비밀정보 제거)·GitOps SHA·Pod/헬스·테스트 시각을 PR 또는 Issue에 첨부

**주의:** `Jenkinsfile.aws`는 Application의 `main`을 체크아웃한다.
최신 커밋과 이전 **성공** 커밋 간 Backend 변경이 없으면
`BACKEND_CHANGED=false`로 GitOps 갱신이 생략될 수 있다.
그 경우 임의 커밋으로 강제하지 않고 별도 Deploy-only 개선 PR을 검토한다.
또한 ECR 단계 성공은 **실제 On-Prem 롤아웃 성공의 증거가 아니다**.

ROSA 환경이 10/12 이전에 없으면 ROSA 쪽 GitOps 태그만 확인한다.
ROSA 신규 Pod 배포·MaxScale DB 연결·로그인/조회/저장은 10/12 별도 검증.

## 중단·회복
- IAM Plan이 권한 1개 생성 외 변경을 보이면 중단
- ECR 조회가 `AccessDenied`면 다른 계정/자격증명/정책 경계(SCP, permission boundary 포함)를 진단
- Jenkins의 GitOps Push 후 On-Prem Auto-Sync가 실패하면 담당자와 복구/롤백 승인 후 진행
- GitOps #12는 **Jenkins로 양쪽 배포 성공 확인 전 Close/Merge하지 않는다**
- **실제 Terraform Apply, Jenkins 실행, Argo CD Sync 및 클러스터 배포는 이 PR로 자동 실행되지 않는다**
