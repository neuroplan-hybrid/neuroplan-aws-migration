# T8 런북 (네트워크 파트) — Failback: 온프렘 DR → ROSA 복귀 (구 T6, 1013 작성 · 1028 실제 순서 반영)
 
> 담당 **희재(트래픽·네트워크) + 정현(데이터)** · 예린(ROSA·Plan/Apply)
> 번호: [통합 시연안 #123](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123)(**미병합 PR**)에서 제안한 번호 체계를 인용해 **T8**(이전 번호 T6)로 표기한다. 본문의 "DR 런북 8번"은 `site_dr_rosa_to_onprem_1008.md`의 가중치 고정 단계(구 T5 8번)를 뜻한다
> 계획서 기준(1013): 10/16에는 **설명만** 하고 실제 원복은 destroy로 대체 → **실제 진행(10/16)**: T8로 실제 수행, PASS. 결과 `docs/test-results/t8_failback_1016.md`
> 이 문서는 네트워크·트래픽 단계와 전체 순서를 다룬다. 데이터 재동기화 명령은 정현 런북 범위
 
## 1. 원칙 — "넘어갈 때는 자동, 돌아올 때는 일부러 수동"
 
| 방향 | 방식 | 이유 |
|---|---|---|
| ROSA → 온프렘 (DR) | Route 53 HC가 unhealthy를 보고 자동 전환 | 장애 시 사람 판단을 기다리지 않음 |
| 온프렘 → ROSA (Failback) | **가중치를 먼저 고정한 뒤** 데이터가 맞춰지면 사람이 되돌림 | DR 기간 쓰기는 온프렘에만 있음. ROSA HC가 healthy로 돌아왔다고 트래픽만 넘기면 그 데이터가 RDS에 없음 |
 
- 위험 시나리오: DR 런북 8번 고정 전에 ROSA가 복구되면, 가중치가 ROSA 1 / 온프렘 0이라 HC 회복 즉시 Route 53이 ROSA로 응답 → 사용자는 RDS(DR 기간 데이터 없음)를 봄 → **DR 런북 8번(ROSA 0 / 온프렘 1 고정)이 Failback의 전제**
- 가중치 복귀는 **맨 마지막**: 데이터 재동기화 전에 트래픽이 ROSA로 가는 것을 막기 위해서다
- 가중치만 되돌리는 방식으로는 복귀할 수 없다: DR 기간 `db-primary`에 RDS에 없는 독자 GTID가 쌓이므로(10/16 실측 1,645건), 복제를 그대로 재개하면 두 이력이 합쳐질 위험이 있다
## 2. 순서 (10/16 T8 실제 순서 기준)
 
| # | 단계 | 담당 | 네트워크 확인 (희재) |
|---|---|---|---|
| 0 | 가중치 **ROSA 0 / 온프렘 1 고정** 상태 확인 (DR 런북 8번 완료) | 희재 | 권한 DNS = onprem, HC_ROSA `Inverted=False` |
| 1 | ROSA 복구 확인 (Router·Backend 정상) | 예린 | `primary-health` routing 200 — **트래픽은 여전히 온프렘** (가중치 0이므로) |
| 2 | Plan-only 1차(사전 검증): `operation`·`rosa-on` 각각 | 예린 | 기대값 `0 add / 2 change / 0 destroy`, 알람 no-op |
| 3 | RDS 수동 스냅샷(재동기화 전 RDS 상태 보존, 별도 복구 지점) | 정현 | — |
| 4 | 온프렘 쓰기 차단(온프렘 Fence=true, gitops PR) → **실제 쓰기 503 확인 = T_freeze** | 정현 | 관측 시작 확인(HC_ROSA·HC_DR·터널·probe), T_freeze 시각 기록 |
| 5 | `db-primary` 최종 증적·일관 백업 (DR 기간 독자 GTID·업무 데이터 보존 수단) | 정현 | — |
| 6 | **5번 동결 백업으로 RDS 재시드**(백업 복원) → **RDS 단일 Writer 확정** | 정현 | 없음 (백업 복원이라 온프렘 ↔ RDS 복제 연결을 쓰지 않음) |
| 7 | RDS 기준으로 온프렘 **두 DB 모두** 재시드 → RDS → db-primary, RDS → db-replica **직접 복제** 구성 | 정현 | **db-primary·db-replica 각각 → RDS 3306** (`data-to-aws` + DB VM 경로) → 두 DB에서 `check_db_rds_path_1013.sh` OK (#96) |
| — | **DB 게이트**: 세 DB 행 수 일치, 온프렘 2대 `read_only=1`, 복제 IO/SQL Yes·Lag 0 | 정현 | 게이트 통과 공유 전 8번 이후 진행 금지 |
| 8 | DB 게이트 통과 후 **ROSA 쓰기 차단 해제**(ROSA Fence=false, gitops PR) → 해제 상태에서 ROSA NLB **직접** 검증(로그인·조회·저장) | 예린·정현 | ROSA → RDS 3306 (RDS SG ROSA /20) |
| 9 | Plan-only 2차(Apply 직전) → 정현·예린 승인 + **희재 네트워크 GO** | 예린·정현·희재 | 변경은 `app_weighted["onprem"]` 1→0, `["rosa"]` 0→1뿐, 알람 no-op. 네트워크 GO 기준은 3장 |
| 10 | **가중치 복귀 ROSA 1 / 온프렘 0** (Traffic Failback) PR 병합 → Apply | 희재·예린 | 아래 3장 |
| 11 | 공개 도메인 k6(로그인·조회·저장) + 웹 UI 저장 후 새로고침, 최종 복제 확인 | 정현·희재 | probe `weights <csv> 100` → 권한 DNS rosa 100% |
 
- **실제 데이터 흐름 (10/16 T8)**: 6번 = `db-primary` 동결 백업 → RDS 복원 / 7번 = RDS → 온프렘 두 DB 재시드 후 직접 복제. 실제로 쓴 복제 연결은 **7번 한 방향(접속 On-Prem → RDS 3306)** 뿐이다
- 7번 복제 구성 (정현 #107 정정, 현재 main Ansible·실제 운영 상태와 같음): **RDS → db-primary, RDS → db-replica 각각 직접 복제**. 두 DB 모두 RDS로 연결을 열므로 두 DB 모두 경로·3306 점검 대상 (#96에서 db-replica만 경로가 빠져 있던 사례) → 7번 전에 경로 점검 스크립트 필수
- **대안 (T8에서 사용하지 않음)**: 6번을 백업 복원 대신 복제(데이터 On-Prem → RDS)로 맞추는 경우, 접속 방향이 **RDS → On-Prem 3306**(`aws-to-data`, RDS가 연결을 엶, 이관 단계와 같은 방향)이라 7번과 연결을 여는 쪽이 반대가 된다. 이때는 양방향 3306 경로를 모두 점검한다
- DR 시 단일 Writer로 수동 승격하는 대상이 db-primary라는 원칙(DR 런북)은 이와 별개
- 보존 수단 구분: DR 기간 독자 GTID·업무 데이터는 **5번 `db-primary` 동결 백업**으로 보존한다. 3번 RDS 스냅샷은 재동기화 전 RDS 상태만 담으며 DR 기간 변경분은 포함하지 않는다
- DB 게이트의 행 수 일치(10/16 실측 세 DB `infraready` 6,448행)는 **행 수 기준**이며, 데이터 내용 전체 일치는 확인 범위 밖이다
- 3번 RDS 수동 스냅샷은 Terraform 밖 리소스라 destroy로 지워지지 않는다 → destroy 전에 보존·삭제 여부 결정(정현), 비용 확인
### 하드 스톱
 
- **하드 스톱 = T_freeze(4번) + 90분.** 초과하면 병합·Apply 없이 현재 상태를 유지한다(정현 판단)
- T_freeze는 **실제 쓰기 503을 확인한 시각**으로 정한다. 사전에 입력한 시각은 쓰지 않는다
- 7번(재시드)부터는 온프렘 데이터가 덮어써져 "DR 상태 유지"로 되돌릴 수 없다
- 10/16 실측 기록(절차와 구분): T_freeze 17:19:24(당시 공유된 관측 시각) → 하드 스톱 18:49:24, 실제 종료 약 18:30. 공개 경로 PATCH 503 원본 증적은 확보하지 못했다(T8 결과 5장)
## 3. 10번 가중치 복귀 (희재)
 
### 네트워크 GO (9번에서 희재가 공유)
 
| 확인 | 기준 |
|---|---|
| 권한 DNS | 현재 onprem (DR NLB IP) |
| HC_ROSA·HC_DR | 둘 다 Healthy |
| VPN | ESP 2, `check_vpn_state` FAIL 0 |
| probe | `rosa`·`dr` 200 유지, 관측 창(HC·터널·probe) 기록 중 |
| Plan | 변경이 가중치 2개뿐, 알람 no-op (예린 결과 확인) |
 
→ 모두 충족하면 "네트워크 GO"를 공유. 하나라도 어긋나면 병합하지 않는다
 
### 가중치 PR (예시)
 
```bash
# DevOps VM (heejae) — 예시: 가중치가 ROSA 0 / 온프렘 1인 상태에서만 실행
# (현재 main은 이미 ROSA 1 / 온프렘 0이라 그대로 실행하면 변경 0)
cd ~/neuroplan-aws-migration && git switch main && git pull --ff-only
git switch -c feature/route53-failback-1-0-$(date +%m%d)
sed -i -E 's/^rosa_weight( *)= *[0-9]+/rosa_weight\1= 1/; s/^onprem_weight( *)= *[0-9]+/onprem_weight\1= 0/' \
  envs/prod/operation.tfvars envs/prod/rosa-on.tfvars
git diff --stat && grep -nE '^(rosa|onprem)_weight' envs/prod/operation.tfvars envs/prod/rosa-on.tfvars && (cd envs/prod && terraform fmt -check -diff)
git add envs/prod/operation.tfvars envs/prod/rosa-on.tfvars && git commit -m "feat(edge): Route 53 Failback — ROSA 1 / 온프렘 0" && git push -u origin HEAD
```
- 두 파일(`operation.tfvars`·`rosa-on.tfvars`)을 **함께** 1/0으로 되돌림 (DR 런북 8번 #118과 같은 이유: 어느 파일로 Plan/Apply해도 같은 값). 10/16 실제 PR #133도 두 파일을 함께 변경
- Plan 기대값 (예린 `operation`·`rosa-on` 각각): `app_weighted["rosa"]`·`["onprem"]` **2 change (weight만)**, 그 외 0. 알람(네트워크·RDS) no-op
- 가중치 전환만으로 DB Writer가 복귀하지 않음: 2~9번을 모두 마친 뒤에만 진행
- Route 53 weight 0은 절대 차단이 아님 (DR Target이 전부 비정상이면 ROSA가 응답 후보). 그래서 **DB 게이트 통과 전까지** ROSA 쓰기 차단(`DEMO_WRITE_FENCE=true`)을 유지하고, 게이트 통과 후 8번에서 해제한 다음 직접 검증한다
- 병합 조건: 9번 Plan-only 2차 결과 공유 + 정현·예린 승인 + 희재 네트워크 GO, 하드 스톱 이내
- 확인: 권한 DNS = ROSA NLB IP (`dig +short app.neuroplan.cloud @<awsdns NS>`), HC 2개 Healthy, probe `rosa`·`dr` 200
- 10/16 실측: 병합 → 권한 DNS 전환 약 5분 13초 (Apply 약 35초, Apply 종료 → DNS 최초 전환 약 9초)
## 4. 중단 기준
 
어느 단계에서 멈추는지에 따라 되돌릴 수 있는 범위가 다르다. 10/16 T8은 문제 없이 끝나 롤백을 실제로 쓰지 않았고, 아래 **롤백 방식은 팀 합의 전 제안**이다(T8 결과 문서 5장).
 
| 상태 | 멈추는 조건 | 조치 |
|---|---|---|
| **재시드 전** (0~6번) | 하드 스톱 초과 / 6번 백업 복원 실패 / RDS Writer 확정 검증 불일치 | 병합·Apply 없이 현재 상태 유지. 가중치 온프렘 1 유지. 제안: 온프렘 Fence 해제로 DR 상태 복귀(5번 동결 백업 있음) |
| **재시드 후** (7~9번) | 하드 스톱 초과 / 7번 역복제 연결 실패 / DB 게이트 불일치 / 8번 ROSA 직접 검증 실패 / 9번 Plan이 2 change 외 변경 포함 / 네트워크 GO 미충족 | 병합·Apply 금지, 가중치 온프렘 1 유지. 7번 연결 실패는 경로 점검(`check_db_rds_path_1013.sh`, Infra `setup_db_to_rds_1013.sh verify`) 후 재시도. 온프렘은 이미 덮어써져 DR 상태로 되돌릴 수 없음 → 제안: fail-forward(ROSA 쪽 수정) 또는 읽기 전용 폴백 중 택일 |
| **가중치 복귀 후** (10번 이후) | ROSA 쪽 오류 | **가중치만 0/1로 되돌리는 것은 단독 롤백이 아님**: 온프렘 DB가 `read_only=1`이라 쓰기가 실패한다. 온프렘 쓰기 재개 금지(정현 판단), ROSA 쪽 수정 우선 |
 
## 5. 발표 설명 (발표증적 5.6)
1. 1차와 다른 점 ① 데이터 역방향 재동기화(관리형 RDS ↔ 직접 구축 MariaDB, GTID) ② 인터넷 DNS 캐시 때문에 잠시 두 사이트에 요청이 나뉠 수 있음 ③ HC 자동 복귀 위험 → 첫 단계가 가중치 고정
2. 문장: "넘어갈 때는 자동, 돌아올 때는 일부러 수동"
3. 순서: **동결 → 보존 → 재시드 → ROSA 재개 → DNS 복귀**, 하드 스톱 90분 안에 게이트를 통과할 때만 복귀
4. 네트워크 관점: T8은 백업 복원 + 역복제(온프렘 → RDS 3306) 한 방향을 썼고, 복제로 맞추는 대안을 쓰면 **양방향 3306 경로**가 필요하다 → 10/13 #96에서 역복제 방향 누락을 사전에 발견·보완
