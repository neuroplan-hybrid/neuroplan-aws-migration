#!/bin/bash
# probe_1006.sh — 1초 간격 전환 측정 (Control RTO / User RTO 보조 증거, 작업일지 1006 1장 3번, #22 결정 C)
#
# 주 증거는 k6(로그인 → 조회 → 저장), 이 스크립트는 DNS 전환 시각과 사이트별 헬스를 1초 단위로 남기는 보조
# 실행 위치: 리눅스 (DevOps VM heejae 등, root 불필요). 필요 명령: dig, curl, awk, date
#   bash probe_1006.sh run                 # Ctrl+C까지 1초마다 기록 → probe_<MMDD-HHMM>.csv
#   bash probe_1006.sh run 300             # 300초만 기록
#   bash probe_1006.sh summary <csv> [T0]  # 요약. T0(HH:MM:SS, 장애 주입 시각)를 주면 Control/User RTO 계산
#
# 매초 기록 (병렬 실행, 요청마다 타임아웃 → 한 줄이 1초를 넘지 않게)
#   ip_auth  : 권한 네임서버(awsdns) 직접 조회 결과 → Route 53 판단이 바뀐 시각 (Control RTO)
#   ip_user  : 시스템 Resolver 조회 결과 (캐시 포함) → 사용자 체감 (User RTO)
#   site_*   : 위 IP가 DR NLB(온프렘)인지 ROSA LB인지 (LB IP는 60초마다 다시 조회)
#   app      : https://app.neuroplan.cloud${APP_PATH} 응답 코드·시간 (시스템 Resolver 그대로)
#   dr/rosa  : 각 사이트의 /actuator/health/routing (DNS와 무관하게 LB로 직접, SNI는 *-health 이름) = Route 53 HC가 보는 값
#   write    : 쓰기 요청 결과 — TODO: 정현 저장·로그인 API·테스트 계정 확정 후 구현 (현재 "-")
# 참고: readiness(DB 포함)는 health 호스트에 노출하지 않음(#34·#40) → DB 상태는 oc/kubectl·모니터링으로 확인
# 주의: 조건문에 "명령 | grep -q"를 쓰지 않는다 (pipefail 거짓 실패, 작업일지 0930 3.9)
set -uo pipefail

DOMAIN="${DOMAIN:-neuroplan.cloud}"
APP_HOST="${APP_HOST:-app.${DOMAIN}}"
APP_PATH="${APP_PATH:-/}"
HC_PATH="${HC_PATH:-/actuator/health/routing}"
DR_HEALTH="${DR_HEALTH:-dr-health.${DOMAIN}}"
ROSA_HEALTH="${ROSA_HEALTH:-primary-health.${DOMAIN}}"
DR_NLB_DNS="${DR_NLB_DNS:-neuroplan-dr-nlb-450961729f2f0929.elb.ap-northeast-2.amazonaws.com}"
ROSA_LB_DNS="${ROSA_LB_DNS:-}"          # 10/13 ROSA Ingress LB DNS (비어 있으면 rosa 열은 "-")
TIMEOUT="${TIMEOUT:-0.9}"
OUT_DIR="${OUT_DIR:-.}"

usage() { echo "사용법: bash $0 run [초] | summary <csv> [T0 HH:MM:SS]" >&2; exit 1; }

lb_ips() { [[ -n "$1" ]] && dig +short +time=1 +tries=1 "$1" A 2>/dev/null | grep -E '^[0-9.]+$' | sort | paste -sd' '; }
site_of() {  # $1 IP 목록(공백) → onprem/rosa/unknown/-
    local ips="$1" ip
    [[ -z "$ips" ]] && { echo "-"; return; }
    for ip in $ips; do
        [[ " $DR_IPS " == *" $ip "* ]] && { echo "onprem"; return; }
        [[ -n "$ROSA_IPS" && " $ROSA_IPS " == *" $ip "* ]] && { echo "rosa"; return; }
    done
    echo "unknown"
}
http() {  # $1 URL, $2 추가 curl 인자(문자열) → "code ms"
    local r
    # shellcheck disable=SC2086
    r="$(curl -sk -o /dev/null -w '%{http_code} %{time_total}' --max-time "$TIMEOUT" $2 "$1" 2>/dev/null)"
    [[ -z "$r" ]] && r="000 ${TIMEOUT}"
    awk '{printf "%s %d", $1, $2*1000}' <<<"$r"
}

