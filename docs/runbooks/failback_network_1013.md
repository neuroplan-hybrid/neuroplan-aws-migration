# T6 런북 (네트워크 파트) — Failback: 온프렘 DR → ROSA 복귀 (1013, 설명용)

> 담당 **희재(트래픽·네트워크) + 정현(데이터)** · 10/16 시연은 **설명만** (실제 원복은 destroy로 대체, T5 런북 5.2)
> 기준: 2차 시나리오 4.10 Failback 흐름, T5 런북 `site_dr_rosa_to_onprem_1008.md`(8번 고정·5.2), 발표증적 5.6
> 이 문서는 네트워크·트래픽 단계만 구체화한다. 데이터 재동기화 명령은 정현 런북 범위

## 1. 원칙 — "넘어갈 때는 자동, 돌아올 때는 일부러 수동"

| 방향 | 방식 | 이유 |
|---|---|---|
| ROSA → 온프렘 (T5) | Route 53 HC가 unhealthy를 보고 자동 전환 | 장애 시 사람 판단을 기다리지 않음 |
| 온프렘 → ROSA (T6) | **가중치를 먼저 고정한 뒤** 데이터가 맞춰지면 사람이 되돌림 | DR 기간 쓰기는 온프렘에만 있음. ROSA HC가 healthy로 돌아왔다고 트래픽만 넘기면 그 데이터가 RDS에 없음 |

- 위험 시나리오: T5 8번 고정 전에 ROSA가 복구되면, 가중치가 ROSA 1 / 온프렘 0이라 HC 회복 즉시 Route 53이 ROSA로 응답 → 사용자는 RDS(DR 기간 데이터 없음)를 봄 → **T5 8번(ROSA 0 / 온프렘 1 고정)이 Failback의 전제**

## 2. 순서 (담당·네트워크 확인 포인트)

| # | 단계 | 담당 | 네트워크 확인 (희재) |
|---|---|---|---|
| 0 | 가중치 **ROSA 0 / 온프렘 1 고정** 상태 확인 (T5 8번 완료) | 희재 | 권한 DNS = onprem, HC_ROSA `Inverted=False` |
| 1 | ROSA 복구 확인 (Router·Backend 정상) | 예린 | `primary-health` routing 200 — **트래픽은 여전히 온프렘** (가중치 0이므로) |
| 2 | 온프렘 신규 쓰기 중지 (점검 모드) | 정현 | — |
| 3 | DR 기간 데이터 확인 (승격 시점 GTID ~ 현재) | 정현 | — |
| 4 | RDS 재동기화: 온프렘(Source) → RDS(Replica) | 정현 | **RDS → 온프렘 3306** 연결 (`aws-to-data`, RDS가 연결을 엶) — 이관 단계와 같은 방향, 10/12까지 사용하던 경로 |
| 5 | GTID·Row Count 검증 → RDS를 Writer로 | 정현 | — |
| 6 | 온프렘을 RDS의 Replica로 재구성 (역복제) | 정현 | **온프렘 DB → RDS 3306** (`data-to-aws` + DB VM 경로) → `check_db_rds_path_1013.sh` 두 DB 모두 OK 확인 (#96) |
| 7 | 앱 DB 엔드포인트 = RDS, ROSA 쓰기 차단 해제 | 정현·예린 | ROSA → RDS 3306 (RDS SG ROSA /20) |
| 8 | **가중치 복귀 ROSA 1 / 온프렘 0** (Traffic Failback) | 희재 | 아래 3장 |
| 9 | 사용자 쓰기 재개, k6 로그인·조회·저장 확인 | 정현·희재 | probe `weights <csv> 100` → 권한 DNS rosa 100% |

- 4번과 6번은 **연결을 여는 쪽이 반대** (4: RDS → 온프렘, 6: 온프렘 → RDS). 10/13 #96은 6번 방향만 막혀 있던 사례 → 6번 전에 경로 점검 스크립트 필수

## 3. 8번 가중치 복귀 (희재)

```bash
# DevOps VM (heejae) — tfvars PR (T5 8번에서 0/1로 바꾼 operation.tfvars를 1/0으로)
cd ~/neuroplan-aws-migration && git switch main && git pull --ff-only
git switch -c feature/route53-failback-1-0-$(date +%m%d)
sed -i -E 's/^rosa_weight( *)= *[0-9]+/rosa_weight\1= 1/; s/^onprem_weight( *)= *[0-9]+/onprem_weight\1= 0/' envs/prod/operation.tfvars
git diff && (cd envs/prod && terraform fmt -check -diff)
git commit -am "feat(edge): Route 53 Failback — ROSA 1 / 온프렘 0" && git push -u origin HEAD
```
- Plan 기대값 (예린 `operation`): `app_weighted["rosa"]`·`["onprem"]` **2 change (weight만)**, 그 외 0
- apply 조건: 2~7번 정현·예린 완료 공유 후에만 (데이터가 RDS에 맞춰지기 전 복귀 금지)
- 확인: 권한 DNS = ROSA NLB IP (`dig +short app.neuroplan.cloud @<awsdns NS>`), HC 2개 Healthy, probe `rosa`·`dr` 200

## 4. 중단 기준

| 상황 | 조치 |
|---|---|
| 4·6번 복제가 연결되지 않음 | 가중치 그대로(온프렘 1) 유지 → 서비스는 온프렘에서 계속. 경로 점검(`check_db_rds_path_1013.sh`, Infra `setup_db_to_rds_1013.sh verify`) 후 재시도 |
| 5번 검증 불일치 | RDS를 Writer로 바꾸지 않음, 온프렘 Writer 유지 (정현) |
| 8번 후 ROSA 쪽 오류 | 가중치를 다시 0/1로 되돌리는 PR → 2 change → apply (데이터는 RDS가 Writer이므로 **온프렘 쓰기 재개 금지**, 정현 판단) |

## 5. 발표 설명 (발표증적 5.6)
1. 1차와 다른 점 ① 데이터 역방향 재동기화(관리형 RDS ↔ 직접 구축 MariaDB, GTID) ② 인터넷 DNS 캐시 때문에 잠시 두 사이트에 요청이 나뉠 수 있음 ③ HC 자동 복귀 위험 → 첫 단계가 가중치 고정
2. 문장: "넘어갈 때는 자동, 돌아올 때는 일부러 수동"
3. 네트워크 관점: Failback은 복제 방향이 두 번 바뀌므로(4·6번) **양방향 3306 경로**가 모두 열려 있어야 함 → 10/13 #96에서 한쪽 방향 누락을 사전에 발견·보완
