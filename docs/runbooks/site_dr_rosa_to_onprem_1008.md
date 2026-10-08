# T5 런북 — ★ Site DR: ROSA → 온프레미스 전환·데이터 정합성 (1008, r3: AWS CLI는 Infra VM root = IAM user heejae)

> 담당 **희재(네트워크·측정) + 정현(데이터)** · P0·핵심 · 시연 10/16 · 리전 ap-northeast-2 (Route 53은 글로벌)
> 기준: #53(순서), #55(확정표), **#68(단계별 담당·주입 방식·RTO 기준 합의)**, 런북 형식은 T4(#67)
> 희재: 0·5~8번 + 측정·판정 / 정현: 1~4번 데이터 전환·6번 쓰기 재개 판단 (#68 정현 확정안 10/8 반영)
> 비밀번호·계정 ID는 적지 않는다

## 1. 목적과 판정

| 항목 | 내용 |
|---|---|
| 시작 상태 | Cutover 후 운영: Route 53 **ROSA 1 / 온프렘 0**, RDS = Writer, RDS → 온프렘 db-primary·replica 역복제 |
| 흐름 | 데이터 전환(1~4, 정현) → 트래픽 전환(5~7, 희재) → 고정(8, 희재) |
| 데이터 판정 (정현) | GTID 일치, 마지막 쓰기 DR 반영, 단일 Writer, 온프렘 쓰기 후 재조회 |
| 트래픽 판정 (희재) | Control RTO·User RTO 측정·기록, 전환 후 k6 로그인·조회·저장 성공, 권한 DNS = onprem 유지 |
| 중단 (#68) | ROSA 쓰기 차단 후 **5분 안에** GTID 불일치 / IO·SQL ≠ Yes / Lag ≠ 0 → **승격 안 함, 5번 주입 안 함** → 5.1 **승격 전 원복** (`DEMO_WRITE_FENCE` 해제, ROSA + RDS Writer 운영 복귀). 승격 후에는 5.2 |

### 1.1 시각 기록 (#68 확정)

| 기호 | 시각 | 누가 |
|---|---|---|
| T_sync | `DEMO_WRITE_FENCE=true` Argo CD Sync 완료 | 정현·예린 |
| T_rollout | ROSA Backend 새 Pod 롤아웃 완료 | 정현·예린 |
| **T0** | 롤아웃 완료 후 ROSA 쓰기 API가 **실제로 503**을 반환한 시각 | 정현 (희재 기록) |
| T_promote | 온프렘 db-primary 승격·제한 쓰기·재조회 성공 | 정현 |
| **T_inject** | `primary-health` HC `--inverted` **명령 실행 시각** | 희재 |
| T_unhealthy | HC Unhealthy 관측 시각 (보조) | 희재 |
| T_dns | 권한 DNS가 onprem 응답 시작 (probe) | 희재 |
| T_user | k6 로그인·조회·저장 30초 연속 성공 시작 | 희재 |
| T_write_resume | 온프렘 사용자 쓰기 재개 (6번 조건 충족) | 정현 |

| 지표 | 계산 | 성격 |
|---|---|---|
| 데이터 전환 시간 | T0 → T_promote | 소요 시간 (수동 단계 포함, RTO 아님) |
| 쓰기 차단 반영 지연 | T_sync → T0 | 보조 (Sync·롤아웃 시간) |
| **Control RTO** | T_inject → T_dns | 주 지표 |
| **User RTO** | T_inject → T_user | 주 지표 |
| Route 53 전파 시간 | T_unhealthy → T_dns | 보조 |

## 2. 왜 전환되는가 (발표 설명용)

```
app.neuroplan.cloud  Weighted A(Alias) 2개
  ├ rosa   → ROSA Router NLB   weight 1  ← HC primary-health (/actuator/health/routing)
  └ onprem → DR NLB            weight 0  ← HC dr-health
- weight > 0 레코드(rosa)가 모두 unhealthy → Route 53이 weight 0 레코드(onprem)로 응답 (active-passive)
- HC 설정: HTTPS 10초 간격, 3회 연속 실패 시 Unhealthy. `--inverted` 후 실제 걸리는 시간(T_inject → T_unhealthy / T_dns)은 단정하지 않고 **10/13~14 리허설에서 실측해 확정** (6장)
```
- 주입을 `--inverted`로 하는 이유 (#68): `DEMO_READINESS_FAIL` 롤아웃은 `maxUnavailable: 0`에서 기존 Pod가 200을 계속 낼 수 있어 주입 실패 위험. inverted는 명령 1줄·시각이 정확·GitOps 무관
- 발표 설명: 데이터 전환(1~4)은 계획된 수동 절차, 그 뒤 "ROSA 사이트 장애"를 HC 판정으로 주입해 DNS 기반 자동 전환을 측정

## 3. 사전 조건 (T5 시작 전)

| # | 확인 | 담당 | 기대 |
|---|---|---|---|
| ① | `DEMO_WRITE_FENCE` 앱·GitOps PR Merge (10/12 전) | 정현·예린 | ROSA overlay에 플래그(기본 false), 상태 변경 API만 503·조회·routing health 유지 |
| ② | 8번용 tfvars PR 리뷰·승인 완료 (Merge 전 대기) | 희재 | `operation.tfvars` `rosa_weight = 0`, `onprem_weight = 1` |
| ③ | Route 53 HC 2개 Healthy, 권한 DNS = rosa | 희재 | 아래 3.1 |
| ④ | 복제 정상 (IO/SQL Yes, Lag 0) | 정현 | |
| ⑤ | VPN ESP 2, DR 경로 200 | 희재 | `check_vpn_state_0930.sh --aws` FAIL 0, probe `dr` 200 |
| ⑥ | 측정 PC·DevOps VM·Infra VM 시각 동기화 | 전원 | `date '+%F %T.%N %z'` 비교 |

### 3.1 측정 값 조회·HC·DNS 사전 확인

> **AWS CLI 명령은 모두 Infra VM(root)에서 실행.** DevOps VM `heejae` 계정은 AWS 자격 증명·Terraform backend가 없음 (10/8 예린 확인)

- **AWS CLI 실행 주체**: Infra VM 리눅스 `root` 계정의 기본 프로필(`/root/.aws`, 600) = **IAM 사용자 `heejae`** (`AWS_PROFILE` 지정 없음). 10/8 `sts get-caller-identity` → `user/heejae`, `simulate-principal-policy`로 아래 권한 allowed 확인
  - `route53:ListHealthChecks`·`GetHealthCheck`·`GetHealthCheckStatus`·`UpdateHealthCheck`·`ListHostedZonesByName`·`ListResourceRecordSets`, `elasticloadbalancing:DescribeLoadBalancers`
- **값 전달 경로**: DevOps VM `heejae` → `root@192.168.14.62` SSH/scp (Mgmt 대역, 비밀번호 인증, 10/7부터 스크립트 복사에 사용 — 실행시트 0.1)
- 당일 사전 확인:
```bash
# Infra VM (root)
whoami; aws sts get-caller-identity --query Arn --output text | sed -E 's/[0-9]{12}/<ACCT>/'   # 기대: root / ...:user/heejae
# DevOps VM (heejae)
ssh -o ConnectTimeout=5 root@192.168.14.62 'whoami; hostname -s'                               # 기대: root / infra
```

```bash
# Infra VM (root) — ① AWS에서 직접 조회 → ~/t5_env.sh (Terraform output 불필요)
ZID="$(aws route53 list-hosted-zones-by-name --dns-name neuroplan.cloud --max-items 1 \
  --query "HostedZones[?Name=='neuroplan.cloud.'].Id | [0]" --output text 2>/dev/null | sed 's#/hostedzone/##')"
if [[ ! "$ZID" =~ ^Z[A-Z0-9]+$ ]]; then echo "⚠ Hosted Zone ID 조회 실패: '$ZID' → 중단"; ZID=""; fi
HC_ROSA="$(aws route53 list-health-checks --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='primary-health.neuroplan.cloud'].Id | [0]" --output text)"
HC_DR="$(aws route53 list-health-checks --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='dr-health.neuroplan.cloud'].Id | [0]" --output text)"
DR_NLB_DNS="$(aws elbv2 describe-load-balancers --region ap-northeast-2 --names neuroplan-dr-nlb --query 'LoadBalancers[0].DNSName' --output text)"
ROSA_LB_DNS="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZID" \
  --query "ResourceRecordSets[?Name=='app.neuroplan.cloud.' && SetIdentifier=='rosa'].AliasTarget.DNSName | [0]" --output text | sed 's/\.$//')"
ok=1; for v in ZID HC_ROSA HC_DR DR_NLB_DNS ROSA_LB_DNS; do
  [[ -n "${!v}" && "${!v}" != None ]] || { echo "⚠ $v 없음 → 중단"; ok=0; }
done
[[ "$HC_ROSA" =~ ^[0-9a-f-]{36}$ && "$HC_DR" =~ ^[0-9a-f-]{36}$ ]] || { echo "⚠ HC ID 형식 이상 → 중단"; ok=0; }
[[ "$DR_NLB_DNS" == *.elb.ap-northeast-2.amazonaws.com ]] || { echo "⚠ DR NLB DNS 형식 이상 → 중단"; ok=0; }
if (( ok )); then
  umask 077
  printf 'export HC_ROSA=%q\nexport HC_DR=%q\nexport DR_NLB_DNS=%q\nexport ROSA_LB_DNS=%q\n' \
    "$HC_ROSA" "$HC_DR" "$DR_NLB_DNS" "$ROSA_LB_DNS" > ~/t5_env.sh.tmp && mv ~/t5_env.sh.tmp ~/t5_env.sh && cat ~/t5_env.sh
else
  rm -f ~/t5_env.sh ~/t5_env.sh.tmp; echo "⚠ t5_env.sh 생성 안 함 (이전 값도 삭제)"
fi
```
- 4개가 모두 값이 있어야 파일 생성. HC ID는 HC 대상 FQDN(`primary-health`·`dr-health`)으로, ROSA LB DNS는 `app` Weighted 레코드(`rosa`)의 Alias 대상으로 찾음 → 10/13 Route 53 `weighted` 적용 후에만 값이 나옴

```bash
# DevOps VM (heejae) — ② 같은 값 받아오기 (probe용, AWS 호출 없음)
scp -o ConnectTimeout=10 root@192.168.14.62:~/t5_env.sh ~/ && chmod 600 ~/t5_env.sh && cat ~/t5_env.sh
```
- 이후 4장 명령은 **터미널마다 `source ~/t5_env.sh`로 시작** (새 터미널에서 변수가 비는 문제 방지). AWS 명령은 Infra VM, probe는 DevOps VM

```bash
# Infra VM (root) — ③ HC·DNS 상태 확인
source ~/t5_env.sh \
&& for h in "${HC_ROSA:?}" "${HC_DR:?}"; do
     aws route53 get-health-check --health-check-id "$h" --query 'HealthCheck.HealthCheckConfig.[FullyQualifiedDomainName,ResourcePath,Inverted]' --output text
     aws route53 get-health-check-status --health-check-id "$h" --query 'HealthCheckObservations[].StatusReport.Status' --output text | tr '\t' '\n' | cut -c1-30 | sort | uniq -c
   done
dig +short app.neuroplan.cloud @"$(dig +short NS neuroplan.cloud @8.8.8.8 | head -1)"
```
- 기대: 둘 다 `Inverted=False`, 체커 대부분 `Success: HTTP Status Code 200`, 권한 DNS 응답 = ROSA Router NLB IP

## 4. 진행 절차

### 0. 측정 시작 (희재, T0 5분 전)
```bash
# DevOps VM (heejae) — probe: 권한 DNS 사이트 + 양쪽 routing health 1초
source ~/t5_env.sh && cd ~/neuroplan-aws-migration && pwd \
&& echo "DR=${DR_NLB_DNS:?} ROSA=${ROSA_LB_DNS:?}" \
&& bash scripts/probe_1006.sh run 1800
```

```bash
# 측정 PC — k6 User RTO (iter 모드 = 매 반복 로그인·조회·저장)
read -rp 'TEST_EMAILS (정현 테스트 계정, 쉼표 구분): ' TEST_EMAILS
read -rsp 'TEST_PASSWORD: ' TEST_PASSWORD; echo; export TEST_PASSWORD
K6_CSV_TIME_FORMAT=rfc3339_nano k6 run \
  -e BASE_URL=https://app.neuroplan.cloud -e TEST_EMAILS="$TEST_EMAILS" \
  -e LOGIN_MODE=iter -e DNS_TTL=5s -e DURATION=30m \
  --out csv=k6_$(date +%m%d-%H%M).csv scripts/k6_rto_1007.js
unset TEST_PASSWORD
```
- `DNS_TTL=5s`: k6 내부 DNS 캐시가 전환을 늦추지 않게 (기본 60s)
- 1~4번 동안(쓰기 차단 중) k6 저장 실패는 **예상된 실패** → User RTO는 T_inject 이후만 계산

```bash
# Infra VM (root) — HC 체커별 상태·CheckedTime 1초 기록 (별도 창, T_unhealthy 보조 지표·증적)
source ~/t5_env.sh && : "${HC_ROSA:?}"
LOG=~/t5_hc_$(date +%m%d-%H%M).tsv
printf 'local_time\tregion\tchecked_time\tstatus\n' > "$LOG"
while :; do
  now="$(date +%T.%3N)"
  out="$(aws route53 get-health-check-status --health-check-id "$HC_ROSA" \
        --query 'HealthCheckObservations[].[Region,StatusReport.CheckedTime,StatusReport.Status]' --output text 2>&1)"
  awk -v t="$now" -F'\t' 'NF >= 3 { print t "\t" $1 "\t" $2 "\t" substr($3, 1, 60) }' <<< "$out" >> "$LOG"   # 체커별 원본 (증적)
  printf '%s %s\n' "$now" "$(awk -F'\t' 'NF >= 3 { print substr($3, 1, 7) }' <<< "$out" | sort | uniq -c | tr -s ' \n' ' ')"   # 화면 요약
  sleep 1
done
```
- 증적 파일: 체커(Region)별 **AWS `CheckedTime`**과 상태를 로컬 시각과 함께 저장 (#68) → T_unhealthy는 로컬 시각이 아니라 체커 `CheckedTime` 기준으로 판정
- ⚠ 리허설 확인 필요: `--inverted` 상태에서 체커별 `StatusReport`가 원래 결과(Success)를 보이는지, 뒤집힌 결과를 보이는지 → 10/13~14에 확인 후 T_unhealthy 판정 기준 확정. 확정 전까지 T_unhealthy는 CloudWatch `HealthCheckStatus`(1분 단위, us-east-1)로 보완

### 1~4. 데이터 전환 (정현, #68 확정)

| # | 단계 | 판정 (모두 충족) | 증적 |
|---|---|---|---|
| 1 | ROSA Backend 쓰기 차단: `DEMO_WRITE_FENCE=true` (앱·GitOps PR, 10/12 전 Merge, 기본값 false) → Sync → 롤아웃 | 상태 변경 API **503** · 조회 API 정상 · `/actuator/health/routing` **200** · `/actuator/health/readiness` 의도대로 정상 · ROSA Backend Pod 전체 롤아웃 완료 | T_sync, T_rollout, **T0** |
| 2 | 복제 catch-up (RDS → 온프렘) | GTID 일치 · `Slave_IO_Running: Yes` · `Slave_SQL_Running: Yes` · `Seconds_Behind_Master: 0` · 마지막 테스트 쓰기 행이 온프렘에 존재 | 상태 출력 |
| 3 | db-primary 승격: `rds-dr-promote.yml` 승인 플래그와 함께 실행, **db-primary만** | `hostname=db-primary` · `read_only=0` · 승격 후 GTID · 복제 중지 상태 · 제한 테스트 쓰기 성공 · 재조회 성공 | 출력 저장 (메시지만으로 판단하지 않음) |
| 4 | 온프렘 제한 쓰기: 온프렘 경로로 테스트 marker 저장·재조회 | 쓰기 성공 · 재조회 성공 · db-primary가 유일한 Writer · RDS 동시 쓰기 없음 | **T_promote** |

- 희재 할 일: 1번 T0를 `~/t5_times.log`에 기록 (정현 공유 시각), probe·k6 동작 확인 / 4번 완료 공유를 받은 뒤에만 5번 진행
- **중단 (#68)**: T0 후 5분 안에 GTID 불일치 / IO·SQL ≠ Yes / Lag ≠ 0 → 3번 승격·5번 주입 **진행 안 함** → **5.1 승격 전 원복** (쓰기 차단이 걸려 있으므로 RDS Writer 유지만으로는 사용자 쓰기가 계속 막힘)
- 1~4번 동안 k6 저장 실패는 쓰기 차단에 따른 예상된 실패 (User RTO는 T_inject 이후만 계산)

### 5. ROSA routing health 실패 주입 (희재) · T_inject
```bash
# Infra VM (root) — 4번 완료(정현 "승격 완료" 공유) 후에만
source ~/t5_env.sh
read -rp '정현 4번 완료 확인 (yes 입력): ' ok
if [[ "$ok" == yes && -n "${HC_ROSA:-}" ]]; then
  echo "T_inject $(date '+%F %T.%3N %z')" | tee -a ~/t5_times.log
  aws route53 update-health-check --health-check-id "$HC_ROSA" --inverted \
    --query 'HealthCheck.HealthCheckConfig.Inverted' --output text
else
  echo "⚠ 중단: 4번 미완료 또는 HC_ROSA 없음"
fi
```
- 기대 출력: `True`
- `HC_DR`은 건드리지 않음 (DR 쪽이 Healthy여야 전환됨)

### 6. DR DNS 응답 확인 (희재) → 온프렘 사용자 쓰기 재개 (정현) · T_write_resume
- probe 창: `site_auth`가 `rosa` → `onprem`으로 바뀐 첫 시각 = **T_dns**
```bash
# DevOps VM — 수동 교차 확인
dig +short app.neuroplan.cloud @"$(dig +short NS neuroplan.cloud @8.8.8.8 | head -1)"   # 기대: DR NLB IP
```
- 희재가 정현에게 공유: 권한 DNS = onprem, DR NLB Target healthy (T4 런북 4.4 명령), probe `dr` 200
- **쓰기 재개 조건 (#68, 모두 충족 시 정현이 재개 → T_write_resume)**: 권한 DNS가 onprem 응답 · DR NLB Target healthy · `dr-health` HTTP 200 · 온프렘 제한 쓰기·재조회 성공 · db-primary가 유일한 Writer
- DR 운영 중에는 ROSA 쓰기 차단(`DEMO_WRITE_FENCE=true`) 유지

### 7. k6 복구 판정 (희재) · T_user
- k6 출력에서 로그인·조회·저장이 연속 성공으로 돌아오는지 확인 → 30초 연속 성공 후 판정 완료 (계산은 아래 "측정 종료·요약")

### 8. ROSA 0 / DR 1 고정 (희재) · ROSA 쓰기 차단 유지
- 3장 ②에서 승인해 둔 tfvars PR Merge (T_write_resume 이후) → 예린(지정 실행자) `operation` plan → apply
- **plan 예상 변경 (리뷰 때 미리 공유)**
  - `app` Weighted 레코드 2개 weight 변경 (rosa 1 → 0, onprem 0 → 1)
  - `primary` HC `inverted: true → false` (5번 CLI 변경을 Terraform이 원복 = 예상된 drift)
  - 그 외 변경 0 (destroy/replace 0)
- apply 후 확인: 권한 DNS 계속 onprem, HC_ROSA `Inverted=False`, ROSA 쓰기 차단(`DEMO_WRITE_FENCE=true`) 유지 (정현)

### 측정 종료·요약 (8번 후, 희재)
```bash
# DevOps VM (heejae) — probe Ctrl+C 후
cd ~/neuroplan-aws-migration && pwd
TI="15:20:03"                                   # ~/t5_times.log의 T_inject(HH:MM:SS)로 교체
CSV="$(ls -t probe_*.csv | head -1)" && echo "$CSV"
bash scripts/probe_1006.sh summary "$CSV" "$TI"      # → Control RTO (T_inject → 권한 DNS onprem)
```
```bash
# 측정 PC — k6 Ctrl+C 후
python3 scripts/k6_rto_summary_1007.py "$(ls -t k6_*.csv | head -1)" --t0 "2026-10-16 15:20:03" --mode rto   # → User RTO
```
- 기록: 1.1의 시각 전부, Control·User RTO, 데이터 전환 시간·쓰기 차단 반영 지연(정현), Route 53 전파 시간(보조), HC 체커 로그 전환 구간

## 5. 중단·원복 (단계별)

> 어디서 멈췄는지에 따라 원복 방법이 다르다. **Writer 위치와 사용자 트래픽 방향이 어긋나지 않게** 하는 것이 기준.

| 멈춘 시점 | Writer | Route 53 | 원복 | HC 단독 `--no-inverted` |
|---|---|---|---|---|
| 1~2번 (승격 전) | RDS | ROSA 1 / 온프렘 0, inverted 아님 | **5.1** | 해당 없음 (주입 전) |
| 3~4번 이후 (승격 후, 5번 주입 전) | 온프렘 db-primary | ROSA 1 / 온프렘 0 | **5.2** | 해당 없음 |
| 5~7번 (주입 후, 8번 전) | 온프렘 db-primary | ROSA 1 / 온프렘 0, **inverted** | **5.2** | **금지** |
| 8번 완료 | 온프렘 db-primary | ROSA 0 / 온프렘 1 (apply로 inverted 원복) | 정상 종료 | 이미 원복됨 |

### 5.1 승격 전 중단 → 기존 ROSA + RDS Writer 운영 복귀 (정현·예린, 희재 확인)
1. `DEMO_WRITE_FENCE=false` (ROSA overlay ConfigMap, GitOps 커밋)
2. Argo Sync 완료 · ROSA Backend 롤아웃 완료
3. ROSA 쓰기 API **정상 성공** 확인 (테스트 쓰기 → 재조회)
4. 기존 운영 상태 확인: RDS = Writer, RDS → 온프렘 복제 IO/SQL Yes, 권한 DNS = ROSA, k6 저장 성공 복귀 (희재)
- 5번 주입을 하지 않았으므로 HC·Route 53은 손대지 않음

### 5.2 승격 후 중단 → HC만 단독 원복 금지
- db-primary가 Writer가 된 뒤 `HC_ROSA`만 `--no-inverted`로 되돌리면, 가중치가 ROSA 1 / 온프렘 0이라 **Route 53이 다시 ROSA를 응답** → 사용자 트래픽(ROSA)과 실제 Writer(온프렘)가 어긋남
- 둘 중 하나로만 마무리:
  - **(가) DR 유지**: 8번(ROSA 0 / 온프렘 1 고정 apply)을 끝까지 진행 → apply가 HC inverted도 함께 원복. 5번 주입 전에 멈췄다면 5번부터 이어서 진행해 DR로 확정
  - **(나) Failback**: T6 절차로 RDS Writer를 다시 확정(재동기화 → 온프렘 쓰기 중지 → RDS Writer 전환 → ROSA 쓰기 차단 해제)한 **뒤에** HC를 원복
```bash
# Infra VM (root) — (나)에서 RDS Writer 재확정이 끝난 뒤에만 실행, Writer 확인 입력 가드
source ~/t5_env.sh
read -rp 'RDS Writer 재확정·ROSA 쓰기 차단 해제 완료 (yes 입력): ' ok
if [[ "$ok" == yes ]]; then
  aws route53 update-health-check --health-check-id "${HC_ROSA:?}" --no-inverted --query 'HealthCheck.HealthCheckConfig.Inverted' --output text   # 기대: False
else
  echo "⚠ 중단: Writer 재확정 전 HC 단독 원복 금지 (5.2)"
fi
```
- 10/16 시연에서는 (가)가 기본. (나)는 T6 런북 설명 범위이고 실제 원복은 10/16 destroy로 대체

## 6. 리허설 (희재)
- 10/13~14 Weighted 검증 단계에서 **5~6번만** 사전 확인 (`--inverted` → 권한 DNS 전환 → `--no-inverted` 원복)
  - 이관 단계 가중치(rosa 0 / onprem 100)에서는 방향이 반대이므로, 그때의 가중치에 맞춰 "weight > 0 쪽 HC를 inverted"로 확인
  - 확인할 것: inverted 시 `get-health-check-status` 체커 상태 표시, **T_inject → T_unhealthy / T_dns 실측** (2장 설명 값 확정), 1초 polling 시 API throttling 여부 (있으면 간격 2~5초로 조정)

## 7. 발표 증적 (발표증적 5.5)
- 1.1 시각표(T_sync~T_write_resume) + Control/User RTO, 데이터 전환 시간(별도), probe `site_auth` 전환 구간, k6 실패 구간 그래프, HC 체커 로그, GTID·마지막 쓰기 증적(정현), 8번 plan 요약
