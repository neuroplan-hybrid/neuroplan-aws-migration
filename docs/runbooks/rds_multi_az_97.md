# #97 RDS Multi-AZ 적용 전후 확인

## 상태와 범위

이 문서는 Draft PR 검토용이다. Merge/Apply 승인이 아니다.
운영 tfvars 두 파일의 `rds_multi_az=true`와 기존 RDS 이벤트 구독의
`failover` 추가만 제안한다. 기존 availability/failure/maintenance, SNS,
CloudWatch 알람 임계값, 백업 7일, Final Snapshot 설정은 유지한다.
PoC/Single-AZ에는 failover 구독을 추가하지 않는다.

Multi-AZ는 별도 AZ의 동기식 standby를 이용한 운영 HA이다. 읽기 분산용
replica가 아니며, T3 PITR 데이터 복구 검증을 대체하지 않는다.
이번 범위에는 강제 failover, reboot, GTID reset, Writer 승격, Route 53 전환이 없다.

## Merge/Apply 전 GO

- 플랫폼: 최신 State와 이 PR HEAD에서 두 tfvars의 최종 Plan 확인.
- DB 담당: 현재 RDS Writer → db-primary/db-replica GTID 복제 및 Backend 연결 영향 검토.
- 예산/시간: 현재 서울 리전 요금으로 추가 비용 확인, 작업 시간과 중단 기준 합의.
- T1/T2/T5 작업과 겹치지 않는 시간으로 조율. #118 트래픽 전환 PR과 분리한다.

**두 tfvars의 rds_apply_immediately는 이미 true이다.** 이 PR을 병합하면
이후 정상 운영 Apply에도 Multi-AZ 전환이 포함되므로, 검토 중에는 Draft를 유지한다.
백업/스냅샷 보존 정책과 종료 일정은 바꾸지 않는다.

## 최종 Plan

플랫폼의 기존 사전 Plan은 DB 1개 변경이었다. 이 PR에는 이벤트 구독 변경이
추가되므로, 현재 알려진 State 기준 기대값은 **0 add / 2 change / 0 destroy**:
DB `multi_az: false → true`, 이벤트 구독 `failover` 추가. 이는 실제 Plan 결과가 아니다.

두 파일 모두 기존 운영 private 입력을 그대로 사용해야 한다.
특히 #115 활성화에 사용한 `network-alarms-on.tfvars.json` 및 실제 운영
auto.tfvars를 누락하지 않는다. private 입력은 커밋/출력하지 않는다.
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
1. RDS available / MultiAZ=true / 다른 AZ의 SecondaryAZ / Pending 변경 해소 확인.
2. 동일 Endpoint와 Backend 연결/Ready/스크랩/5xx/응답시간 확인.
3. 두 온프렘 DB read_only=1 및 IO/SQL Yes, lag 수렴, 오류 없음, GTID 진행 확인.
4. 외부 3경로 PASS와 기존 4개 네트워크 알람 유지 확인.
5. 기존 SNS Topic에 availability/failure/maintenance/failover 구독 활성 상태 확인.

위 확인은 구성 전환 확인이다. 실제 장애 발생·복구, 강제 failover 성공,
RTO/RPO 또는 failover 메일 실수신 증거로 대체하지 않는다.
failover 테스트가 필요하면 담당자 GO 후 별도 수동 테스트로 진행한다.

## 오프라인 검증

`terraform -chdir=modules/data test`는 AWS mock provider만 사용한다.
테스트의 `command=apply`도 mock 리소스에만 적용되며 실제 AWS Apply가 아니다.
Single-AZ/Multi-AZ 이벤트, SNS 재사용, 임계값/백업 유지, 비활성 상태를 검증한다.

## 근거

- [AWS Multi-AZ DB instance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZSingleStandby.html)
- [Single-AZ → Multi-AZ 전환](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZ.Migrating.html)
- [Failover 연결 동작](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZ.Failover.html)
- [RDS 이벤트 범주](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_Events.Messages.html)
