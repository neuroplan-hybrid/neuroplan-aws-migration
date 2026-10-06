#!/bin/bash
# probe_1006.sh — 1초 간격 전환 측정 (Control RTO + 보조 지표, 작업일지 1006 1장 3번, #22 결정 C)
#
# 주 증거는 k6(로그인 → 조회 → 저장). User RTO(#22: T0 → k6 에러율 0 복귀 시각 T3)는 k6 결과에서만 계산한다
# 이 스크립트는 Control RTO(권한 DNS 전환)와 보조 지표 Probe Recovery를 1초 단위로 남긴다
# 실행 위치: 리눅스 (DevOps VM heejae 등, root 불필요). 필요 명령: dig, curl, getent, timeout, awk, date
# LB DNS는 고정값 없음 — 실행할 때마다 최신 Terraform Output을 넘긴다 (NLB 재생성 시 이전 NLB 측정 방지, #50 리뷰)
#   DR_NLB_DNS="$(cd envs/prod && terraform output -raw dr_nlb_dns_name)" \
#   ROSA_LB_DNS="<ROSA Ingress LB DNS, 10/13 이후>" \
#   bash scripts/probe_1006.sh run         # Ctrl+C까지 1초마다 기록 → probe_<MMDD-HHMM>.csv
#   (같은 변수로) bash scripts/probe_1006.sh run 300   # 300초만 기록
#   bash probe_1006.sh summary <csv> [T0]  # 요약. T0(HH:MM:SS, 장애 주입 시각)를 주면 Control RTO·Probe Recovery 계산
#
# 매초 기록 (정각 초에 시작, 병렬 실행, 모든 요청에 TIMEOUT → 한 줄이 1초를 넘지 않게)
#   ip_auth/site_auth         : 권한 네임서버(awsdns) 직접 조회 IP·사이트 → Route 53 판단이 바뀐 시각 (Control RTO)
#   ip_resolver/site_resolver : 시스템 Resolver 조회 IP·사이트 (캐시 포함) → Probe Recovery 보조 지표
#   app_code/app_ms           : https://app.neuroplan.cloud${APP_PATH} 응답 코드·시간 (시스템 Resolver 그대로)
#   app_ip/app_site           : app 요청이 실제로 연결된 IP(curl remote_ip)·사이트 → DNS 값과 실제 연결 구분
#   dr/rosa                   : 각 사이트의 /actuator/health/routing (LB로 직접, SNI는 *-health 이름) = Route 53 HC가 보는 값
#   write                     : 쓰기 요청 결과 — TODO: 정현 저장·로그인 API·테스트 계정 확정 후 구현 (현재 "-")
#   site 값: onprem(DR NLB IP), rosa(ROSA LB IP), unknown, - (LB IP는 60초마다 다시 조회)
# 1초 주기 보장: 한 회차가 늦어 다음 정각 초를 넘기면 몰아서 실행하지 않고 다음 정각 초로 건너뜀 → summary에 "측정 공백"으로 표시
# 참고: readiness(DB 포함)는 health 호스트에 노출하지 않음(#34·#40) → DB 상태는 oc/kubectl·모니터링으로 확인
# 주의: 조건문에 "명령 | grep -q"를 쓰지 않는다 (pipefail 거짓 실패, 작업일지 0930 3.9)
set -uo pipefail

DOMAIN="${DOMAIN:-neuroplan.cloud}"
APP_HOST="${APP_HOST:-app.${DOMAIN}}"
APP_PATH="${APP_PATH:-/}"
HC_PATH="${HC_PATH:-/actuator/health/routing}"
DR_HEALTH="${DR_HEALTH:-dr-health.${DOMAIN}}"
ROSA_HEALTH="${ROSA_HEALTH:-primary-health.${DOMAIN}}"
DR_NLB_DNS="${DR_NLB_DNS:-}"            # 필수: terraform output -raw dr_nlb_dns_name
ROSA_LB_DNS="${ROSA_LB_DNS:-}"          # 10/13 ROSA Ingress LB DNS (비어 있으면 rosa 열은 "-")
TIMEOUT="${TIMEOUT:-0.9}"               # 요청 하나의 최대 시간(초), 1 미만이어야 함
OUT_DIR="${OUT_DIR:-.}"
HEADER="ts,epoch_ms,ip_auth,site_auth,ip_resolver,site_resolver,app_code,app_ms,app_ip,app_site,dr_code,dr_ms,rosa_code,rosa_ms,write_code,write_seq,write_ms"

