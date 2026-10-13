# Route 53 단계 전환 런북 — off → weighted 0/100 → (10/90 → 50/50) → 운영 1/0 (1013)

> 담당 **희재** (실행 주체: Terraform apply = 예린, AWS CLI 조회 = Infra VM root / IAM user heejae) · 리전 ap-northeast-2 (Route 53은 글로벌)
> 기준: #33(B안 가중치 단계), #49(off validation), #100(LB DNS·weighted 전환, Plan 6 add PASS), T5 런북 `site_dr_rosa_to_onprem_1008.md`
> 비밀번호·계정 ID는 적지 않는다. 각 단계는 **tfvars PR → Plan-only 확인 → 승인 → apply → 측정** 순서

## 1. 단계와 판정 한눈에

| 단계 | tfvars (rosa / onprem) | Plan 기대값 | 측정 | PASS |
|---|---|---|---|---|
| S0 켜기 | `rosa-on` 0 / 100 (#100) | `module.edge` **6 add** / 0 / 0 | probe 5분 + `weights 0` | HC 2개 Healthy, 권한 DNS = onprem 100%, app 200 |
| S1 | `rosa-on` 10 / 90 | `app_weighted` **2 change** (weight만) | probe 5분 + `weights 10` | 권한 DNS ROSA 비율 95% 구간에 10 포함 |
| S2 | `rosa-on` 50 / 50 | `app_weighted` **2 change** | probe 5분 + `weights 50` | 95% 구간에 50 포함 |
| S3 운영 | `operation` 1 / 0 | 단계 전환 Plan (예린) — Route 53은 weight 2 change | probe 5분 + `weights 100` | 권한 DNS = rosa 100% |
| (T5) | `operation` 0 / 1 고정 | weight 2 change + HC inverted 원복 | T5 런북 | T5 런북 |

- weight 0 레코드는 "절대 응답 안 함"이 아님: weight > 0 레코드가 **모두 unhealthy**면 weight 0 쪽이 응답 (active-passive 원리, T5)
- `route53_routing_mode`를 다시 `off`로 돌리면 레코드·HC가 삭제됨 → 단계 사이 원복은 **가중치만** 되돌린다

## 2. ⚠ Cutover와의 순서 (팀 결정 사항)

| 시점 | DB | S1·S2(트래픽 분산) 가능 범위 |
|---|---|---|
| Cutover **전** | 두 사이트 모두 온프렘 MaxScale(같은 Writer)에 씀 | 조회·로그인·**저장** 모두 측정 가능 (k6 포함) |
| Cutover **후** | ROSA → RDS Writer / 온프렘 DB = RDS의 **읽기 전용 Replica** | 온프렘으로 간 사용자의 **저장 실패** → S1·S2는 **조회 경로(probe)만**, k6 저장 금지 · 또는 S1·S2 생략하고 S0 → S3 |

- 10/13 #100·#93 합의: DNS 활성화는 **DB Cutover·검증 후** → 기본 경로는 **S0 → S3** (S1·S2는 조회 전용 측정으로 할지 팀 확인)
- Cutover 동안은 Route 53 **off 유지** (정현 #100 댓글)

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

## 4. S0 — 켜기 (#100, 0/100)

1. #100 Merge → 예린 `rosa-on` Plan: **`module.edge` 6 add / 0 / 0만** (헬스체크 2, `primary-health`·`dr-health` A 2, `app` weighted 2). 그 외 변경이 있으면 중단
   - 같은 시점에 main에 #103(AMG)이 있으면 AMG 7 add가 함께 나옴 → 13 add로 설명 가능해야 함 (그 외 0)
2. apply 후 확인 (Infra VM root):
```bash
for f in primary-health dr-health; do
  id="$(aws route53 list-health-checks --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='${f}.neuroplan.cloud'].Id | [0]" --output text)"
  echo "== $f $id"; aws route53 get-health-check-status --health-check-id "$id" \
    --query 'HealthCheckObservations[].StatusReport.Status' --output text | tr '\t' '\n' | cut -c1-30 | sort | uniq -c
done
NS="$(dig +short NS neuroplan.cloud @8.8.8.8 | head -1)"; for h in app primary-health dr-health; do echo "$h: $(dig +short $h.neuroplan.cloud @$NS | paste -sd' ')"; done
```
   - 기대: 체커 대부분 `Success: HTTP Status Code 200` / `app` = DR NLB IP(0/100이므로 onprem) / `primary-health` = ROSA NLB IP / `dr-health` = DR NLB IP
3. 측정 (DevOps VM heejae): `bash scripts/probe_1006.sh run 300` → `bash scripts/probe_1006.sh weights <csv> 0`
4. 발표증적 4.1 캡처: 2번 출력 + `weights` 결과

## 5. S1·S2 — 가중치 변경 (Cutover 전이거나, 후라면 조회 전용)

```bash
# DevOps VM (heejae) — 10/90 예시 (50/50은 숫자만 변경)
git switch -c feature/route53-weight-10-90-$(date +%m%d)
sed -i -E 's/^rosa_weight( *)= *[0-9]+/rosa_weight\1= 10/; s/^onprem_weight( *)= *[0-9]+/onprem_weight\1= 90/' envs/prod/rosa-on.tfvars
git diff                                            # rosa-on.tfvars 2줄만 바뀌어야 함
(cd envs/prod && terraform fmt -check -diff)        # fmt_exit 0
git commit -am "feat(edge): Route 53 weighted ROSA 10 / 온프렘 90" && git push -u origin HEAD
```
- Plan 기대값: `module.edge.aws_route53_record.app_weighted["rosa"]`·`["onprem"]` **2 change (weight만)**, 그 외 0
- 측정: probe `run 300` → `weights <csv> 10` (50/50은 `50`). 권한 DNS 표본 300개면 10%의 95% 구간은 대략 ±3.4%p
- `app 실제 연결(참고)` 비율은 Resolver 캐시(Alias TTL) 때문에 덜 고르게 나오는 것이 정상 → 판정은 권한 DNS 기준
- Cutover 후라면: k6 저장 시나리오 금지, probe(`/`, health)만. 온프렘 쪽 저장 실패는 설계상 정상(읽기 전용 Replica)임을 기록

## 6. S3 — 운영 1/0

- `operation.tfvars`는 #100에서 이미 `weighted` + LB DNS + 1/0 → **별도 PR 없음**. Cutover 단계에서 예린이 `operation` Plan·apply할 때 함께 반영
- Plan 확인: Route 53은 `app_weighted` 2 change(weight), 그 외는 operation 단계 전환 내용(예린 설명)과 일치해야 함
- 측정: probe `run 300` → `weights <csv> 100` → 권한 DNS rosa 100%
- 이후 T5 6장 리허설(`--inverted` → 권한 DNS 전환 → `--no-inverted` 원복)로 **T_inject → T_dns 실측** → T5 2장 설명 값 확정

## 7. 중단·원복

| 상황 | 조치 |
|---|---|
| Plan에 기대값 외 변경 | apply 안 함, 원인 확인 (예: Subnet 태그·IAM — #101 이후 0이어야 함) |
| S0 후 HC Unhealthy | `/actuator/health/routing` 직접 확인 (발표증적 3.3 명령), 원인 해결 전 다음 단계 금지. 라우팅은 off로 돌리지 않음(레코드 삭제됨) |
| S1·S2에서 ROSA 쪽 오류 증가 | 직전 단계 가중치로 되돌리는 tfvars PR (예: 10/90 → 0/100) → Plan 2 change → apply |
| 전체 철회 | `route53_routing_mode = "off"` PR → Plan 6 destroy (HC·레코드) — 팀 승인 후 |

## 8. 비용
- 헬스체크 2개: AWS 리소스 대상은 계정당 50개까지 무료, ELB 대상은 미과금 → 사실상 0 / Hosted Zone 월 $0.5 (기존) / 질의 소액
