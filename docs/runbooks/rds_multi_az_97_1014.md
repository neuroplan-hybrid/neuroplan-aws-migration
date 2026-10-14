# #97 RDS Multi-AZ 적용 전후 확인

## 상태와 범위

이 문서는 Draft PR 검토용이다. Merge/Apply 승인이 아니다.
운영 tfvars 두 파일의 `rds_multi_az=true`와 기존 RDS 이벤트 구독의
`failover` 추가만 제안한다. 기존 availability/failure/maintenance, SNS,
CloudWatch 알람 임계값, 백업 7일, Final Snapshot 설정은 유지한다.
PoC/Single-AZ에는 failover 구독을 추가하지 않는다.

Multi-AZ는 별도 AZ의 동기식 standby를 이용한 운영 HA이다. 읽기 분산용
replica가 아니며, 기존 #63의 T3 PITR(신규 #123 제안의 T4) 데이터 복구를 대체하지 않는다.
**#122의 Terraform 변경 자체에는 강제 Failover·reboot·GTID reset·Writer 승격·Route 53 전환이 없다.**
그러나 DB 담당이 #123의 **신규 T3 통제 RDS Failover 시연 포함에는 조건부 동의**했다(#122 댓글 6166356556). 
실제 장애 주입은 Multi-AZ Apply/안정화와 별도의 전원 GO가 필요하다.

## 적용 순서 개편 제안 및 Merge/Apply 전 GO

**최신 정정 기준의 순서 제안: Master_Host 확인·새 운영 Plan → 적용 직전 GO → #122 Merge·최신 main Plan·Multi-AZ Apply → 10분 연속 안정화 → T1·T2 → 기존 T4 VPN 본 시연(신규 T5)·정상 복귀 → 인증서/DR 사전 확인 → 기존 T5 Site DR(신규 T6).** 통제 RDS Failover의 실제 배치·작업 창은 별도 합의한다. 이 순서는 희재님의 정정 댓글 6166803565를 반영한 **팀 검토안**이며, 플랫폼 일정 확인 없이 확정하지 않는다.
기존 런북의 “#118 T5 이후 #122 적용” 조건을 변경하는 방향으로 **DB 담당은 조건부 동의**했다. **네트워크 담당의 최종 순서 동의, 플랫폼 GO, 작업 창·비용·복구 담당 확정은 아직 필요**하므로 이 문서 수정만으로 적용 권한은 생기지 않는다.

### 순서와 역할

