# Route 53 활성화·가중치 런북 — off → 실서비스 ROSA 1 / 온프렘 0 → 운영 (1013, #107 리뷰 반영)

> 담당 **희재** (실행 주체: Terraform apply = 예린, AWS CLI 조회 = Infra VM root / IAM user heejae) · 리전 ap-northeast-2 (Route 53은 글로벌)
> 기준: #33(B안 가중치 단계), #49(off validation), #100(LB DNS·weighted 전환), T5 런북 `site_dr_rosa_to_onprem_1008.md`, #107 리뷰(예린·정현 1013)
> 비밀번호·계정 ID는 적지 않는다. 각 단계는 **tfvars PR → Plan-only 확인 → 승인 → apply → 측정** 순서
> 이 런북은 실행 절차 문서다. 각 단계의 Route 53 전환·Terraform Apply는 별도 팀 승인 후 실행

## 1. 팀 결정 (1013, #107 리뷰) — 쓰기 안전 조건

- Cutover 후 온프렘 DB는 RDS의 **읽기 전용 Replica** → 온프렘으로 간 요청은 로그인 세션 생성·저장이 실패한다
- 따라서 **공개 서비스(`app.neuroplan.cloud`)에서 온프렘 가중치 > 0 금지** (0/100, 10/90, 50/50 모두). 실서비스 활성화는 **처음부터 ROSA 1 / 온프렘 0**
- 활성화 조건 (모두 충족):
  1. DB Cutover 완료, Cutover 동안 Route 53 **off 유지** (정현 #100)
  2. 정현: ROSA → RDS **쓰기·조회 검증 완료** 공유
  3. ROSA 쪽 HC 대상 `primary-health` `/actuator/health/routing` = 200 (발표증적 3.3 명령)
  4. 예린 Plan이 2장 기대값과 같음
- weight 0은 "절대 응답 안 함"이 아님: weight > 0 레코드가 **모두 unhealthy**면 weight 0 쪽(여기서는 온프렘)이 응답 → ROSA 장애 시 온프렘으로 넘어가는 것이 T5 설계. 이때 온프렘 쓰기 재개는 T5 런북(정현 판단)으로만
- 반대로 T5 8번(ROSA 0 / 온프렘 1 고정) 이후에는 온프렘이 모두 unhealthy면 ROSA(weight 0)가 응답 후보 → **ROSA 쓰기 차단 유지**가 T5 전제 (#108 예린 리뷰)

## 2. 단계와 판정 한눈에

| 단계 | tfvars (rosa / onprem) | Plan 기대값 | 측정 | PASS |
|---|---|---|---|---|
| **A 활성화 (기본)** | `rosa-on` **1 / 0** (#100) | `module.edge` **6 add** / 0 / 0 | probe 5분 + `weights 100` | HC 2개 Healthy, 권한 DNS = rosa 100%, app 200 |
| S3 운영 | `operation` 1 / 0 (#100) | Route 53 **변경 0** (rosa-on과 같은 값), 나머지는 operation 단계 전환 내용 | probe 5분 + `weights 100` | 권한 DNS = rosa 100% |
| (T5) | `operation` 0 / 1 고정 (#108) | weight 2 change + HC inverted 원복 | T5 런북 | T5 런북 |
| (선택) S0·S1·S2 | 0/100 · 10/90 · 50/50 | `app_weighted` 2 change (weight만) | 5장 **격리 조건에서만** | 권한 DNS ROSA 비율 95% 구간에 목표값 포함 |

- `route53_routing_mode`를 다시 `off`로 돌리면 레코드·HC가 삭제됨 → 단계 사이 원복은 **가중치만** 되돌린다
- 계획 vs 실제: 계획(#33·#49)은 0/100 → 10/90 → 50/50 → 1/0 점진 전환. 실제는 DNS 활성화가 Cutover 후로 밀려(1013 #100·#93) 온프렘이 읽기 전용이 되므로 **1/0으로 바로 활성화**, 가중치 분산은 선택 측정으로 축소

## 3. 공통 준비 (단계마다)

```bash
# Infra VM (root) — ROSA LB·DR NLB DNS (probe 입력값)
DR_NLB_DNS="$(aws elbv2 describe-load-balancers --region ap-northeast-2 --names neuroplan-dr-nlb --query 'LoadBalancers[0].DNSName' --output text)"
ROSA_LB_DNS="$(aws elbv2 describe-load-balancers --region ap-northeast-2 --query "LoadBalancers[?starts_with(DNSName,'af7cae78')].DNSName | [0]" --output text)"
printf 'export DR_NLB_DNS=%q\nexport ROSA_LB_DNS=%q\n' "$DR_NLB_DNS" "$ROSA_LB_DNS" | tee ~/r53_env.sh
```
```bash
# DevOps VM (heejae)
scp root@192.168.14.62:~/r53_env.sh ~/ && source ~/r53_env.sh
cd ~/neuroplan-aws-migration && git switch main && git pull --ff-only
```
- ROSA LB 이름(`af7cae78…`)은 10/13 `describe-load-balancers` + 태그 `kubernetes.io/service-name=openshift-ingress/router-default`로 확인한 값. ROSA를 다시 만들면 바뀜

## 4. A — 활성화 (#100, ROSA 1 / 온프렘 0)

1. 1장 활성화 조건 1~3 확인 → #100 Merge → 예린 `rosa-on` Plan: **`module.edge` 6 add / 0 / 0만** (헬스체크 2, `primary-health`·`dr-health` A 2, `app` weighted 2). 그 외 변경이 있으면 중단
   - 같은 시점에 main에 #103(AMG)이 있고 아직 Apply 전이면 AMG 7 add가 함께 나옴 → 13 add로 설명 가능해야 함 (그 외 0)
   - `app_weighted["rosa"]` weight = 1, `["onprem"]` weight = 0인지 Plan에서 확인 (0/100이면 중단)
2. apply 후 확인 (Infra VM root):
```bash
for f in primary-health dr-health; do
  id="$(aws route53 list-health-checks --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='${f}.neuroplan.cloud'].Id | [0]" --output text)"
  echo "== $f $id"; aws route53 get-health-check-status --health-check-id "$id" \
    --query 'HealthCheckObservations[].StatusReport.Status' --output text | tr '\t' '\n' | cut -c1-30 | sort | uniq -c
done
NS="$(dig +short NS neuroplan.cloud @8.8.8.8 | head -1)"; for h in app primary-health dr-health; do echo "$h: $(dig +short $h.neuroplan.cloud @$NS | paste -sd' ')"; done
```
   - 기대: 체커 대부분 `Success: HTTP Status Code 200` / `app` = **ROSA NLB IP** / `primary-health` = ROSA NLB IP / `dr-health` = DR NLB IP
   - `app`이 DR NLB IP로 나오면 ROSA HC가 unhealthy라는 뜻 → 온프렘(읽기 전용)으로 가고 있음 → 즉시 7장
3. 측정 (DevOps VM heejae): `bash scripts/probe_1006.sh run 300` → `bash scripts/probe_1006.sh weights <csv> 100`
4. 정현: ROSA 경유 로그인·저장 1회 확인
5. 발표증적 4.1 캡처: 2번 출력 + `weights` 결과

## 5. (선택) S0·S1·S2 — 가중치 분산 측정, 격리 조건에서만

Cutover 후에는 **아래 조건을 모두 만족할 때만**, 아니면 생략 (기본 = 생략). 공개 `app` 레코드는 사용자 유입을 기술적으로 막을 수 없으므로 조건 ①이 핵심
1. 점검 시간으로 공지하고 실사용자 없음 확인 (시연 계정만), 측정은 최대 30분
2. 측정은 probe(`/`, health)만 — **로그인·저장·k6 금지**
3. 정현: 온프렘 DB 읽기 전용(Replica) 상태 확인 — 온프렘 경로의 쓰기는 반드시 실패해야 하며 데이터가 갈라지면 안 됨
4. 측정 직후 **1/0 복귀 PR → Plan 2 change → apply** 를 미리 만들어 두고 바로 실행
5. 팀 승인 (#107 리뷰: S0~S2는 사용자 유입을 차단한 조회/probe 검증으로 한정)

```bash
# DevOps VM (heejae) — 10/90 예시 (0/100·50/50은 숫자만 변경)
git switch -c feature/route53-weight-10-90-$(date +%m%d)
sed -i -E 's/^rosa_weight( *)= *[0-9]+/rosa_weight\1= 10/; s/^onprem_weight( *)= *[0-9]+/onprem_weight\1= 90/' envs/prod/rosa-on.tfvars
git diff                                            # rosa-on.tfvars 2줄만 바뀌어야 함
(cd envs/prod && terraform fmt -check -diff)        # fmt_exit 0
git commit -am "feat(edge): Route 53 weighted ROSA 10 / 온프렘 90 (격리 측정)" && git push -u origin HEAD
```
- Plan 기대값: `module.edge.aws_route53_record.app_weighted["rosa"]`·`["onprem"]` **2 change (weight만)**, 그 외 0
- 측정: probe `run 300` → `weights <csv> 10` (50/50은 `50`, 0/100은 `0`). 권한 DNS 표본 300개면 10%의 95% 구간은 대략 ±3.4%p
- `app 실제 연결(참고)` 비율은 Resolver 캐시(Alias TTL) 때문에 덜 고르게 나오는 것이 정상 → 판정은 권한 DNS 기준
- 온프렘 쪽 저장 실패는 설계상 정상(읽기 전용 Replica)임을 기록

## 6. S3 — 운영 1/0

- `operation.tfvars`는 #100에서 이미 `weighted` + LB DNS + 1/0 → **별도 PR 없음**. Cutover 단계에서 예린이 `operation` Plan·apply할 때 함께 반영
- Plan 확인: A에서 이미 1/0이면 Route 53은 **변경 0** (5장 측정 후 복귀를 안 했다면 weight 2 change), 그 외는 operation 단계 전환 내용(예린 설명)과 일치해야 함
- ⚠ 1013 main에 #108(operation 0/1)이 조기 Merge됨 → **Revert가 #100보다 먼저 Merge되어야 함**. Plan에서 operation `rosa` weight가 0이면 중단
- 측정: probe `run 300` → `weights <csv> 100` → 권한 DNS rosa 100%
- 이후 T5 6장 리허설(`--inverted` → 권한 DNS 전환 → `--no-inverted` 원복)로 **T_inject → T_dns 실측** → T5 2장 설명 값 확정

## 7. 중단·원복

| 상황 | 조치 |
|---|---|
| Plan에 기대값 외 변경, 또는 weight가 1/0이 아님 | apply 안 함, 원인 확인 (예: Subnet 태그·IAM — #101 이후 0이어야 함, #108 Revert 여부) |
| A 후 HC Unhealthy / `app`이 DR NLB IP | `/actuator/health/routing` 직접 확인 (발표증적 3.3 명령). 온프렘은 읽기 전용이므로 **쓰기 실패를 정현에게 즉시 공유**, ROSA 원인 해결 우선. 라우팅은 off로 돌리지 않음(레코드 삭제됨). 장기화되면 T5 판단(정현·예린) |
| 5장 측정 중 사용자 유입·온프렘 쓰기 시도 발견 | 즉시 1/0 복귀 PR apply, 측정 중단 |
| 전체 철회 | `route53_routing_mode = "off"` PR → Plan 6 destroy (HC·레코드) — 팀 승인 후 |

## 8. 비용
- 헬스체크 2개: AWS 리소스 대상은 계정당 50개까지 무료, ELB 대상은 미과금 → 사실상 0 / Hosted Zone 월 $0.5 (기존) / 질의 소액
