# Neuroplan 통합 모니터링 (#113)

기존 Monitoring VM의 Grafana·Prometheus·Blackbox·Alertmanager를 재사용한다.
AMG를 새로 만들지 않으며, ROSA/CloudWatch 조회가 온프렘 Prometheus에 자동 저장되는 구조는 아니다.

## 경로와 관리 주체

| 범위 | 수집/판정 → 표시/전달 |
|---|---|
| 기존 온프렘 | Exporter → 온프렘 Prometheus → Grafana; Prometheus 규칙 → 기존 Alertmanager → 이메일 |
| 외부 HTTPS 경로 | 온프렘 Blackbox → 온프렘 Prometheus → Grafana; Blackbox 규칙 → 기존 Alertmanager |
| ROSA Pod/API | ROSA Prometheus/Thanos → Grafana; Grafana-managed 규칙 → 기존 온프렘 Alertmanager → 이메일 |
| RDS·VPN·NLB·Route 53 | CloudWatch → Grafana; CloudWatch Alarms → 기존 SNS → 이메일 (Route 53은 조회만) |

Grafana의 외부 Alertmanager 데이터 소스에서 Receive Grafana Alerts와
Alerting Settings의 Receiving Grafana-managed alerts를 모두 활성화했다.
기존 SMTP·수신자·온프렘 규칙은 바꾸지 않았으며, 같은 경보를 외부 Contact point로
또 전달하면 중복될 수 있으므로 중복 전달 경로를 추가하지 않는다.

## 저장 파일

- cloudwatch-check/neuroplan-cloud-check-provisioned.json: 동일 dashboard UID로 관리하는 AWS·ROSA·Blackbox 통합 패널.
- blackbox-cloud/: 공인 HTTPS 모듈·Prometheus Job·4개 규칙·검사/적용 스크립트.
- grafana-alerting/: ROSA 운영 규칙 3개·격리된 메일 테스트·API 적용 스크립트·회귀 테스트.
- 이 PR은 코드 보관/문서 목적이다. Merge 자체로 VM 또는 ROSA에 배포되지 않는다.

대시보드의 datasource UID와 Route 53 HealthCheck ID는 현재 환경 식별자다.
다른 환경 재구축 시 실제 UID/ID로 대조해야 하며, ROSA 토큰·AWS 키·SMTP 암호를
JSON에 넣지 않는다. Blackbox 데이터 소스 변수는 기존 온프렘 Prometheus를 선택한다.
ROSA Thanos를 선택하면 온프렘 Blackbox 지표는 나오지 않는다.

## 확인된 실행 증적 (2026-10-14)

아래는 담당자 댓글/정현님이 공유한 실제 VM 출력·Grafana 화면·수신 메일 기준이다.
작성 도구가 VM에서 직접 검증한 결과로 표현하지 않는다.

- Grafana 온라인 SQLite/config 백업 및 CloudWatch/ROSA 데이터 소스 Save & test 성공.
- GitOps #18 병합 및 플랫폼 사후 Argo Synced/Healthy·Backend ServiceMonitor 반영 확인.
- Backend scrape 대상 2개 UP=1, HTTP 요청 지표 실제 조회, AWS·ROSA 대시보드 표시 확인.
- 기존 온프렘 Blackbox 직접 IP 검사 6개 유지 + 공인 경로 3개 모두 probe_success=1.
  신규 경로는 HTTP 200·공인 TLS 검증 ON이며 Host/SNI를 app.nplan.local로 고정하지 않는다.
- Prometheus 새 Blackbox 규칙 4개 실제 health=ok/state=inactive 확인.
- 온프렘 Alertmanager SMTP·email receiver 존재 확인; Grafana 외부 전달 활성화 확인.
- NeuroplanNotificationTest 발생 메일 17:33:50 KST, 복구 메일 17:35:10 KST 확인.
  이는 테스트 규칙의 전체 전달 경로 검증이며 실제 ROSA 장애 검증과 구분한다.
- 테스트 UID 삭제 후 운영 3개 규칙 쿼리 및 A/B/C 평가식 PASS·등록 완료.
  Grafana 화면에서 세 규칙 모두 초록색 정상/Provisioned 확인.
- #115 신규 CloudWatch 알람 4개 실제 생성/OK는 플랫폼 댓글 기준.
  초기 INSUFFICIENT_DATA → OK 이메일 4건 수신 확인.
  실제 ALARM 발화/장애 후 ALARM → OK 메일 검증은 완료로 주장하지 않는다.