usage() { echo "사용법: bash $0 run [초] | summary <csv> [T0 HH:MM:SS]" >&2; exit 1; }

check_lb() {  # $1 변수 이름, $2 값, $3 required|optional → 비었거나 ELB DNS 형식이 아니면 중단
    if [[ -z "$2" ]]; then
        [[ "$3" == required ]] || return 0
        echo "$1 필수 — 예: $1=\"\$(cd envs/prod && terraform output -raw dr_nlb_dns_name)\" bash $0 run" >&2; exit 1
    fi
    [[ "$2" =~ ^[A-Za-z0-9.-]+\.elb\.([a-z0-9-]+\.)?amazonaws\.com$ ]] || { echo "$1 형식 이상: '$2' (ELB DNS 이름이어야 함, terraform output이 null인지 확인)" >&2; exit 1; }
}
# DNS 조회는 모두 timeout으로 감싼다 (dig +time=1도 응답 지연 시 1초를 넘길 수 있음)
dns_a() {  # $1 이름, $2 서버(선택) → 정렬된 IP 목록(공백)
    local srv=()
    [[ -n "${2:-}" ]] && srv=("@$2")
    timeout "$TIMEOUT" dig +short +time=1 +tries=1 "$1" A "${srv[@]}" 2>/dev/null | grep -E '^[0-9.]+$' | sort | paste -sd' '
}
resolver_a() { timeout "$TIMEOUT" getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' '; }
lb_ips() { [[ -n "$1" ]] && dns_a "$1"; }
site_of() {  # $1 IP 목록(공백) → onprem/rosa/unknown/-
    local ips="$1" ip
    [[ -z "$ips" ]] && { echo "-"; return; }
    for ip in $ips; do
        [[ " $DR_IPS " == *" $ip "* ]] && { echo "onprem"; return; }
        [[ -n "$ROSA_IPS" && " $ROSA_IPS " == *" $ip "* ]] && { echo "rosa"; return; }
    done
    echo "unknown"
}
http() {  # $1 URL, $2 추가 curl 인자(문자열) → "code ms remote_ip"
    local r
    # shellcheck disable=SC2086
    r="$(curl -sk -o /dev/null -w '%{http_code} %{time_total} %{remote_ip}' --max-time "$TIMEOUT" $2 "$1" 2>/dev/null)"
    [[ -z "$r" ]] && r="000 ${TIMEOUT}"
    awk '{printf "%s %d %s", $1, $2*1000, ($3 == "" ? "-" : $3)}' <<<"$r"
}
sleep_until() {  # $1 epoch 초 → 그 정각까지 대기
    local sl=$(( $1 * 1000000000 - $(date +%s%N) ))
    (( sl > 0 )) && sleep "$(awk -v n="$sl" 'BEGIN{printf "%.3f", n/1e9}')"
    return 0
}