1. **문서·PR 순서 변경 리뷰:** 운영 Route 53은 **ROSA 1 / 온프렘 0**을 유지하고 **#118은 Draft**로 남긴다.
2. **시연 순서 재확인:** 희재님의 정정에 따라 T1·T2 및 VPN T4 본 시연을 Multi-AZ Apply 선행 조건으로 두지 않는다. **Multi-AZ 적용·10분 안정화 후 T1·T2, 그 뒤 VPN T4 본 시연을 진행하는 안**을 플랫폼/DB/네트워크 담당이 검토·확정한다. VPN 본 시연은 Multi-AZ 상태 기준으로 기록한다. **10/14 11:34 VPN 실행은 리허설이며 본 시연 완료로 간주하지 않는다.** 두 터널·복제·DR 경로 정상 복귀 후 사이트 DR로 넘어간다.
3. **적용 직전 GO:** DB·네트워크·플랫폼 승인, 최신 RDS/역복제/Backend/네트워크 기준선, 추가 비용·작업 시간·중단 및 복구 담당 확인.
4. **#122 Merge 후 main 기반 최종 Plan·Apply:** 먼저 PR HEAD의 최신 운영 Plan을 검토한다. **적용 직전 GO가 확인된 작업 창에서 #122를 Merge하고**, 병합된 최신 main/실제 운영 State와 #115 알람 ON 입력으로 두 tfvars의 최종 Plan을 새로 생성·검토한다. 예상되는 기존 RDS Multi-AZ와 이벤트 구독의 **두 in-place update만** 확인된 **승인 Plan**으로 지정 실행자가 Apply한다. 브랜치에서만 Apply하고 main을 false로 남기는 방식은 금지한다. Merge 자체가 Apply/강제 Failover 실행은 아니며, 다른 Apply도 이 작업 창에 섞지 않는다. 기존 saved Plan은 재사용하지 않는다.
5. **안정화:** RDS MultiAZ/서로 다른 Primary·Secondary AZ, DB 복제 2대, Backend/외부 경로 등 아래 **30초 간격 10분 연속** PASS.
6. **통제 Failover는 별도:** 신규 #123 T3의 **실제 실행 위치와 작업 창은 아직 확정하지 않는다.** 시연 포함과 실제 주입 승인은 **별개**. 안정화 후 DB 주도·복구 담당·측정 기준·전원 GO가 있어야만 실시. 두 온프렘 DB 복제와 서비스 완전 정상화 뒤 다음 시연.
7. **사이트 DR:** 다른 장애(플랫폼·VPN·TLS 포함) 정상 복구 후 기존 **T5 Site DR(신규 #123 T6)** 진행. **#118의 8번 Merge/Apply는 정현님의 온프렘 사용자 쓰기 재개 `T_write_resume` 확인·공유 이후**, 팀 GO 및 최신 운영 Plan 재검증 후에만 실행한다.

### 적용 직전 필수 체크

- [ ] 네트워크·플랫폼의 **Multi-AZ 선적용 순서 동의** 및 DB 포함 적용 직전 GO 확인. #118 Draft 상태.
- [ ] 작업 창·추가 비용·중단 기준·DB/네트워크/플랫폼 복구 담당 및 종료 일정 확인. 기존 **10/15 15:00 GO 마감**, **17:00 미안정 시 강제 Failover 생략·사이트 DR 독립 GO 판단**, 필요 시 **10/16 10:00 재확인**, **10/16 18:00 destroy** 기준 유지.
- [ ] **ROSA 1 / 온프렘 0**, 현재 RDS Writer 단일 쓰기 경로·RDS `available`, Pending 변경 없음.
- [ ] 온프렘 **db-primary·db-replica 두 대** `read_only=1`, IO/SQL **Yes**, lag **0**, 새 복제 오류 없음, GTID 진행·마지막 테스트 데이터 반영 확인.
- [ ] 정현 측 읽기 전용 조회·희재 검토: 두 DB `SHOW SLAVE STATUS\G`의 **Master_Host가 현재 RDS Endpoint 호스트명**인지 확인. [정현 측 실제 조회 결과](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/122#issuecomment-6166771567)는 두 DB 모두 DNS 호스트명, IO/SQL Yes, lag 0, 마지막 오류 빈 값이다. 이는 해당 조회 시점 증적이며 **Apply 직전 재확인**한다. 고정 IP/불일치면 STOP. 계정 전달이나 설정 변경은 필요하지 않으며 이 항목만으로 전체 GO가 되지 않는다.
- [ ] ROSA Backend **Ready 2/2**, DB 연결·재시도 상태와 로그인→조회→저장 기준선 정상.
- [ ] 두 DB `check_db_rds_path_1013.sh` **exit=0**, `check_vpn_state_0930.sh --aws` **FAIL 0**, ROSA·DR probe HTTP **200**, 외부 3경로 PASS. **#116** 측정 스크립트로 적용 전부터 기록.
- [ ] 최신 **main·#122 HEAD·State·입력**에서 양쪽 tfvars Plan 재생성. 기존 **#115 비공개 알람 ON 입력** 및 실제 auto.tfvars 유지. 리소스 0 add / 2 update / 0 destroy, 변경 필드는 `multi_az: false→true`와 이벤트 `failover` 추가뿐이어야 한다. **DB 교체·다른 변경·알람 삭제·Route 53 변경 시 STOP**.
- [ ] 승인된 saved Plan·commit SHA·운영 입력/State 기준을 기록하고 **지정 실행자**만 별도 Apply한다. 민감 변수·State/Plan 원문은 Git·댓글에 게시하지 않는다.

**#118 후속:** Multi-AZ 적용 뒤에는 #118을 **최신 main/State**에 맞춰 재검증하여 두 tfvars에 `rds_multi_az=true`, 기존 #115 알람 ON, 유효한 RDS 설정이 유지되도록 한다. #118의 가중치 변경만 승인된 단계에서 반영하고, **`T_write_resume` 이전 Merge/Apply를 하지 않는다.**

**주의:** 두 tfvars의 `rds_apply_immediately=true`가 이미 설정돼 있어 병합 뒤 일반 Terraform Apply에도 Multi-AZ 전환이 포함될 수 있다. 위 게이트 충족 전에는 **Draft·Merge/Apply 보류**, 백업/스냅샷 보존 정책과 종료 일정은 그대로 둔다.

### 적용 시작 시한 제안

- **10/15 15:00 전 팀 GO, 15:30까지 실제 Apply 시작**을 제안한다. DB·네트워크·플랫폼이 작업 창에서 명시적으로 확인해야 확정된다.
- 미시작 상태에서 확정한 시작 시한을 넘기면 해당 작업 창의 Apply를 보류하고 DR 우선 일정/범위를 다시 합의한다.
- 15:30 시작은 17:00 완료 보장이 아니다. 이미 시작한 AWS 변경은 임의 취소·Single-AZ 원복하지 않고 상태·복제·서비스를 관찰한다.

### 17:00 이후 우선순위

- **10/15 17:00까지 Multi-AZ 안정화 미완료이면 신규 T3 통제 Failover는 생략**하고 P0인 기존 T5(신규 T6) Site DR 준비를 우선한다. 미실행 Failover를 PASS로 표시하지 않는다.
- DR은 Multi-AZ 시연 완료 여부와 독립적으로 판단한다. RDS available·Backend 정상, 두 온프렘 DB read_only=1·GTID catch-up·IO/SQL Yes·lag 0·새 오류 없음, 두 VPN/DR NLB·TLS/외부 경로 정상 및 기존 DR 승격/측정/복구 담당 조건을 **모두** 확인하고 전원 GO를 받은 경우만 진행한다.
- RDS 전환 중, 복제·쓰기·VPN·TLS 장애가 남았다면 Failover를 생략해도 **DR NO-GO**다. DB와 무관한 비필수 항목만 미완료일 때도 필수 게이트를 우회하지 않는다.
- 당일 DR 게이트 미충족이면 10/16 오전에 재확인한다. **10:00까지 미충족이면 시연 범위 축소/DR 보류**, **18:00 destroy**는 유지한다.
- 이미 완료된 Multi-AZ를 임의 Single-AZ로 되돌리거나 진행 중인 AWS 변경을 임의 취소하지 않는다.

## 최종 Plan

플랫폼의 기존 사전 Plan은 DB 1개 변경이었다. 이 PR에는 이벤트 구독 변경이
추가되므로, 현재 알려진 State 기준 기대값은 **0 add / 2 change / 0 destroy**:
DB `multi_az: false → true`, 이벤트 구독 `failover` 추가.
2026-10-14 플랫폼 담당은 **최신 검증 HEAD `6e2fc46`**에서 두 tfvars 모두
**0 add / 2 update / 0 destroy**, 변경 필드는 **RDS `multi_az`와 기존 이벤트 구독 `event_categories`뿐**이며
교체/추가/삭제 및 다른 변경이 없음을 운영 State 기반 **Plan-only**로 확인했다.
앞선 `a0912aa`의 두 tfvars 검증과 CI 성공도 별도 기록됐다.
이 결과는 **적용 직전 GO 및 승인된 saved Plan이 아니다**. 변경된 HEAD/운영 State/입력에 맞춰
다시 Plan하고 과거 saved Plan을 재사용하지 않는다.

두 파일 모두 기존 운영 private 입력을 그대로 사용해야 한다.
특히 `network-alarms-on.tfvars.json`은 향후 활성화 예정 파일이 아니라,
**#115의 네트워크 알람 4개 활성화에 이미 사용한 운영 비공개 입력**이다.
플랫폼 담당의 #122 Plan-only 검증에서도 이 파일을 명시적으로 포함했다.
이 파일과 실제 운영 auto.tfvars 등 현재 적용에 사용한 입력을 누락하지 않는다.
private 입력은 커밋/출력하지 않는다.
다른 변수로 상태를 덮어쓰거나 예전 worktree의 Plan을 재사용하지 않는다.

다음 차이가 있으면 Apply 중단:

- 4개 VPN/NLB 알람 삭제, 신규 SNS Topic 생성, 기존 구독 제거
- DB 교체/삭제, 엔진/파라미터/클래스/스토리지/백업 변경
- ROSA, Route 53 가중치, HC, VPN, 방화벽 변경
- 위 두 변경 외 예상하지 않은 변경

승인된 정확한 var-file 목록과 commit SHA를 기록하고 saved Plan을 검토한다.
승인된 saved Plan만 플랫폼 담당이 Apply한다. 이 문서 자체로 실행을 승인하지 않는다.

## DB 영향과 적용 전 기록

동기식 standby 전환은 쓰기/commit 지연 및 성능에 영향을 줄 수 있다.
전환을 무중단 보장으로 표현하지 않는다. Multi-AZ failover 시 연결 재수립과
DNS 재해석이 필요할 수 있으며, 외부 GTID 복제의 재연결 성공은 현재 환경에서
확인해야 한다. MariaDB 자동 복구/GTID 연속성을 검증 없이 단정하지 않는다.

승인된 DB 자격 증명을 사용해 각 DB에서 읽기 전용 조회로 기록:

- RDS: available, MultiAZ, AZ/SecondaryAZ, PendingModifiedValues, Endpoint,
  엔진/백업 설정, GTID/binlog 상태, 실제 DB 쓰기 경로
- db-primary / db-replica: `SHOW SLAVE STATUS\G`, IO/SQL Yes,
  Last_IO_Error/Last_SQL_Error, Seconds_Behind_Master, GTID 위치, read_only=1
- Backend: RDS DNS Endpoint 사용 여부, Ready 2/2, `up` 2개=1,
  5xx 비율/응답시간/DB 연결 오류 baseline
- Blackbox 외부 3경로 PASS, RDS 알람/SNS 이벤트 구독 상태

GTID 절대값은 고정하지 않고 시각과 함께 증가/연속성을 비교한다.
비밀번호/토큰/Secrets Manager 응답 원문은 증빙에 넣지 않는다.

## 적용 중/후

전환 중 RDS 이벤트, 상태, 지연, Backend 연결 오류와 두 외부 replica를 관측한다.
쓰기 오류, replication IO/SQL 정지, lag 증가가 지속되면 추가 변경을 중단하고
DB/플랫폼 담당에게 공유한다. 임의 GTID reset, CHANGE MASTER,
재시드, DB 재시작, DNS 전환으로 해결하지 않는다. 복구 조치는 별도 승인한다.

완료 후:

1. RDS `available`, **MultiAZ=true**, 서로 다른 Primary/Secondary AZ, Pending 변경 해소 확인.
2. RDS Endpoint·Backend DB 재연결, Ready **2/2**·스크랩·5xx·로그인→조회→저장 정상 확인.
3. **30초 간격 10분 연속** 두 온프렘 DB `read_only=1`, IO/SQL **Yes**, lag **0**, 새 복제 오류 없음, GTID 진행 및 테스트 데이터 반영 확인. 중간에 실패한 구간은 PASS로 처리하지 않는다.
4. 두 DB 경로 `check_db_rds_path_1013.sh` exit=0, VPN `check_vpn_state_0930.sh --aws` FAIL 0, probe ROSA·DR HTTP 200, 외부 3경로 PASS. #116 측정 기록 보관.
5. 기존 RDS CloudWatch 알람 2개와 #115 네트워크 알람 4개 유지. SNS Topic과 기존 availability/failure/maintenance/**failover** 구독 활성화 확인.

**이상 시 후속 시연 STOP.** 로그·상태 조회와 자동 재연결 관찰을 우선하고 DB·복제·Backend 재시작 및 복제 STOP/START는 원인 확인 후 별도 개별 승인한다. 임의 GTID reset·CHANGE MASTER·재시드·재동기화·Single-AZ 원복은 기본 복구 범위가 아니다.

위 안정화는 **구성/운영 상태 검증**이며 실제 강제 Failover 성공, RTO/RPO, failover 이메일 실수신 증거가 아니다.

### 신규 #123 T3 — 통제 Failover 별도 GO

- **DB 담당이 시연 포함에 조건부 동의**했더라도 실제 주입은 **안정화 PASS 이후 전원 별도 GO**를 받는다.
- DB 담당 주도로 장애 주입 방식, 중단 기준, 복구 담당, 측정/작업 창을 확정한다. **DB User RTO = `T_rds_user − T_rds_inject`**(30초 연속 로그인→조회→저장 성공 구간의 시작 시각)을 사용해 사이트 DR RTO와 분리한다.
- RDS/Backend 서비스 복구와 **온프렘 DB 두 대 GTID·IO/SQL·lag/read_only**가 다시 정상화된 뒤에만 기존 T5(신규 T6) Site DR로 넘어간다.
- 안정화·시간·비용이 부족하면 강제 Failover를 **생략/축소**하되, 성공했다고 표시하지 않는다.

## 오프라인 검증

`terraform -chdir=modules/data test`는 AWS mock provider만 사용한다.
테스트의 `command=apply`도 mock 리소스에만 적용되며 실제 AWS Apply가 아니다.
Single-AZ/Multi-AZ 이벤트, SNS 재사용, 임계값/백업 유지, 비활성 상태를 검증한다.

## 근거

- [AWS Multi-AZ DB instance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZSingleStandby.html)
- [Single-AZ → Multi-AZ 전환](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZ.Migrating.html)
- [Failover 연결 동작](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZ.Failover.html)
- [RDS 이벤트 범주](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_Events.Messages.html)