### 명시적으로 남기는 미확인 사항

- Blackbox 통합 대시보드 최신 파일 설치는 성공했지만 새 4개 패널의 최종 UI 캡처는 미확인.
- ROSA 운영 3개 규칙을 실제 장애로 각각 발화시킨 증적은 없음.
- #115 실제 장애/복구 이메일과 비공개 ON 설정의 독립 재현 검증은 해당 PR 후속.
- CloudWatch 인증은 기존 IAM 계정으로 사용 중; 전용 조회 최소권한 정책을 검증했다고 주장하지 않음.
- CloudWatch 실제 비용/조회량의 최종 수치 정리는 미완료.
- ROSA 로그 Loki 통합, 자동 Thanos 토큰 갱신은 구현하지 않음.
- #97 Multi-AZ는 별도 검토/Draft PR 단계이며 이 구성/PR로 적용하지 않음.

## 운영 규칙과 의미

| 규칙 | 조건 | 유지 시간 |
|---|---|---|
| ROSA Backend 수집 실패 | 발견된 scrape 대상 중 UP=0 | 1분 |
| ROSA Backend Ready 부족 | Ready Pod 수 < Deployment 희망 Replica 수 | 2분 |
| ROSA Backend HTTP 5xx 증가 | 최근 5분 요청 처리율에서 5xx 비율 >5% | 5분 |
| Blackbox 외부 경로 실패 | HTTP 200/TLS 검사 실패 | 1분 |
| Blackbox 응답 지연 | 성공 Probe 전체 시간이 2초 초과 | 5분 |
| Blackbox 인증서 만료 임박 | 체인 중 가장 빠른 만료가 7일 이내 | 1시간 |
| Blackbox 검사 결과 수집 실패 | 해당 Job의 up=0 | 1분 |

임계값은 초기 운영 기준이며 측정된 SLO가 아니다. 낮은 요청량에서는 5xx 비율을
오류 건수/요청량과 함께 해석한다. NoData/Error를 강제로 정상으로 치환하지 않는다.
외부 HTTP 성공은 로그인/저장/DB 정합성 성공을 보장하지 않는다.
ROSA 기본 규칙이 Grafana 목록에 보인다는 이유만으로 온프렘 메일 전달을 주장하지 않는다.

## 배포·변경 시 안전 기준

### 대시보드
- Monitoring VM의 /var/lib/grafana/dashboards/neuroplan-aws-check-v1.json 파일 하나를 관리한다.
  동일 UID 파일을 다른 이름으로 중복 배포하지 않는다.
- 기존 파일 백업 → JSON 검사 → owner 472/group 472/mode 640 설치.
- SELinux Enforcing을 유지하고 대상 파일만 dashboards 디렉터리의 context/MCS를 참조한다.
- provider는 30초 간격이며 allowUiUpdates=false. 파일 수정이 정본이다.
- 새 datasource/메일 설정은 별도 관리되고 대시보드 JSON 교체로 삭제하지 않는다.
- 기본 자동 새로고침은 OFF. 필요할 때 1분 이상으로 설정하고 CloudWatch 조회량을 관측한다.

### Blackbox
- 최초 설치는 blackbox-cloud/install.sh, 기존 파일/대상/규칙 보존 및 backup 경로 출력.
- 실제 Blackbox config.check와 promtool check를 통과한 뒤 HUP 재로드한다.
- 재로드 확인은 직접 /metrics + active config로 수행한다. 자체 지표의 다음 scrape를
  10초 안에 기다리며 실패로 판단했던 초기 확인 오류는 수정했다.
- 운영 설정 검증은 기존 6개와 신규 3개 수집을 모두 확인한다.
- 스크립트는 재설치/중복 Job을 거부한다. 백업 폴더를 확인하고 변경 범위를 검토한다.
- Endpoint 장애를 단순 정상으로 숨기지 않으며 실제 데이터 발화와 메일 테스트는 구분한다.

### Grafana 운영/메일 테스트
- grafana-alerting/README.md의 순서를 따른다. server-admin 암호는 VM에서만 대화형 입력.
- 적용 전 실제 쿼리와 전체 A/B/C 표현식을 검사, 온라인 SQLite 백업 후 Admin API hot reload.
- provisioning alerting 디렉터리의 755 권한과 파일 context/644 권한을 보존한다.
  초기 umask 077 때문에 root-only 디렉터리가 된 문제는 수정했다.