do_run() {
    local limit="${1:-0}" ns csv n=0 skip=0 next t0 c now
    for c in dig curl getent timeout awk date; do command -v "$c" >/dev/null || { echo "$c 없음" >&2; exit 1; }; done
    awk -v t="$TIMEOUT" 'BEGIN{exit !(t > 0 && t < 1)}' || { echo "TIMEOUT=${TIMEOUT}: 0보다 크고 1보다 작아야 함" >&2; exit 1; }
    check_lb DR_NLB_DNS "$DR_NLB_DNS" required
    check_lb ROSA_LB_DNS "$ROSA_LB_DNS" optional
    DR_IPS="$(lb_ips "$DR_NLB_DNS")"; ROSA_IPS="$(lb_ips "$ROSA_LB_DNS")"
    [[ -n "$DR_IPS" ]] || { echo "DR_NLB_DNS 조회 결과 IP 없음 (${DR_NLB_DNS}) → 삭제·교체된 NLB일 수 있음, terraform output 다시 확인" >&2; exit 1; }
    echo "측정 대상: DR NLB ${DR_NLB_DNS} (${DR_IPS}) / ROSA LB ${ROSA_LB_DNS:-미지정} ${ROSA_IPS:+(${ROSA_IPS})}" >&2
    ns="$(timeout 5 dig +short NS "$DOMAIN" @8.8.8.8 2>/dev/null | head -1)"
    [[ -n "$ns" ]] || { echo "권한 NS 조회 실패 (${DOMAIN})" >&2; exit 1; }
    csv="${OUT_DIR}/probe_$(date +%m%d-%H%M).csv"
    echo "$HEADER" > "$csv"
    echo "기록 시작: ${csv} (권한 NS ${ns%.}, app https://${APP_HOST}${APP_PATH}, HC ${HC_PATH}, TIMEOUT ${TIMEOUT}s) — Ctrl+C로 종료" >&2
    trap 'echo; echo "종료: ${csv} (${n}줄, 건너뛴 초 ${skip})" >&2; exit 0' INT TERM
    next=$(( $(date +%s) + 1 ))
    while :; do
        sleep_until "$next"
        t0=$(date +%s%3N)
        local tmp; tmp="$(mktemp -d)"
        # LB IP 재조회도 같은 회차 안에서 병렬·timeout (주기를 밀지 않게)
        if (( n % 60 == 0 && n > 0 )); then
            ( lb_ips "$DR_NLB_DNS" > "$tmp/drips" ) &
            ( lb_ips "$ROSA_LB_DNS" > "$tmp/roips" ) &
        fi
        ( dns_a "$APP_HOST" "${ns%.}" > "$tmp/auth" ) &
        ( resolver_a "$APP_HOST" > "$tmp/res" ) &
        ( http "https://${APP_HOST}${APP_PATH}" "" > "$tmp/app" ) &
        ( http "https://${DR_HEALTH}${HC_PATH}" "--connect-to ${DR_HEALTH}:443:${DR_NLB_DNS}:443" > "$tmp/dr" ) &
        if [[ -n "$ROSA_LB_DNS" ]]; then
            ( http "https://${ROSA_HEALTH}${HC_PATH}" "--connect-to ${ROSA_HEALTH}:443:${ROSA_LB_DNS}:443" > "$tmp/rosa" ) &
        else echo "- - -" > "$tmp/rosa"; fi
        wait
        if [[ -s "$tmp/drips" ]]; then DR_IPS="$(cat "$tmp/drips")"; fi   # 조회 실패(빈 값)면 이전 IP 유지
        if [[ -s "$tmp/roips" ]]; then ROSA_IPS="$(cat "$tmp/roips")"; fi
        local auth res app_c app_ms app_ip dr_c dr_ms ro_c ro_ms _ip
        auth="$(cat "$tmp/auth")"; res="$(cat "$tmp/res")"
        read -r app_c app_ms app_ip < "$tmp/app"; read -r dr_c dr_ms _ip < "$tmp/dr"; read -r ro_c ro_ms _ip < "$tmp/rosa"
        rm -rf "$tmp"
        local app_site="-"
        [[ "$app_ip" != "-" ]] && app_site="$(site_of "$app_ip")"
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(date -d "@$((t0/1000))" +%H:%M:%S).$(printf '%03d' $((t0%1000)))" "$t0" \
            "${auth:--}" "$(site_of "$auth")" "${res:--}" "$(site_of "$res")" \
            "$app_c" "$app_ms" "$app_ip" "$app_site" "$dr_c" "$dr_ms" "$ro_c" "$ro_ms" "-" "-" "-" | tee -a "$csv"
        n=$((n+1))
        (( limit > 0 && n >= limit )) && { echo "종료: ${csv} (${n}줄, 건너뛴 초 ${skip})" >&2; break; }
        next=$((next+1))
        now=$(date +%s)
        if (( now >= next )); then   # 늦었으면 몰아서 실행하지 않고 다음 정각 초로
            skip=$(( skip + now - next + 1 )); next=$((now+1))
            echo "⚠ 회차 지연 → 다음 정각 초로 건너뜀 (누적 ${skip}초)" >&2
        fi
    done
}

