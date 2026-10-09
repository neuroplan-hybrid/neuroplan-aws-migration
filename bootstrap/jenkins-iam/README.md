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

## Terraform 적용 완료 이력 (2026-10-09)

> **적용 완료 — 재실행 지시가 아님.** 본 PR의 IAM 정책은 PR Merge 전에 승인된 실증 과정에서 이미 Terraform Apply되었다. Merge는 소스 이력을 실제 AWS State와 일치시키며, 정책을 다시 생성하지 않는다.

- S3 Backend: `bootstrap/jenkins-iam/terraform.tfstate` (별도 State)
- `terraform init`, `fmt -check`, `validate` 성공
- Plan: **1 to add, 0 to change, 0 to destroy**
- Apply: **1 added, 0 changed, 0 destroyed**
- 적용 리소스: `aws_iam_user_policy.jenkins_ecr_describe_images`
- 이후 Jenkins ECR 조회, GitOps Push, On-Prem Argo CD 배포 실증 완료 (PR #85 본문 참조)

향후 재확인이 필요한 경우 지정 실행자가 AWS 계정·기존 State를 확인한 뒤 읽기 전용 `terraform plan`으로 드리프트 여부를 검토한다. **기존 적용 이력을 다시 재현하기 위해 `terraform apply`를 반복하지 않는다.** 예상하지 못한 변경이 보이면 중단하고 별도 승인받는다. `*.tfplan` 및 State 파일은 커밋하지 않는다.

## Jenkins → GitOps → On-Prem 실측 게이트 (2026-10-09 완료 이력)

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

**검증 기록:** Jenkins ECR 조회·Frontend/Backend 단독 SCM 자동 배포·GitOps Push·On-Prem Pod 2/2 Ready는 PR #85 본문에 실측 PASS로 기록되었다. 아래 체크리스트는 재현용 절차이며 미체크가 완료된 검증을 부정하는 것은 아니다. `dr-health` 200은 별도 외부 DR NLB IP `--resolve` 경로에서 10/9 12:19 확인되었으며, 사용자 기능의 최종 `e5d288f` 재검증은 별도 증적이 필요하다.

## 중단·회복
- IAM Plan이 권한 1개 생성 외 변경을 보이면 중단
- ECR 조회가 `AccessDenied`면 다른 계정/자격증명/정책 경계(SCP, permission boundary 포함)를 진단
- Jenkins의 GitOps Push 후 On-Prem Auto-Sync가 실패하면 담당자와 복구/롤백 승인 후 진행
- GitOps [#12](https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/12)는 최신 Backend 태그 `e5d288f`가 `main`에 반영되어 **2026-10-09 Merge 없이 Close 완료**. 재병합하지 않는다.
- **실제 Terraform Apply, Jenkins 실행, Argo CD Sync 및 클러스터 배포는 이 PR로 자동 실행되지 않는다**
