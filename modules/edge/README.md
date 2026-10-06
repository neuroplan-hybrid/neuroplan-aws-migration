# edge module

DR NLB와 Route 53(GSLB) 레코드·헬스체크를 만드는 희재 담당 모듈이다. ROSA Ingress LB와 Hosted Zone은 만들지 않고 입력값으로만 받는다.

```
사용자 / Route 53 헬스체커
        │  app.<도메인> (Weighted: 이관 비율 조정 → 운영 ROSA 1 / 온프렘 0)
        ├──────────────▶ ROSA Ingress LB (ROSA 관리) → Router → Route → App
        └──────────────▶ DR NLB (이 모듈, Public 3AZ, TCP 443)
                              │ IP target 192.168.24.100:443, availability_zone = all
                              ▼
                         VGW → S2S VPN → Infra VM(aws-to-dmz) → VIP → HAProxy → NGF → App
```

## 리소스

| 조건 | 리소스 |
|---|---|
| `enable_dr_nlb` | SG(인바운드 443 ← `dr_nlb_ingress_cidrs`, 아웃바운드 → VIP/32:443), NLB(internet-facing), Target Group(TCP, IP, TCP 헬스체크), VIP 타깃, Listener 443 |
| `enable_route53_routing` + `enable_dr_nlb` | 헬스체크 `dr-health`(HTTPS, SNI, `/actuator/health/routing`), `dr-health.<도메인>` Alias → DR NLB, app 레코드 `onprem` |
| `enable_route53_routing` + `primary_lb_dns_name` | 헬스체크 `primary-health`, `primary-health.<도메인>` Alias → ROSA LB, app 레코드 `rosa` |
| `app_routing_policy` | `weighted`: `app_weighted[rosa/onprem]` (사용) / `failover`: `app_failover[rosa=PRIMARY, onprem=SECONDARY]` (모듈 호환용, 사용 계획 없음) / `none`: app 레코드 없음 |

- 도메인이 없어도 DR NLB는 만들 수 있다 (`enable_route53_routing = false`). PoC는 NLB DNS로 확인한다.
- 헬스체크 대상 이름(`primary-health`, `dr-health`)은 app 레코드와 분리한다 (시나리오 4.8).
- NLB 타깃 헬스체크는 TCP, Route 53 헬스체크는 HTTPS + FQDN + SNI (NLB HTTPS 헬스체크는 Host/SNI 지정 불가).
- VPN 너머 IP 타깃은 Client IP 보존이 안 되므로 `preserve_client_ip = false`. 온프렘에는 NLB 사설 IP(Public 서브넷)가 출발지로 보인다.

## 라우팅 단계 (B안 확정: Weighted 기반 active-passive)

운영 단계도 Failover 레코드로 바꾸지 않고 **Weighted를 유지**한다 (#28 리뷰, 예린 제안 · 정현 · 희재 동의, 1001).

| 단계 | envs/prod `route53_routing_mode` | 가중치 (ROSA / 온프렘) | 헬스체크 |
|---|---|---|---|
| 초기 | `off` | — (헬스체크·레코드 없음) | — |
| 전환 검증 | `weighted` | 0 / 100 → 10 / 90 → 50 / 50 등 단계적 조정 | 두 레코드 모두 개별 연결 |
| 운영 기본 | `weighted` | **1 / 0** (active-passive) | 두 레코드 모두 개별 연결 |

- 운영 단계 동작: Route 53은 가중치가 0보다 큰 레코드 중 healthy인 것만 응답하고, **가중치 0보다 큰 레코드가 모두 unhealthy일 때만 가중치 0 레코드로 응답**한다 → 평소 ROSA만 응답, ROSA 헬스체크 실패 시 온프렘(DR NLB)으로 전환
- 그래서 ROSA·온프렘 레코드 모두 `primary-health`·`dr-health` 헬스체크를 각각 연결한다 (이 모듈은 사이트가 있으면 자동 연결)
- Failover 레코드로 바꾸지 않는 이유: Route 53은 같은 이름·타입에 Weighted와 Failover 레코드를 함께 둘 수 없다. 바꾸려면 `none`을 거쳐 apply를 두 번 해야 하고, 그 사이(1~2분) `app` 레코드가 없어 조회한 Resolver가 SOA 음수 캐시 시간(현재 Zone 900초) 동안 NXDOMAIN을 기억한다
- `failover` 값과 `app_failover` 리소스는 모듈 호환용으로만 남긴다 (envs/prod에서 쓰지 않음)
- 근거: [Route 53 — Active-active and active-passive failover](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-failover-types.html) "If all the records that have a weight greater than 0 are unhealthy, then Route 53 responds to queries using the zero-weighted records."

## 다른 담당과의 연결

| 필요한 것 | 담당 | 없으면 |
|---|---|---|
| Public RT `192.168.24.0/24 → VGW`, VPN static route | 희재 (hybrid, 적용됨) | NLB 타깃 unhealthy |
| Infra `aws-to-dmz` policy, LB 반환 라우트 | 희재 (온프렘, 0930 적용) | 타깃 unhealthy |
| ROSA Route host `primary-health.<도메인>` → `/actuator/health/routing` (Health 전용 Service, gitops #4) | 예린 | ROSA 헬스체크 실패 (Router 503) |
| 온프렘 NGF listener·HTTPRoute `dr-health.<도메인>` → `/actuator/health/routing` (Health 전용 Service, `scripts/setup_dr_health_1006.sh`) | 희재 | DR 헬스체크 실패 |
| 온프렘 `app.<도메인>` listener·HTTPRoute hostname | 별도 (GitOps `overlays/onprem-dr`) | DR 전환 후 사용자 요청 404 |
| Backend `routing` health group (`livenessState,deploymentSafety`, DB 제외) | 정현 | `/actuator/health/routing` 404 → 헬스체크 실패 |
| Hosted Zone, 도메인 | 희재 (bootstrap/dns) | `enable_route53_routing = true` 시 plan 단계에서 중단 |
| 공인 인증서 (Route 단위 TLS, NGF) | 희재 발급 → 예린·온프렘 적용 | 브라우저 경고 (Route 53 헬스체크는 인증서를 검증하지 않음) |

## 확인 (AWS CLI, ap-northeast-2)

```bash
# NLB 타깃 상태 (healthy / unhealthy 사유)
aws elbv2 describe-target-health --target-group-arn <dr_target_group_arn> --region ap-northeast-2

# 도메인 전: NLB IP로 온프렘 앱 확인 (NGF 1차 hostname 사용)
NLB_IP=$(dig +short <dr_nlb_dns_name> | head -1)
curl -sk --resolve app.nplan.local:443:$NLB_IP https://app.nplan.local/ -o /dev/null -w '%{http_code}\n'

# Route 53 헬스체크 상태 (헬스체크는 글로벌 서비스)
aws route53 get-health-check-status --health-check-id <dr_health_check_id>
```

## 비용 (켜 둔 시간만큼)

| 항목 | 기준 |
|---|---|
| NLB | 시간 요금 + NLCU (서울 리전 단가 확인) |
| 공인 IPv4 | internet-facing NLB는 AZ마다 1개 → 3개 × 시간 요금 |
| Route 53 헬스체크 | 2개, 월 단위 요금 + HTTPS·fast interval 옵션 요금 (12일이면 일할) |
| Hosted Zone·쿼리 | bootstrap/dns, Alias 쿼리(AWS 리소스 대상)는 무료 |

- DR NLB는 `enable_dr_nlb = false`로 끌 수 있다. 정리는 Destroy 순서상 **edge가 먼저** (README Apply 절).