do_run() {
    local limit="${1:-0}" ns csv n=0 next t0 c
    for c in dig curl getent awk date; do command -v "$c" >/dev/null || { echo "$c 없음" >&2; exit 1; }; done
    ns="$(dig +short NS "$DOMAIN" @8.8.8.8 2>/dev/null | head -1)"
    [[ -n "$ns" ]] || { echo "권한 NS 조회 실패 (${DOMAIN})" >&2; exit 1; }
    csv="${OUT_DIR}/probe_$(date +%m%d-%H%M).csv"
    echo "ts,epoch_ms,ip_auth,site_auth,ip_user,site_user,app_code,app_ms,dr_code,dr_ms,rosa_code,rosa_ms,write_code,write_seq,write_ms" > "$csv"
    echo "기록 시작: ${csv} (권한 NS ${ns%.}, app https://${APP_HOST}${APP_PATH}, HC ${HC_PATH}) — Ctrl+C로 종료" >&2
    trap 'echo; echo "종료: ${csv} (${n}줄)" >&2; exit 0' INT TERM
    DR_IPS="$(lb_ips "$DR_NLB_DNS")"; ROSA_IPS="$(lb_ips "$ROSA_LB_DNS")"
    next=$(date +%s)
    while :; do
        if (( n % 60 == 0 && n > 0 )); then DR_IPS="$(lb_ips "$DR_NLB_DNS")"; ROSA_IPS="$(lb_ips "$ROSA_LB_DNS")"; fi
        t0=$(date +%s%3N)
        local tmp; tmp="$(mktemp -d)"
        ( dig +short +time=1 +tries=1 "$APP_HOST" A @"${ns%.}" 2>/dev/null | grep -E '^[0-9.]+$' | sort | paste -sd' ' > "$tmp/auth" ) &
        ( getent ahostsv4 "$APP_HOST" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' ' > "$tmp/user" ) &
        ( http "https://${APP_HOST}${APP_PATH}" "" > "$tmp/app" ) &
        ( http "https://${DR_HEALTH}${HC_PATH}" "--connect-to ${DR_HEALTH}:443:${DR_NLB_DNS}:443" > "$tmp/dr" ) &
        if [[ -n "$ROSA_LB_DNS" ]]; then
            ( http "https://${ROSA_HEALTH}${HC_PATH}" "--connect-to ${ROSA_HEALTH}:443:${ROSA_LB_DNS}:443" > "$tmp/rosa" ) &
        else echo "- -" > "$tmp/rosa"; fi
        wait
        local auth user
        auth="$(cat "$tmp/auth")"; user="$(cat "$tmp/user")"
        read -r app_c app_ms < "$tmp/app"; read -r dr_c dr_ms < "$tmp/dr"; read -r ro_c ro_ms < "$tmp/rosa"
        rm -rf "$tmp"
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(date -d "@$((t0/1000))" +%H:%M:%S).$(printf '%03d' $((t0%1000)))" "$t0" \
            "${auth:--}" "$(site_of "$auth")" "${user:--}" "$(site_of "$user")" \
            "$app_c" "$app_ms" "$dr_c" "$dr_ms" "$ro_c" "$ro_ms" "-" "-" "-" | tee -a "$csv"
        n=$((n+1))
        (( limit > 0 && n >= limit )) && { echo "종료: ${csv} (${n}줄)" >&2; break; }
        next=$((next+1))
        local now; now=$(date +%s%N)
        local sl=$(( next*1000000000 - now ))
        (( sl > 0 )) && sleep "$(awk -v n="$sl" 'BEGIN{printf "%.3f", n/1e9}')"
    done
}

do_summary() {
    local csv="${1:-}" t0s="${2:-}" t0e=""
    [[ -f "$csv" ]] || usage
    if [[ -n "$t0s" ]]; then
        local d; d="$(awk -F, 'NR==2{print $2}' "$csv")"
        t0e=$(( $(date -d "$(date -d "@$((d/1000))" +%F) $t0s" +%s) * 1000 ))
    fi
    awk -F, -v t0="$t0e" '
    NR==1 { next }
    { rows++; st[$4]++; if ($7 != "200") appfail++; if ($9 != "200" && $9 != "-") drf++; if ($11 != "200" && $11 != "-") rof++
      if (NR > 2 && $4 != prev_auth) { tr = tr sprintf("  %s  권한 DNS 사이트 %s → %s\n", $1, prev_auth, $4) }
      prev_auth = $4
      if (t0 != "" && $2 >= t0) {
        if (ctrl == "" && $4 == "onprem") ctrl = $2 - t0
        if ($6 == "onprem" && $7 == "200") { ok++; if (ok == 3 && user == "") user = start - t0 } else { ok = 0 }
        if (ok == 1) start = $2
      }
    }
    END {
      printf "행 %d (약 %d초)\n", rows, rows
      printf "권한 DNS 사이트별:"; for (k in st) printf " %s=%d", k, st[k]; printf "\n"
      printf "app 비정상 %d행, dr HC 비정상 %d행, rosa HC 비정상 %d행\n", appfail, drf, rof
      printf "권한 DNS 전환 시각:\n%s", (tr == "" ? "  없음\n" : tr)
      if (t0 != "") {
        printf "Control RTO (T0 → 권한 DNS가 onprem): %s\n", (ctrl == "" ? "미발생" : sprintf("%.1f초", ctrl/1000))
        printf "User RTO (T0 → 시스템 Resolver onprem + app 200 연속 3회 시작): %s\n", (user == "" ? "미발생" : sprintf("%.1f초", user/1000))
      }
    }' "$csv"
}

case "${1:-}" in
    run)     do_run "${2:-0}" ;;
    summary) do_summary "${2:-}" "${3:-}" ;;
    *)       usage ;;
esac