- Reducer strict의 API 표현은 settings를 생략한다. settings.mode=strict 문자열은 넣지 않는다.
  이 오류에서 발생한 DatasourceError 메일을 정상 테스트 PASS로 기록하지 않는다.
- test-fire / test-retry → test-resolve → remove-test. 테스트 규칙을 계속 남겨두지 않는다.
- install은 자체 3개 UID만 관리하며 기존 SMTP·수신자·전역 notification policy는 변경하지 않는다.
- Grafana DB를 실행 중에 복사본으로 강제 덮어쓰지 않는다. 백업 파일은 root-private이며 Git 금지.

## 토큰 만료·재발급

- 조회 SA: neuroplan/grafana-thanos-reader, 플랫폼 담당자가 발급/재발급한다.
- 플랫폼 인계 만료시각: 2026-10-17 15:26:26. 실제 JWT exp와 시간대를 재확인한다.
- 자동 갱신 없음. 사용 기간을 연장하면 만료 24시간 전 재발급을 조율한다.
- Monitoring VM root 전용 전달 파일: /root/.config/neuroplan/rosa-thanos-reader.token (600).
- Grafana ROSA Thanos의 Authorization 헤더를 새 Bearer 토큰으로 교체 후 Save & test,
  up/Backend 쿼리·운영 규칙 평가를 확인한다. 토큰을 댓글·영상·파일 저장소에 게시하지 않는다.
- 토큰 만료와 Monitoring VM 장애는 이 중앙 Grafana 판정 경로의 한계다.

## ROSA 종료 전후

1. 종료 전 대시보드·규칙 상태·발생/복구 메일·DB 별도 증적을 비공개 보관한다.
2. 업데이트된 apply_rules.py를 VM에 전송한 뒤 아래로 ROSA 운영 규칙만 일시정지한다.
   `sudo python3 /tmp/grafana-alerting/apply_rules.py pause`
   새 pause 코드는 저장소 보관용 추가이며 아직 VM 실행 증적은 없다.
   조회 실패 후에도 pause할 수 있게 live ROSA 쿼리는 요구하지 않는다.
3. 기존 온프렘 Prometheus/Alertmanager/Blackbox 규칙을 전부 끄지 않는다.
   ROSA/공인 경로 종료 후 신규 cloud Blackbox 4개 규칙은 계획된 종료 상태를 장애로
   반복 통지하지 않도록 대상/규칙을 조정하는 별도 변경 승인을 받는다. 기존 6개는 보존한다.
4. datasource를 없애기 전 해당 UID를 참조하는 규칙/패널 처리를 결정한다.
   종료 후 ROSA/CloudWatch No data를 정상 운영 증적으로 사용하지 않는다.
5. 토큰·AWS 인증정보 폐기/회수는 각 담당자가 수행한다. 전체 shared account 키를
   다른 사용자 영향 검토 없이 임의 삭제하지 않는다.

## #115 ON 입력 유지

기본 enable_network_cloudwatch_alarms=false와 실제 ON 운영 상태는 다르다.
플랫폼은 비공개 ~/.config/neuroplan/network-alarms-on.tfvars.json 및 작업용 auto.tfvars를 사용했다.
향후 두 운영 tfvars Plan/Apply에서도 같은 ON 입력을 명시해야 한다.
누락해 알람 4개 삭제 또는 예상 외 변경이 나오면 중단한다.
작업용 auto.tfvars가 없는 깨끗한 실행 환경에서 비공개 입력을 명시한 독립 재현 검증은 후속이다.
실제 입력 내용·ARN·원본 Plan/JSON/로그는 GitHub에 올리지 않는다.
이 문서는 기존 saved Plan 재사용 또는 AWS Apply 승인이 아니다.

## 종료 기준/추적

#113은 이 PR 리뷰·병합, Blackbox 화면 최종 확인, 위 운영 한계/후속 범위 합의 후 종료한다.
#115 실제 ALARM/복구 이메일은 해당 PR에서 추적하며 #113 전체에서 성공으로 오인하지 않는다.
#97 DB 변경·T1/T2/T4/T5 작업 승인과 이 코드 보관은 별개다.