do_summary() {
    local csv="${1:-}" t0s="${2:-}" t0e=""
    [[ -f "$csv" ]] || usage
    [[ "$(head -1 "$csv")" == "$HEADER" ]] || { echo "CSV 헤더가 현재 형식과 다름 (${csv})" >&2; exit 1; }
    if [[ -n "$t0s" ]]; then
        local d; d="$(awk -F, 'NR==2{print $2}' "$csv")"
        t0e=$(( $(date -d "$(date -d "@$((d/1000))" +%F) $t0s" +%s) * 1000 ))
    fi
    awk -F, -v t0="$t0e" '
    NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    { rows++
      ep = $c["epoch_ms"]; sa = $c["site_auth"]; sr = $c["site_resolver"]; ac = $c["app_code"]; as = $c["app_site"]
      st[sa]++; ast[as]++
      if (ac != "200") appfail++
      if ($c["dr_code"] != "200" && $c["dr_code"] != "-") drf++
      if ($c["rosa_code"] != "200" && $c["rosa_code"] != "-") rof++
      if (rows > 1 && ep - prev_ep > 1500) { gap++; gaps = gaps sprintf("  %s 앞 %.1f초 간격\n", $1, (ep - prev_ep) / 1000) }
      if (rows > 1 && sa != prev_auth) { tr = tr sprintf("  %s  권한 DNS 사이트 %s → %s\n", $1, prev_auth, sa) }
      prev_auth = sa; prev_ep = ep
      if (t0 != "" && ep >= t0) {
        if (ctrl == "" && sa == "onprem") ctrl = ep - t0
        if (conn == "" && as == "onprem" && ac == "200") conn = ep - t0
        if (sr == "onprem" && ac == "200") { ok++; if (ok == 1) start = ep; if (ok == 3 && prec == "") prec = start - t0 } else { ok = 0 }
      }
    }
    END {
      printf "행 %d, 측정 공백(1.5초 초과 간격) %d곳\n%s", rows, gap, gaps
      printf "권한 DNS 사이트별:"; for (k in st) printf " %s=%d", k, st[k]; printf "\n"
      printf "app 실제 연결 사이트별:"; for (k in ast) printf " %s=%d", k, ast[k]; printf "\n"
      printf "app 비정상 %d행, dr HC 비정상 %d행, rosa HC 비정상 %d행\n", appfail, drf, rof
      printf "권한 DNS 전환 시각:\n%s", (tr == "" ? "  없음\n" : tr)
      if (t0 != "") {
        printf "Control RTO (T0 → 권한 DNS가 onprem): %s\n", (ctrl == "" ? "미발생" : sprintf("%.1f초", ctrl/1000))
        printf "[보조] Probe Recovery (T0 → Resolver onprem + app 200 연속 3회 시작): %s\n", (prec == "" ? "미발생" : sprintf("%.1f초", prec/1000))
        printf "[보조] App 연결 전환 (T0 → app 실제 연결 onprem + 200 첫 시각): %s\n", (conn == "" ? "미발생" : sprintf("%.1f초", conn/1000))
        printf "User RTO는 k6 결과에서 계산 (#22: T0 → k6 에러율 0 복귀 시각 T3) — 이 스크립트에서는 계산하지 않음\n"
      }
    }' "$csv"
}

case "${1:-}" in
    run)     do_run "${2:-0}" ;;
    summary) do_summary "${2:-}" "${3:-}" ;;
    *)       usage ;;
esac
