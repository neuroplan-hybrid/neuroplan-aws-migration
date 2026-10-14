# T4 DB 복제 연속 기록

희재님이 제안한 `SHOW SLAVE STATUS` 1초 간격 기록 코드를 실제 DB 접속 방식에 맞춰 파일로 정리했습니다. T4는 VPN 터널 하나의 장애/복구 시험이며, 이 도구는 DB 복제 상태를 관측할 뿐 장애를 주입하거나 복제 설정을 바꾸지 않습니다.

## 준비 및 배포

실행 위치: DevOps VM, 저장소 루트. 병합 후 최신 main의 아래 파일만 두 DB로 복사합니다. 다른 로컬 변경은 지우지 않습니다.

```bash
cd ~/neuroplan-aws-migration
scp scripts/record_t4_replication.sh dbadmin@192.168.14.51:/tmp/record_t4_replication.sh
scp scripts/record_t4_replication.sh dbadmin@192.168.14.52:/tmp/record_t4_replication.sh
```

실행 위치: db-primary와 db-replica 각각, dbadmin 계정. 먼저 5초 시험을 하고 화면과 저장 파일을 확인합니다.

```bash
bash -n /tmp/record_t4_replication.sh
bash /tmp/record_t4_replication.sh 5
```

조회가 정상이면 `QUERY_OK`, 마지막에 `query_errors=0`과 저장 경로가 나옵니다. `QUERY_OK`는 SQL 조회 성공이지 복제 정상 판정이 아닙니다. IO/SQL Yes, Lag 0, 오류 번호/메시지도 별도로 확인합니다.

## 녹화 시연

두 DB 터미널에서 각각 주입 1분 전 시작합니다.

```bash
bash /tmp/record_t4_replication.sh 1200
```

희재님이 장애 주입/복구 시각을 공유하며, 복구 후 최소 3분까지 기록한 다음 각 터미널에서 Ctrl+C로 종료합니다. 화면 녹화는 별도 프로그램으로 수행합니다. 정상 종료 시간을 20분으로 잡았으며, 기본값은 10분입니다. 로그 경로를 명시하려면 두 번째 인자를 사용합니다.

```bash
bash /tmp/record_t4_replication.sh 1200 "$HOME/t4-db-primary-run1.log"
```

기존 파일은 덮어쓰지 않습니다. 파일은 실행 계정 소유, 권한 600으로 생성합니다. 증적에는 내부 주소/오류 내용이 포함되므로 GitHub에 원본 로그를 올리지 말고 필요한 결과만 공유합니다.

## 기록 및 한계

- 날짜/밀리초/시간대, Master Host, IO/SQL, Lag, IO/SQL 오류 번호와 메시지, GTID, read_only를 화면과 파일에 기록합니다.
- 기존과 동일한 `sudo mariadb --protocol=socket` 접속입니다. 시작 시 sudo 인증을 받고 이후에는 비대화형 조회를 사용합니다. SSH 비밀번호, sudo 비밀번호, Ansible Vault 비밀번호는 별개입니다.
- SQL은 `SHOW SLAVE STATUS`와 `SELECT`뿐입니다. RDS 마커 쓰기, 계정 생성, STOP/START/RESET/CHANGE MASTER는 수행하지 않습니다.
- 각 조회 후 1초 대기하므로 정확한 1Hz 보장이 아니라 약 1초 간격 폴링입니다. 조회에는 8초 제한이 있으며 오류/타임아웃은 `QUERY_ERROR`로 남습니다. 오류가 있으면 정상 시간 종료 시 exit 1입니다.
- `NULL` Lag를 0으로 취급하지 않습니다. 로그에서 최대 숫자 Lag와 NULL/조회 오류 구간을 구분해 보고합니다. 짧은 중단은 샘플 사이에서 놓칠 수 있습니다.
- 현재 환경의 단일 기본 복제 채널을 대상으로 합니다. 멀티소스 복제에는 사용하지 않습니다.
- GTID는 domain별 위치를 비교하며 문자열 순서가 달라도 동일할 수 있습니다. 현재 GTID 일치는 과거 주입 구간의 무중단 증명이 아닙니다.
- 본 시연 전 두 VM에서 실제 5초 실행/로그 저장 검증이 필요합니다. Linux mock CI는 실제 DB 검증을 대체하지 않습니다.

## 별도 보강

A1(과거 DB 에러 로그), A2(RDS 에러 로그), A3(현재 RDS/Replica GTID 비교)는 별도 보조 점검입니다. 이 PR은 실제 시연용 연속 기록에만 한정합니다. 추가 리허설 또는 본 시연 중 사용 여부는 희재님과 협의합니다.
