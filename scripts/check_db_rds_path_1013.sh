#!/bin/bash
# check_db_rds_path_1013.sh — 온프렘 DB VM → RDS 3306 경로 점검 (읽기 전용, #96 재발 방지, #18 "역복제 네트워크 사전 점검" 약속)
#
# #96에서 실제로 나온 원인 2가지를 DB VM 쪽에서 먼저 잡는다
#   ① 경로: RDS로 가는 패킷이 데이터망(via 192.168.44.62, src 192.168.44.x)으로 나가는지
#        (10/13 db-replica는 10.20.0.0/16 경로가 없어 관리망 ens160·src 14.52로 나감 → Infra에서 차단)
#   ② TCP 3306 연결 (Infra data-to-aws·RDS SG가 막으면 TIMEOUT)
#   ③ (선택) TLS: RDS CA로 서버 인증서 검증 (#104 역복제 MASTER_SSL_VERIFY_SERVER_CERT=1과 같은 조건)
# 실행 위치: db-primary·db-replica 각각 (root 불필요)
#   RDS_EP=<RDS 엔드포인트> bash check_db_rds_path_1013.sh
#   RDS_EP=<...> RDS_CA=/etc/my.cnf.d/rds-ca/ca-bundle.pem bash check_db_rds_path_1013.sh   # TLS까지
# 종료 코드: 0 = 모두 OK, 1 = 하나라도 FAIL (조치 힌트 출력)
set -uo pipefail

RDS_EP="${RDS_EP:-}"
RDS_PORT="${RDS_PORT:-3306}"
RDS_CA="${RDS_CA:-}"
DATA_GW="${DATA_GW:-192.168.44.62}"     # Infra VM 데이터망(ens224, nw-data)
DATA_NET="${DATA_NET:-192.168.44.}"     # 출발지가 이 대역이어야 VPN·RDS SG·Infra policy에 맞음
# RDS IP 허용 범위 = Infra data-to-aws 목적지 10.20.100.0/22 (10.20.100.0 ~ 10.20.103.255, DB 서브넷 100·101/24 포함)
# 문자열 접두어가 아니라 옥텟 숫자로 비교 (#107 리뷰: "10.20.10" 접두어는 10.20.104.x 등도 통과)

fail=0
in_rds_net() {   # 10.20.100.0/22 이면 0
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    (( a == 10 && b == 20 && c >= 100 && c <= 103 && d <= 255 ))
}
ok()   { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
hint() { printf '         → %s\n' "$*"; }

[[ -n "$RDS_EP" ]] || { echo "RDS_EP 필요 — 예: RDS_EP=neuroplan-rds-operation.xxxx.ap-northeast-2.rds.amazonaws.com bash $0" >&2; exit 1; }
printf '== DB VM → RDS 경로 점검 · %s · %s\n' "$(hostname -s)" "$(date '+%F %T')"

# 0) DNS
RDS_IP="$(getent ahostsv4 "$RDS_EP" 2>/dev/null | awk 'NR==1{print $1}')"
if [[ -n "$RDS_IP" ]]; then ok "DNS: ${RDS_EP%%.*}… → ${RDS_IP}"
else bad "DNS 해석 실패 (${RDS_EP})"; hint "/etc/resolv.conf가 Infra BIND(192.168.14.62)를 보는지, BIND 외부 포워딩 확인"; echo "== FAIL ${fail}건"; exit 1; fi
in_rds_net "$RDS_IP" && ok "RDS IP가 DB 서브넷 대역 (${RDS_IP})" || { bad "RDS IP ${RDS_IP}가 DB 서브넷(10.20.100.0/22) 밖"; hint "Infra data-to-aws 목적지(10.20.100.0/22)와 맞지 않음 → 엔드포인트·서브넷 확인"; }

# 1) 경로 (#96 원인 ②)
r="$(ip -o route get "$RDS_IP" 2>/dev/null)"
via="$(awk '{for(i=1;i<NF;i++) if($i=="via") print $(i+1)}' <<<"$r")"
dev="$(awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' <<<"$r")"
src="$(awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}' <<<"$r")"
if [[ "$via" == "$DATA_GW" && "$src" == ${DATA_NET}* ]]; then ok "경로: via ${via} dev ${dev} src ${src}"
else
    bad "경로: via ${via:-없음} dev ${dev:-?} src ${src:-?} (기대 via ${DATA_GW}, src ${DATA_NET}x)"
    hint "데이터망 연결에 영구 경로 추가: nmcli connection modify <데이터망 연결> +ipv4.routes \"10.20.0.0/16 ${DATA_GW}\" && nmcli device reapply <NIC>"
fi

# 2) TCP 3306 (#96 원인 ①: Infra data-to-aws, RDS SG)
if command -v nc >/dev/null 2>&1; then
    if nc -z -w5 "$RDS_IP" "$RDS_PORT" >/dev/null 2>&1; then ok "TCP ${RDS_IP}:${RDS_PORT} 연결"
    else bad "TCP ${RDS_IP}:${RDS_PORT} TIMEOUT/거부"; hint "Infra VM: setup_db_to_rds_1013.sh verify (data-to-aws 규칙) → 그다음 RDS SG Inbound에 이 DB의 /32"; fi
else
    if timeout 5 bash -c "</dev/tcp/${RDS_IP}/${RDS_PORT}" 2>/dev/null; then ok "TCP ${RDS_IP}:${RDS_PORT} 연결 (bash /dev/tcp)"
    else bad "TCP ${RDS_IP}:${RDS_PORT} TIMEOUT/거부"; hint "Infra VM: setup_db_to_rds_1013.sh verify → RDS SG Inbound 확인"; fi
fi

# 3) TLS (선택, #104)
if [[ -n "$RDS_CA" ]]; then
    if [[ ! -r "$RDS_CA" ]]; then bad "RDS_CA 파일 없음 (${RDS_CA})"; hint "#104 configure-onprem-replica가 CA를 배포했는지 확인"
    else
        v="$(echo | timeout 10 openssl s_client -starttls mysql -connect "${RDS_EP}:${RDS_PORT}" -servername "$RDS_EP" \
               -CAfile "$RDS_CA" -verify_hostname "$RDS_EP" 2>/dev/null | awk -F': ' '/Verify return code/{print $2; exit}')"
        if [[ "$v" == 0* ]]; then ok "TLS 인증서 검증 (호스트 이름 포함): ${v}"
        else bad "TLS 인증서 검증 실패: ${v:-응답 없음}"; hint "CA 파일·엔드포인트 이름(IP 금지)·시각 동기화 확인"; fi
    fi
fi

if (( fail == 0 )); then echo "== 결과: OK (역복제 네트워크 전제 충족)"; exit 0; fi
echo "== 결과: FAIL ${fail}건 (위 → 조치 순서대로)"; exit 1
