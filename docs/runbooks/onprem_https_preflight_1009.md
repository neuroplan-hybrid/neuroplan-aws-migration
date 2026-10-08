# On-Prem DR HTTPS 경로 사전 구축 및 적용 순서 (T5·T7)

> 상태: **사전 구축 가이드 / 실제 클러스터 적용 승인 아님**
> 최종 정리: 2026-10-09 · 범위: On-Prem Gateway Listener + GitOps HTTPRoute + HTTPS 사전 검증
> 담당: Gateway Listener = 희재, HTTPRoute/GitOps = 예린, 최종 테스트 = 담당자 협업
> 기존 실행 런북: [Gateway 스크립트](../../scripts/setup_onprem_app_listener_1008.sh), [T5](site_dr_rosa_to_onprem_1008.md), [T7 인증서 CA 전환](cert_ca_switch_continuity_1008.md)

## 1. 목적 및 ROSA와의 관계

- `app.neuroplan.cloud`의 **On-Prem HTTPS 수신·라우팅 경로**를 T5 DR 전환 전에 준비한다.
- 이 Gateway/HTTPRoute 구성은 **On-Prem Kubernetes의 작업**으로, ROSA 구축 완료를 기다리지 않고 독립적으로 사전 구성·검증할 수 있다.
- 단, 실제 **T5 ROSA → On-Prem DR 통합 전환**은 ROSA 서비스, Write Fence, 데이터 복제/승격, DNS/HC 등 양쪽 환경의 선행 조건이 충족된 후 진행한다.
- T7 CA 전환 런북의 **A 범위**(`app` HTTPS + 사용자 트랜잭션)는 이 경로의 검증이 필요하다. **B 범위**는 `dr-health` TLS 전용이므로 A 미충족 시 별도로 판정할 수 있고, 사용자 트랜잭션 연속성을 주장하지 않는다.
- 이 문서는 기존 T5/T7 런북을 대체하지 않으며, **Gateway → GitOps 반영 전후의 승인·순서·검증 게이트**만 보충한다.

## 2. 변경 책임 및 구성

