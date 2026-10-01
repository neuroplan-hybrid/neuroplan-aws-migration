# OCP Pre-flight 검증 결과 (2026-10-01)

## 1. 목적

ROSA HCP 본 구축 전에 강사 제공 OCP 환경에서 OpenShift 공통 계층과 GitOps 배포 흐름을 사전 검증한다.

이번 검증은 ROSA/AWS 종속 기능을 대체하기 위한 것이 아니라, ROSA 생성 전에 애플리케이션 배포 구조와 OpenShift 공통 동작을 확인해 본 구축 시 디버깅 범위를 줄이는 데 목적이 있다.

---

## 2. 검증 환경

- OCP: 4.20.0
- Kubernetes: v1.33.5
- 구성: Master 3대 + Worker 2대
- Namespace: `team4-ocp-lab`
- GitOps: 기존 공용 OpenShift GitOps / Argo CD 사용
- Application: `team4-ocp-preflight`
- 애플리케이션 검증용 이미지: `registry.k8s.io/e2e-test-images/agnhost`

공용 OCP 환경에서 실제 ECR/RDS/운영 Secret을 사용하지 않고, 배포 및 GitOps 동작 검증에 필요한 최소 구성만 적용했다.

---

## 3. 검증 결과

### 3.1 Deployment / Pod

- Frontend 3 Replica 정상 기동 확인
- Backend 3 Replica 정상 기동 확인
- Pod 삭제 후 Deployment가 자동으로 대체 Pod를 생성하는 Self-Healing 확인
- image tag 변경 시 신규 ReplicaSet 생성 및 Rolling Update 확인

최종 상태:

```text
neuroplan-frontend   3/3   3   3
neuroplan-backend    3/3   3   3
```

### 3.2 Route / Service / EndpointSlice

Frontend Route와 Backend Route를 통해 외부 HTTPS 요청이 정상적으로 각 Service에 전달되는 것을 확인했다.

Frontend는 반복 요청 시 3개 Pod가 모두 응답하는 것을 확인했고, Backend는 EndpointSlice에 3개 Pod IP가 모두 등록된 것을 확인했다.

```text
Route
  -> Service
  -> EndpointSlice
  -> Pod Replica
```

Backend EndpointSlice 확인 결과:

```text
10.131.0.251
10.128.2.87
10.131.0.252
```

따라서 Route -> Service -> 다중 Pod 경로가 정상 동작함을 확인했다.

### 3.3 Argo CD Auto Sync

GitOps 전용 실습 브랜치의 변경사항을 Argo CD Application이 감지하고 OCP에 자동 반영하는 것을 확인했다.

```text
Git 변경
 -> Argo CD Sync
 -> Kustomize
 -> Deployment
 -> Service / Route
```

최종 Application 상태:

```text
Synced
Healthy
```

### 3.4 Argo CD selfHeal

Git의 desired replica는 3인 상태에서 Deployment replica를 수동으로 1로 변경했다.

Argo CD가 drift를 감지한 뒤 Git 기준인 3 Replica로 자동 복구하는 것을 확인했다.

```text
수동 변경: 3 -> 1
Argo CD selfHeal
Git 기준 복구: 1 -> 3
```

### 3.5 Argo CD prune

Git에 임시 ConfigMap `team4-prune-test`를 추가한 뒤 Argo CD가 OCP에 생성하는 것을 확인했다.

이후 Git에서 해당 리소스를 제거했고 `prune: true`에 따라 OCP에서도 자동 삭제되는 것을 확인했다.

삭제 후 결과:

```text
Error from server (NotFound): configmaps "team4-prune-test" not found
```

Application은 다시 `Synced / Healthy` 상태로 복귀했다.

### 3.6 Image Tag Rollout / 실패 배포 / Git Rollback

Frontend image tag를 정상 tag로 변경했을 때 신규 ReplicaSet과 Rolling Update가 정상 수행되는 것을 확인했다.

이후 존재하지 않는 테스트 image tag를 의도적으로 적용해 아래 상태를 확인했다.

```text
ErrImagePull
ImagePullBackOff
```

이때 기존 정상 Pod는 유지되어 서비스가 계속 동작했다.

Git에서 정상 image tag로 rollback한 뒤 Argo CD가 자동 Sync하여 실패 Pod를 정리하고 정상 상태로 복구하는 것을 확인했다.

