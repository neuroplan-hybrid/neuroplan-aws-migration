# T3 RDS Multi-AZ Failover — 2026-10-15 실측 결과

> **결과:** 통제 Failover 1회 후 AZ 전환, 사용자 요청 복구, 두 온프렘 DB의 정상 복제 상태를 확인했다.
> **User RTO: 12.6초.** 본 시연의 보고 기준 T0는 팀에 공유한 **AWS Failover 시작 이벤트 시각 19:05:02.313 KST**로 채택한다. 로그인·조회·저장 안정 복구 구간 시작은 19:05:14.866 KST다.
> **관측 범위:** 로그인 타임아웃 2건이 있어 무중단/실패 0건 시험은 아니다. 행 내용 정합성 전체 검증이나 RPO=0을 입증하지 않는다.

## 1. 범위와 실행 환경

- 신규 번호는 [통합 시연 제안 #123](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123)의 **T3 RDS Multi-AZ Failover**를 따른다. 기존 번호의 T3 PITR과 구분한다.
- 대상: 서울 리전 `ap-northeast-2`, RDS MariaDB `neuroplan-rds-operation`.
- DB·네트워크·플랫폼 준비 확인 및 팀 GO를 공유받은 뒤 실행했다. 새로운 장애 주입 승인을 이 문서로 대신하지 않는다.
- DevOps에서 `aws rds reboot-db-instance --force-failover` **1회** 실행, AWS 응답에서 `rebooting` 확인.
- 측정: Infra VM k6 v0.54.0, 전용 웹 테스트 계정 **1 VU**, `LOGIN_MODE=iter`, Step 1 완료 상태 토글. 로그인 → 상태 조회 → 저장을 반복한다.
- DB: db-primary와 db-replica에서 기존 `record_t4_replication.sh 1200` 사용. 구번호 파일명이지만 내용은 복제 상태의 읽기 전용 관측이다.
- 이 PR은 **결과 문서 1개만 추가**한다. 실제 시연은 사전에 별도로 수행했으며, PR 작성 과정에서 AWS·DB·Terraform·GitOps·VPN·방화벽·Grafana 설정은 변경하지 않았다.

## 2. 사전 점검

| 항목 | 확인 결과 |
| --- | --- |
| RDS | available, MultiAZ=true, Primary `ap-northeast-2c`, Standby `ap-northeast-2a`, PendingModifiedValues={} |
| k6 1분 시험 | 37회 로그인·조회·저장, HTTP 111요청 실패 0건, checks 148/148 성공 |
| 두 DB 복제(18:52 KST) | IO/SQL Yes, lag 0, 오류 번호 0, read_only=1, Applied GTID 일치 |
| 두 DB 경로 | db-primary 18:56:08 / db-replica 18:56:11 KST, 기존 점검 스크립트 각각 exit=0 |
| 네트워크 | 희재 측 GO: VPN FAIL 0·ESP 2, HC_DR 16 Success, app·rosa·dr probe HTTP 200 |
| 플랫폼 | 사용자 전달 기준 예린 측 GO 확인. 플랫폼 명령 원문은 이 결과 문서에 포함되지 않는다. |
| 시각 동기화 | Infra VM NTPSynchronized=yes 확인. 장애 요청 PC와의 실제 시각 차이를 별도 수치로 검증한 증적은 없음 |

### 별도 사전 이슈: DevOps SQL 호스트 차단

DevOps 출발지의 RDS SQL 접속에서 1129 응답이 관측됐다. Monitoring Prometheus의 `devops-rds-tcp` job을 주석 처리하고 설정 검사·reload 후 활성 설정에서 제거된 것을 확인했다. 다른 Blackbox 검사 및 서비스 전체는 중단하지 않았다.

db-primary를 통한 TLS 검증된 RDS 관리자 연결에서 `FLUSH NO_WRITE_TO_BINLOG HOSTS`를 실행한 뒤, DevOps의 SQL 조회 성공을 확인했다. 이 작업은 RDS 전체 호스트 캐시 초기화이며 데이터 삭제·DB 재시작은 아니다.

원인 후보는 같은 출발지의 반복 TCP 검사다. 인증 없이 종료되는 연결이 30초 간격으로 기록됐지만, 정확한 host cache 행/카운터가 조회되지 않았으므로 **원인 확정은 하지 않는다**. 이 문제를 온프렘 두 DB 복제 장애로 간주하지 않는다. 해당 TCP 검사는 중단 상태로 유지하며 무조건 재활성화하지 않는다.

## 3. 실제 타임라인 (2026-10-15 KST)

| 시각 | 관측/실행 내용 |
| --- | --- |
| 19:02:29.737 | k6 프로세스 시작 로그 |
| 19:02:30.358 | k6 CSV의 첫 step_ok 표본 |
| 19:02:35 | db-replica 본 기록 시작 |
| 19:02:39 | db-primary 본 기록 시작(로그 파일명/기록 종료 증적 기준) |
| **정확한 시각 미기록** | DevOps Failover 요청. 직전 `date --iso-8601=milliseconds`가 지원되지 않아 실패했으나, 후속 AWS 명령은 실행되어 rebooting 응답 반환 |
| **19:05:02.313 (T0)** | AWS 이벤트: Multi-AZ instance failover started. 본 시연 보고의 T0로 채택 |
| 19:05:04.118 | k6 첫 실패 표본(로그인 타임아웃). 요청 시작/DB 중단 시각이 아니라 결과 기록 시각 |
| 19:05:13.647 | AWS 이벤트: DB instance restarted |
| **19:05:14.866** | CSV 분석기: 마지막 실패 후 로그인·조회·저장 30초 연속 성공 구간의 시작 |
| 19:05:14.955 | 위 복구 구간의 첫 성공 저장 표본 |
| **19:05:20.982** | AWS 이벤트: Multi-AZ instance failover completed / The user requested a failover of the DB instance |
| 19:06:38.770 | DevOps 조회 시각. RDS available, Primary 2a / Standby 2c 확인 |
| 19:07 및 19:10 | 두 DB 최신 표본에서 복제 정상·GTID 진행 확인 |
| 19:11:05.475 | k6 CSV 마지막 step_ok 표본 |
| 19:11:06.197 | k6 teardown 종료 로그. Ctrl+C로 수동 종료 |
| 19:11:07 | db-replica 기록 종료 |
| 19:11:09 | db-primary 기록 종료 |

AWS의 `The user requested...` 이벤트는 완료 이벤트와 동일한 시각에 기록됐으므로 T0로 사용하지 않는다. 본 보고는 AWS Failover 시작 이벤트를 T0로 사용한다. 사용자 성공 복귀가 AWS 완료 이벤트보다 앞선 것은 서로 다른 관측 기준이며, 둘을 동일한 시각으로 맞추거나 보정하지 않는다.

### T0 정의와 복구 시간

- **AWS 이벤트 간 Failover 소요:** 19:05:20.982 − 19:05:02.313 = **18.669초**.
- **본 시연의 보고 T0:** 사용자 요청에 따라 팀에 공유한 AWS Failover 시작 이벤트 시각 **19:05:02.313 KST**를 채택한다.
- **User RTO = T_user − T0:** 19:05:14.866 − 19:05:02.313 = **12.553초(보고값 12.6초)**.
- 이 지표는 **AWS Failover 시작 이벤트 → 사용자 안정 복구 구간 시작**으로 정의한다. CLI 명령 실행 직전 시각은 별도로 미기록이며, AWS 이벤트 시각을 그 시각으로 소급 주장하지 않는다.
- k6 안정 복구 구간 시작 이후 CSV 종료까지 **350.609초(약 5분 50초)**, 추가 실패 표본 없음.
- k6는 20분 설정이지만 Ctrl+C 종료했다. CLI 실행 약 **8분 36.5초**, CSV 첫~마지막 step_ok 구간은 **8분 35.117초**다. 20분 완주로 보고하지 않는다.

## 4. k6 결과

| 단계 | step_ok 표본 | 실패 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: |
| 로그인 | 310 | **2** | 626 ms | 1,099 ms |
| 상태 조회 | 308 | 0 | 31 ms | 57 ms |
| Step 저장 | 308 | 0 | 40 ms | 54 ms |
| 합계 | **926** | **2** | 단계별 참조 | 단계별 참조 |

- 전체 step_ok 성공 **924/926**, 실패율 약 **0.22%**. 실패는 로그인 요청 타임아웃 2건이다.
- CLI checks는 **1,232/1,234** 성공이다. 상태 조회 1요청에 2개 check가 있어 요청 수와 동일하지 않다.
- 마지막 장애 전 성공 저장: **19:04:58.114**, completed=True.
- 안정 복구 구간의 첫 성공 저장: **19:05:14.955**, completed=False.
- 성공 응답 연결 IP는 CSV 분석상 한 주소였다. 이는 DB Writer 식별/전체 DNS 이력/모든 사용자 무중단의 증거가 아니다.
- 단일 테스트 계정의 1 VU 결과로 전체 사용자·다중 사용자 부하·사이트 전체 HTTP 5xx 결과를 일반화하지 않는다.
- `Ctrl+C`에 따른 interrupt/aborted 메시지는 측정 중단이며 추가 애플리케이션 장애로 세지 않는다. CLI에는 309 complete / 1 interrupted iteration이 표시됐다.
- 분석기에서 T0→복구 구간의 state/save가 0건인 것은 구간 끝이 첫 성공 로그인 시각이기 때문이다. 직후의 성공 조회·저장은 전체 CSV 및 첫 저장 시각으로 확인한다.
- `step_ok` 체크는 HTTP 응답/플랜 식별 기준이다. 저장 데이터가 DB에서 정확히 재조회되는지, RPO=0인지는 별도 DB 증적이 필요하다.

### 재분석 명령 (Infra VM)

```bash
python3 /root/k6_rto_summary_1007.py \
  /root/k6_t3_20261015-190229.csv \
  --t0 "2026-10-15T19:05:02.313+09:00" \
  --mode rto
```

위 입력은 본 보고에서 채택한 T0(AWS Failover 시작 이벤트)와 동일하다. 분석기의 `User RTO` 결과 **12.6초**를 본 시연 보고값으로 사용하며, 측정 기준을 함께 표기한다. 자동 분석기의 RPO 관련 안내만으로 데이터 무손실을 판정하지 않는다.

## 5. 두 온프렘 DB 전체 기록 분석

| DB | 기록 구간(KST) | 표본 | 조회 오류 | 정상 조건 이탈 표본 | 최대 숫자 lag |
| --- | --- | ---: | ---: | ---: | ---: |
| db-primary | 19:02:39 ~ 19:11:09 | **492** | **0** | **0** | **0초** |
| db-replica | 19:02:35 ~ 19:11:07 | **493** | **0** | **0** | **0초** |

전체 로그를 읽어 다음 조건을 검사했다: QUERY_OK, IO/SQL=Yes, Seconds_Behind_Master=0, Last_IO_Errno=0, Last_SQL_Errno=0, Read_Only=1. 정상 조건 이탈 시 해당 줄을 출력하도록 분석했고 두 DB 모두 ABNORMAL=0이었다. 종료 표본의 IO/SQL 오류 메시지도 비어 있었다.

- 종료 Applied GTID는 두 DB 모두 **`0-1822967101-3152,1-1-3076`**.
- 기록 중 GTID 진행을 관측했다. 종료 시 일치가 전체 행 내용의 일치나 모든 트랜잭션 무손실을 증명하는 것은 아니다.
- 각 조회 후 1초 대기하는 폴링이다. **표본 사이의 짧은 연결 중단·자동 재연결을 놓칠 수 있으므로, 실제 연결이 한 번도 끊기지 않았다고 주장하지 않는다.**
- 약 19:07부터의 정상 복제 표본과 k6 복구 구간 이후에도 3분 이상 추가 관측했다.
- IO/SQL 정지·lag NULL·1129·쿼리 오류는 분석 표본에서 관측되지 않았다. 복제 RESET/CHANGE MASTER/재시드/온프렘 승격은 수행하지 않았다.

## 6. 증적 보관과 현재 종료 상태

| 위치 | 원본 파일 |
| --- | --- |
| Infra VM | `/root/k6_t3_20261015-190229.csv` |
| db-primary | `/home/dbadmin/repl_t4_db-primary_20261015-190239.log` |
| db-replica | `/home/dbadmin/repl_t4_db-replica_20261015-190235.log` |

원본은 각 VM에 보관하며 **이 PR에는 첨부하지 않는다**. 본 문서는 실행자가 공유한 출력·분석 결과를 정리한 것이며 작성 과정에서 서버 원본을 직접 내려받아 독립 재분석하지는 않았다. 비밀번호·Secret 원문·전체 RDS Endpoint·테스트 계정 이메일은 게시하지 않는다.

- 종료 확인 상태는 **Primary 2a / Standby 2c**이며, 시연 종료로 자동 원복되지 않는다. 원래 AZ로 되돌리는 추가 Failover는 실행하지 않았다. 향후 AWS 유지보수/장애 조치로 다시 바뀔 수 있다.
- 본 측정은 종료했고, T4 PITR/다른 장애 시연은 이 결과에 포함하지 않는다.
- 로그인 iter 모드에 따른 전용 테스트 계정 세션 증가분의 정리 여부는 별도 확인 사항이며, 운영 세션 일괄 삭제를 수행하지 않는다.
- 그래프의 과거 TCP PASS를 현재 SQL 정상 증거로 사용하지 않는다. 중단된 TCP job의 무조건 재활성화나 다른 설정 변경을 이 PR에 포함하지 않는다.

## 7. 판정 및 발표 문구

| 항목 | 결과 |
| --- | --- |
| RDS 통제 Failover·Primary AZ 전환 | 확인 |
| 사용자 로그인·조회·저장 복구 | 확인. 로그인 타임아웃 2건 있음 |
| 두 온프렘 DB의 관측된 복제 정상 상태 | 확인. 전체 표본 분석에서 이탈 없음 |
| 무중단/사용자 요청 실패 0건 | **해당 없음** |
| User RTO (T0=AWS Failover 시작 이벤트) | **12.6초** |
| 전체 행 내용 정합성·RPO=0 | **이 시험 증적만으로 미입증** |

**발표용 표현:** “RDS Multi-AZ 통제 Failover로 Primary가 2c에서 2a로 전환됐습니다. AWS 시작~완료 이벤트는 18.669초였고, 단일 테스트 계정 k6에서는 로그인 타임아웃 2건 이후 조회·저장까지 복구됐습니다. 본 시연은 AWS Failover 시작 이벤트를 T0로 정의하며 User RTO는 12.6초입니다. 두 온프렘 DB의 약 1초 간격 기록에서는 복제 이상이 관측되지 않았습니다.”

관련: [#122 Multi-AZ 구성](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/122), [#123 통합 시연안](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/123), [#124 T1 결과](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/124), [#125 T2 결과](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/125), [#127 구번호 T4 VPN 결과](https://github.com/neuroplan-hybrid/neuroplan-aws-migration/pull/127).