| 범위 | 저장소/대상 | 담당 | 책임 |
|---|---|---|---|
| Gateway HTTPS Listener | `neuroplan-aws-migration` PR [#79](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/79) / `application/neuroplan-gateway` | 희재 | `https-public-app` 추가 및 상태 검증 |
| HTTPRoute | `neuroplan-gitops` PR [#11](https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/11) / `overlays/onprem-dr` | 예린 | `app.neuroplan.cloud` hostname, `https-public-app` parentRef |
| TLS Secret | On-Prem `application/neuroplan-cloud-onprem-tls` | 인증서 담당자 | SAN·만료·TLS 키 일치 여부 확인 및 관리 |
| Argo CD | `argocd/neuroplan-onprem-dr` | GitOps 담당 | 자동 동기화 영향, Sync/Health 확인 |

기존 `https` (`app.nplan.local`), `grafana-https`, `https-dr-health` Listener와 기존 `/api` → Backend, `/` → Frontend 경로는 유지한다. Secret 내용·개인 키는 문서, Git, 로그에 저장하지 않는다.

## 3. 사전 실측 (2026-10-08 DevOps VM 조회; 실배포 전 상태)

| 확인 항목 | 관측 결과 |
|---|---|
| Kubernetes context | `kubernetes-admin-neuroplan.local@neuroplan.local` |
| Argo CD Application | `argocd/neuroplan-onprem-dr` |
| Git 추적 | `https://github.com/neuroplan-hybrid/neuroplan-gitops.git` / `main` / `overlays/onprem-dr` |
| Auto-Sync / selfHeal / prune | **ON / true / true** (조회 당시 Synced) |
| 실제 Gateway Listener | `https`, `grafana-https`, `https-dr-health` **3개만 존재** |
| 신규 `https-public-app` | **실제 미적용** (조회 당시) |
| Secret 타입 | `kubernetes.io/tls` |
| 현재 인증서 | Let's Encrypt, 2027-01-04 만료, SAN `app.neuroplan.cloud` 및 `dr-health.neuroplan.cloud` |
| Gateway 스크립트 | GitHub `main`에 병합 완료, DevOps VM에서 `bash -n` 통과 |
| Gateway 서버 Dry-run | **PASS**: 기존 3개 + `https-public-app`(`app.neuroplan.cloud`, 443, TLS Secret) 예상 출력 확인 |
| HTTPRoute PR #11 | 조회 당시 Open, 미병합·미적용 |

**주의:** 위 결과는 해당 시점의 로그·조회 결과이며, 현재 클러스터 상태 또는 실제 TLS 요청 성공을 보장하지 않는다. 적용 직전에 재조회해야 한다.

## 4. 실제 적용 전 조건 (승인 게이트)

1. **작업자·작업 시각·롤백 담당자 합의**: Gateway 변경은 희재님이 담당하고 실제 `--apply` 실행은 별도 승인 후 진행한다.
2. **PR 및 브랜치 확인**: Gateway 스크립트 PR #79가 병합된 버전을 사용한다. GitOps PR #11은 Listener 준비 전 병합하지 않는다.
3. **Argo CD 설정 재확인**: `neuroplan-onprem-dr`이 `main`의 `overlays/onprem-dr`을 추적하며 Auto-Sync **ON**이므로, PR #11 병합은 곧 배포 트리거가 될 수 있다. 임의로 Auto-Sync를 변경하지 않는다.
4. **기존 경로 영향 최소화**: 기존 Listener와 Secret, Gateway 사전 상태를 기록한다. `kubectl apply`로 Gateway 전체를 덮어쓰지 않고 PR #79의 제한된 patch 절차를 사용한다.
5. **실패 시 중단**: 사전 검증 실패, 기존 Listener 이상, 신규 Listener 상태 불량, TLS 실패가 있으면 GitOps PR #11 병합을 보류한다.

### 조회 전용 재확인 (DevOps VM / On-Prem kubectl 컨텍스트)

```bash
kubectl config current-context
kubectl -n argocd get application neuroplan-onprem-dr \
  -o jsonpath='repo={.spec.source.repoURL}{"\n"}revision={.spec.source.targetRevision}{"\n"}path={.spec.source.path}{"\n"}'
kubectl -n application get gateway neuroplan-gateway \
  -o jsonpath='{range .spec.listeners[*]}{.name}{"\t"}{.hostname}{"\t"}{.port}{"\n"}{end}'
kubectl -n application get secret neuroplan-cloud-onprem-tls \
  -o jsonpath='{.type}{"\n"}'
```

## 5. 단계별 적용·검증

### Step A. Gateway Dry-run → 승인 후 적용 (희재 담당)

실행 호스트는 PR #79 기준 **On-Prem cp1(root)**. cp1에는 AWS Migration 저장소가 없으므로 `~/setup_onprem_app_listener_1008.sh` **복사본**을 사용한다. DevOps VM에 가져온 병합본의 SHA-256과 cp1 복사본의 SHA-256이 **일치하는지 확인한 뒤** 실행한다.

```bash
# DevOps VM — PR #79 병합본을 파일로 추출하고 원본 해시 기록 (Git 작업 트리 변경 없음)
git -C ~/neuroplan-aws-migration fetch origin main
git -C ~/neuroplan-aws-migration show origin/main:scripts/setup_onprem_app_listener_1008.sh \
  > /tmp/setup_onprem_app_listener_1008.sh
sha256sum /tmp/setup_onprem_app_listener_1008.sh

# 위 파일을 승인된 경로로 cp1의 /root/setup_onprem_app_listener_1008.sh 에 복사한다.
# cp1(root) — 복사본 해시를 위 DevOps VM 출력과 비교; 불일치 시 중단
sha256sum ~/setup_onprem_app_listener_1008.sh
bash -n ~/setup_onprem_app_listener_1008.sh

# 변경 없음 — Gateway 서버 Dry-run
bash ~/setup_onprem_app_listener_1008.sh gateway

# 아래 명령은 담당자·작업 시간·롤백 승인 후에만 실행
# bash ~/setup_onprem_app_listener_1008.sh gateway --apply
```

기대 Listener: `https-public-app` / `app.neuroplan.cloud` / 443 / HTTPS Terminate / `neuroplan-cloud-onprem-tls`. 기존 Listener 3개는 변경 없이 유지한다.

### Step B. Listener·인증서 사전 검증 (HTTPRoute 적용 전)

**cp1(root)에서 NGF NodePort를 사용한다.** 기본 `VERIFY_IP=192.168.24.100`(VIP)는 cp1·DevOps VM에서 4-Zone 망 분리로 도달할 수 없으므로 그대로 실행하지 않는다. 이 검증은 **NGF NodePort 직접 경로**이며, HAProxy/VIP 경유 최종 확인은 Step D의 Infra VM에서 별도로 수행한다.

```bash
# cp1(root) — Listener 및 SNI/TLS 사전 검증 (NGF NodePort)
VERIFY_IP=192.168.34.41 VERIFY_PORT=30443 \
  bash ~/setup_onprem_app_listener_1008.sh verify
```

- 신규 및 기존 Listener 상태 `Accepted=True`, `Programmed=True`, `ResolvedRefs=True` 확인
- 신규 호스트의 SNI/SAN 일치, 유효한 TLS 연결 및 `ssl_verify_result=0` 확인
- **이 단계에서는 HTTP 404를 라우팅 성공으로 간주하지 않음** (HTTPRoute가 아직 미적용일 수 있음)
- 통과 결과와 실행 시각을 담당자가 기록

### Step C. GitOps PR #11 병합 → Argo CD 반영 확인 (예린 담당)

Step B 통과 및 팀 승인 이후에만 [GitOps PR #11](https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/11)을 병합한다. Auto-Sync ON이므로 **별도 수동 Sync 명령을 무조건 실행하지 않고** Argo CD가 반영했는지 먼저 확인한다.

```bash
kubectl -n argocd get application neuroplan-onprem-dr \
  -o jsonpath='sync={.status.sync.status}{"\n"}health={.status.health.status}{"\n"}revision={.status.sync.revision}{"\n"}'
kubectl -n application get httproute neuroplan-login-mvp -o yaml
```

- hostname `app.neuroplan.cloud`, parentRef `sectionName: https-public-app` 반영 확인
- HTTPRoute parent 조건(`Accepted=True`, `ResolvedRefs=True`) 확인
- 기존 `app.nplan.local` 및 Frontend/Backend 경로 유지 확인

### Step D. 최종 서비스 검증

**① cp1(root): NGF NodePort 직접 경로**에서 PR #79 `verify-route`를 실행한다. `verify`와 마찬가지로 VIP 기본값을 사용하지 않는다.

```bash
VERIFY_IP=192.168.34.41 VERIFY_PORT=30443 \
  bash ~/setup_onprem_app_listener_1008.sh verify-route
```

**② Infra VM(root): 실제 HAProxy/VIP 경유 경로**에서 TLS와 사용자 라우팅을 별도로 검증한다. cp1 NodePort 성공만으로 최종 VIP 경로 성공으로 판정하지 않는다.

```bash
# Infra VM — VIP 직접 지정, 공인 DNS를 전환하지 않음, -k 미사용
curl -sS -o /dev/null -w 'frontend=%{http_code} ssl_verify=%{ssl_verify_result}\n' \
  --max-time 10 --resolve app.neuroplan.cloud:443:192.168.24.100 \
  https://app.neuroplan.cloud/
curl -sS -o /dev/null -w 'backend=%{http_code} ssl_verify=%{ssl_verify_result}\n' \
  --max-time 10 --resolve app.neuroplan.cloud:443:192.168.24.100 \
  https://app.neuroplan.cloud/api/learning/state
```

| URL | 통과 기준 |
|---|---|
| `/` | HTTP **200**, `ssl_verify_result=0` |
| `/api/learning/state` (비인증) | HTTP **401**, `ssl_verify_result=0` |
| 공통 | curl 종료 코드 **0**, 인증서 검증 통과, 기존 호스트 영향 없음 |

HTTP 000/404/502/503, 예상 밖 코드 또는 인증서 오류면 FAIL로 기록하고 다음 시연 단계로 넘어가지 않는다. 인증서 검증을 생략하는 `-k`는 사용하지 않는다.

## 6. 실패 시 처리 및 완료 기준

- **Listener 검증 전 실패**: Step C 병합 보류. Gateway PR #79의 소유 annotation 및 rollback 조건을 담당자와 검토한다. 승인 없이 rollback 명령 실행 금지.
- **HTTPRoute 반영 후 실패**: Argo CD 상태·HTTPRoute 조건·DNS/SNI/Backend 대상 확인, 원인 기록 후 담당자와 조치. Auto-Sync 환경에서 수동 개체 변경만으로 롤백했다고 판단하지 않는다.
- **완료 선언 조건**: Listener 사전검증(cp1 NodePort) + GitOps Sync/HTTPRoute Accepted·ResolvedRefs + cp1 `verify-route`(NodePort) + Infra VM VIP HTTPS Frontend 200/Backend 401·TLS 검증 결과가 **각 경로별 실측 로그로 확인**된 경우에만 완료 처리.
- **T5**: ROSA·DB·Write Fence 등 통합 선행 조건이 준비된 뒤 별도 런북으로 수행.
- **T7**: 기존 [CA 전환 런북](cert_ca_switch_continuity_1008.md)의 A/B 범위 판정에 따라 실시. B 결과를 사용자 서비스 연속성 성공으로 표현하지 않는다.

## 7. 체크리스트 / 기록 (미수행 항목은 체크하지 않음)

- [x] PR #79 병합 (2026-10-08 확인)
- [x] TLS Secret 타입·SAN 확인 (2026-10-08 조회)
- [x] Gateway 스크립트 Bash 문법 검사 (DevOps VM)
- [x] Gateway 서버 Dry-run 성공 (DevOps VM)
- [x] On-Prem Argo CD Auto-Sync ON, `main` 추적 확인 (2026-10-08 조회)
- [ ] 희재님 Gateway `--apply` 승인 및 실제 적용
- [ ] cp1 복사본 스크립트 SHA-256 일치 확인
- [ ] cp1 NGF NodePort `verify` Listener·TLS 실측 PASS
- [ ] GitOps PR #11 Merge
- [ ] Argo CD Sync·HTTPRoute Accepted/ResolvedRefs 확인
- [ ] cp1 NGF NodePort `verify-route` 실측 PASS
- [ ] Infra VM에서 VIP 직접 접속·HTTP 200/401·TLS 실측 PASS
- [ ] 테스트 로그·스크린샷·작업 시각 및 담당자 기록

| 실행 일시 | 단계 | 실행 위치·담당자 | PASS/FAIL | 증적 링크/비고 |
|---|---|---|---|---|
| 미기록 | Gateway `--apply` | cp1 / 희재 | 미실행 | |
| 미기록 | Listener `verify` (NodePort) | cp1 / 희재 | 미실행 | |
| 미기록 | PR #11/Argo CD | On-Prem / 예린 | 미실행 | |
| 미기록 | `verify-route` (NodePort) | cp1 / 희재 | 미실행 | |
| 미기록 | HTTPS 최종검증 (VIP) | Infra VM | 미실행 | |

## 8. 관련 자료

- [AWS Migration PR #79 — Gateway HTTPS Listener](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/79)
- [GitOps PR #11 — On-Prem public HTTPRoute](https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/11)
- [GitOps PR #10 — ROSA Write Fence 기본값](https://github.com/neuroplan-hybrid/neuroplan-gitops/pull/10)
- [T5 런북](site_dr_rosa_to_onprem_1008.md)
- [T7 인증서 CA 전환 런북](cert_ca_switch_continuity_1008.md)