최종 결과:

```text
Application: Synced / Healthy
Frontend: 3/3
Backend: 3/3
```

### 3.7 SCC / Rootless

GitOps로 배포된 Frontend Pod에서 OpenShift SCC와 실제 UID를 확인했다.

```text
SCC: restricted-v2
uid=1000750000(1000750000) gid=0(root) groups=0(root),1000750000
```

UID가 0이 아닌 OpenShift 할당 non-root UID로 실행되고 있어 rootless 실행이 정상임을 확인했다.

### 3.8 HPA / PVC 기본 동작

OCP 기본 실습에서 아래 항목도 확인했다.

- HPA: CPU 부하 발생 시 3 -> 6 Replica scale-out 후 3으로 scale-in
- PVC: `managed-nfs-storage` 기반 RWX PVC Bound 확인
- Pod 교체 후에도 동일 PVC 데이터 유지 확인

---

## 4. OCP 환경에서 확인된 제약

공용 OCP의 제한된 Worker 자원 때문에 pre-flight 과정에서 아래 현상을 확인했다.

- topology spread 조건과 Master taint 조합으로 신규 Pod가 Pending 될 수 있음
- Backend rollout 중 `maxSurge=1`이면 임시 추가 Pod가 필요한 시점에 Worker memory 부족 발생 가능
- 실습용 agnhost에 한해 Backend memory request 축소 및 rollout 전략 조정이 필요했음

이 조정은 공용 OCP 실습 환경에서 테스트를 성립시키기 위한 임시 보정이며, 실제 ROSA manifest 기준으로 반영하지 않는다.

---

## 5. CD / GitOps 파일 반영 판단

이번 Pre-flight 결과로 인해 현재 `base` 또는 `overlays/rosa`에 즉시 반영해야 할 수정사항은 발견되지 않았다.

따라서 다음 항목은 유지한다.

- 기존 Kubernetes/OpenShift base 유지
- 기존 ROSA overlay 유지
- ROSA용 resource / rollout / topology 정책은 실제 ROSA Worker 사양과 배포 결과를 기준으로 최종 판단

OCP에서 사용한 임시 `ocp-preflight` overlay와 실습 브랜치는 검증 완료 후 삭제했다.

---

## 6. CI 검증 범위

이번 OCP Pre-flight에서는 CI Build/ECR Push를 재검증하지 않았다.

기존 2차 프로젝트에서 애플리케이션 CI의 image Build 및 ECR Push가 이미 정상 동작하는 것을 확인했기 때문에, OCP에서는 중복 CI 검증 대신 CD/GitOps 및 OpenShift 런타임 검증에 집중했다.

따라서 현재 검증 구분은 다음과 같다.

```text
CI
Application Source
 -> Image Build
 -> ECR Push
기존 검증 완료

CD / GitOps
GitOps 변경
 -> Argo CD
 -> Deployment
 -> Service / Route
이번 OCP Pre-flight 검증 완료
```

---

## 7. ROSA에서 최종 검증할 항목

다음 항목은 OCP 결과로 대체하지 않고 ROSA 실제 환경에서 최종 검증한다.

- ROSA HCP / MachinePool
- AWS IAM / STS / OIDC
- ECR 실제 Image Pull
- 실제 NeuroPlan Frontend 화면
- Backend API
- ConfigMap / 운영 Secret
- RDS MariaDB 연결
- 로그인 및 DB Read/Write
- 외부 LLM API 호출
- ROSA Ingress / Route
- Site-to-Site VPN
- On-Prem <-> RDS GTID 복제 및 Cutover
- Route 53 Weighted 전환
- 실제 RTO / RPO

---

## 8. 최종 결론

**OCP Pre-flight 완료.**

OpenShift 공통 계층에서 Deployment, Service, Route, 다중 Replica, Rolling Update, 실패 이미지 rollback, Argo CD Auto Sync/selfHeal/prune, SCC `restricted-v2`, non-root 실행을 정상 확인했다.

현재 `base` 및 `overlays/rosa`에 선제 수정이 필요한 문제는 발견되지 않았으며, OCP 전용 임시 설정은 ROSA에 반영하지 않는다.

이후 ROSA에서는 AWS 종속 항목과 실제 NeuroPlan 애플리케이션 통합 검증에 집중한다.
