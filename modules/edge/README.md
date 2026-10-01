# edge module

DR NLB와 Route 53(GSLB) 레코드·헬스체크를 만드는 희재 담당 모듈이다. ROSA Ingress LB와 Hosted Zone은 만들지 않고 입력값으로만 받는다.

```
사용자 / Route 53 헬스체커
        │  app.<도메인> (Weighted → Failover)
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
| `enable_route53_routing` + `enable_dr_nlb` | 헬스체크 `dr-health`(HTTPS, SNI, `/health/ready`), `dr-health.<도메인>` Alias → DR NLB, app 레코드 `onprem` |
| `enable_route53_routing` + `primary_lb_dns_name` | 헬스체크 `primary-health`, `primary-health.<도메인>` Alias → ROSA LB, app 레코드 `rosa` |
| `app_routing_policy` | `weighted`: `app_weighted[rosa/onprem]` / `failover`: `app_failover[rosa=PRIMARY, onprem=SECONDARY]` / `none`: app 레코드 없음 |

- 도메인이 없어도 DR NLB는 만들 수 있다 (`enable_route53_routing = false`). PoC는 NLB DNS로 확인한다.
- 헬스체크 대상 이름(`primary-health`, `dr-health`)은 app 레코드와 분리한다 (시나리오 4.8).
- NLB 타깃 헬스체크는 TCP, Route 53 헬스체크는 HTTPS + FQDN + SNI (NLB HTTPS 헬스체크는 Host/SNI 지정 불가).
- VPN 너머 IP 타깃은 Client IP 보존이 안 되므로 `preserve_client_ip = false`. 온프렘에는 NLB 사설 IP(Public 서브넷)가 출발지로 보인다.

## Weighted ↔ Failover 전환

Route 53은 같은 이름·타입에 Weighted 레코드와 Failover 레코드를 함께 둘 수 없다. Terraform은 레코드마다 따로 API를 호출하므로 `weighted → failover`를 한 번의 apply로 바꾸면 첫 레코드 생성에서 실패할 수 있다.

| 방식 | 절차 | 영향 |
|---|---|---|
| A. 설계대로 Failover | Cutover 점검 모드 중 `app_routing_policy = "none"` apply → `"failover"` apply | `app` 레코드가 apply 사이(1~2분) 없음. 그 사이 조회한 Resolver는 SOA 음수 캐시 시간 동안 NXDOMAIN을 기억 |
| B. Weighted 유지 | 운영 단계도 Weighted, `rosa_weight = 1`, `onprem_weight = 0` | 가중치만 변경 → 공백 없음. Route 53은 0이 아닌 레코드가 모두 unhealthy일 때만 가중치 0 레코드로 응답 → active-passive |

방식은 팀 결정 후 이 표를 갱신한다.

## 다른 담당과의 연결

| 필요한 것 | 담당 | 없으면 |
|---|---|---|
| Public RT `192.168.24.0/24 → VGW`, VPN static route | 희재 (hybrid, 적용됨) | NLB 타깃 unhealthy |
| Infra `aws-to-dmz` policy, LB 반환 라우트 | 희재 (온프렘, 0930 적용) | 타깃 unhealthy |
| ROSA Route host `primary-health.<도메인>` → `/health/ready` | 예린 | ROSA 헬스체크 실패 (Router 503) |
| 온프렘 NGF HTTPRoute hostname `app.<도메인>`, `dr-health.<도메인>` | 온프렘 앱 배포 | DR 헬스체크 실패 |
| `/health/ready` (App + DB, 실패 시 503) | 정현 | 헬스체크 의미 없음 |
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
