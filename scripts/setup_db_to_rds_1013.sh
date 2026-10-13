#!/bin/bash
# setup_db_to_rds_1013.sh — Cutover 선행조건: 온프렘 db-primary·db-replica → RDS TCP 3306 허용 (Issue #96)
#
# 증상(10/13): db-primary(192.168.44.51) → RDS(10.20.101.107):3306 nc TIMEOUT
#   - db-primary 경로 정상: 10.20.0.0/16 via 192.168.44.62 dev ens192 src 192.168.44.51
#   - Infra VM tcpdump: SYN이 ens224(nw-data) In 에만 찍히고 vti Out 없음 → Infra에서 포워딩 차단
#   - 기존 복제 세션(RDS가 연 연결)은 conntrack으로 통과 → 정방향 복제는 정상이라 드러나지 않았음
# 원인: policy data-to-aws (nw-data → aws-vpn, priority -1, target DROP)에 허용 규칙이 DevOps VM(44.21) 1개뿐
# 조치: data-to-aws에 db-primary·db-replica → DB 서브넷(10.20.100.0/22, 기존 44.21 규칙과 같은 대역) 3306 rich rule 2개 추가
#       runtime + permanent 동시 추가, reload 하지 않음 (VPN·기존 세션 영향 없음)
#
# 실행 위치: Infra VM (root)
#   bash setup_db_to_rds_1013.sh <단계>            # dry-run (기본, 변경 없음)
#   bash setup_db_to_rds_1013.sh <단계> --apply    # 적용
# 단계
#   allow   규칙 2개 추가 (이미 있으면 건너뜀). --apply 끝에 verify 자동 실행
#   verify  읽기만: policy 기본 속성, 규칙 2개 runtime·permanent 존재, 기존 44.21 규칙 유지, ESP 2개
#           하나라도 어긋나면 종료 코드 1
#   remove  롤백용: 이 스크립트가 추가한 규칙 2개만 삭제 (44.21 규칙은 건드리지 않음)
#           ※ Cutover 후에는 역방향 복제에 필요하므로 유지
# 하지 않는 일
#   - policy target·priority·zone 변경, 기존 44.21 규칙 변경
#   - AWS RDS SG (envs/prod/main.tf rds_ingress_cidrs에 .51/.52 이미 정의됨, 적용 여부는 별도 확인)
#   - DB 계정·복제 설정 (정현)
#   - db-replica VPC 경로: 10/13 replica에 10.20.0.0/16 경로가 없어 관리망(ens160, src 14.52)으로 나감 → 별도 조치
#       (db-replica) nmcli connection modify internal +ipv4.routes "10.20.0.0/16 192.168.44.62" && nmcli device reapply ens192
# 연결 확인은 DB VM에서 직접: nc -zv -w5 <RDS_IP> 3306
set -euo pipefail

POLICY="data-to-aws"
DEST="10.20.100.0/22"      # 기존 44.21 규칙과 동일 (DB 서브넷 10.20.100.0/24, 10.20.101.0/24 포함)
PORT=3306
SRCS="192.168.44.51 192.168.44.52"
KEEP_SRC="192.168.44.21"   # 기존 규칙 (변경 금지, 유지 여부만 확인)

usage() { echo "사용법: bash $0 <allow|verify|remove> [--apply]" >&2; exit 1; }
PHASE="${1:-}"
APPLY=0
case "${2:-}" in "") ;; --apply) APPLY=1 ;; *) usage ;; esac
case "$PHASE" in allow|verify|remove) ;; *) usage ;; esac

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ⚠ %s → 중단\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
mode() { if [[ $APPLY -eq 1 ]]; then echo "APPLY"; else echo "DRY-RUN"; fi; }
[[ $EUID -eq 0 ]] || die "root로 실행"

rule() { printf 'rule family="ipv4" source address="%s" destination address="%s" port port="%s" protocol="tcp" accept' "$1" "$DEST" "$PORT"; }
has_rt()   { firewall-cmd --policy="$POLICY" --query-rich-rule="$1" >/dev/null 2>&1; }
has_perm() { firewall-cmd --permanent --policy="$POLICY" --query-rich-rule="$1" >/dev/null 2>&1; }
esp_count() { ipsec trafficstatus 2>/dev/null | grep -c 'type=ESP' || true; }

preflight() {
    local v
    firewall-cmd --state >/dev/null 2>&1 || die "firewalld 미실행"
    v="$(firewall-cmd --permanent --policy="$POLICY" --list-ingress-zones 2>/dev/null)" || die "policy ${POLICY} 없음"
    [[ "$v" == "nw-data" ]] || die "${POLICY} ingress=${v} (기대 nw-data)"
    v="$(firewall-cmd --permanent --policy="$POLICY" --list-egress-zones)"
    [[ "$v" == "aws-vpn" ]] || die "${POLICY} egress=${v} (기대 aws-vpn)"
    v="$(firewall-cmd --permanent --policy="$POLICY" --get-target)"
    [[ "$v" == "DROP" ]] || die "${POLICY} target=${v} (기대 DROP) → 상태가 바뀜, 수동 확인"
    log "전제 OK: ${POLICY} nw-data → aws-vpn, target DROP / ESP $(esp_count)개"
}

phase_verify() {
    local fail=0 s r esp
    log "[verify] ${POLICY}"
    for s in $SRCS; do
        r="$(rule "$s")"
        if has_rt "$r" && has_perm "$r"; then log "  [OK]   ${s} → ${DEST}:${PORT} (runtime+permanent)"
        else log "  [FAIL] ${s} 규칙 없음 (runtime=$(has_rt "$r" && echo y || echo n), permanent=$(has_perm "$r" && echo y || echo n))"; fail=$((fail+1)); fi
    done
    r="$(rule "$KEEP_SRC")"
    if has_rt "$r" && has_perm "$r"; then log "  [OK]   기존 ${KEEP_SRC} 규칙 유지"
    else log "  [FAIL] 기존 ${KEEP_SRC} 규칙이 사라짐"; fail=$((fail+1)); fi
    esp="$(esp_count)"
    if [[ "$esp" -ge 2 ]]; then log "  [OK]   ESP ${esp}개"; else log "  [FAIL] ESP ${esp}개 (기대 2)"; fail=$((fail+1)); fi
    [[ $fail -eq 0 ]] || { log "  verify FAIL ${fail}개"; return 1; }
    log "  다음: DB VM에서 nc -zv -w5 <RDS_IP> 3306 (primary·replica 각각)"
    return 0
}

phase_allow() {
    preflight
    local s r
    for s in $SRCS; do
        r="$(rule "$s")"
        if has_rt "$r" && has_perm "$r"; then log "${s} 규칙 이미 있음 → 건너뜀"; continue; fi
        log "${s} → ${DEST}:${PORT} 추가 예정 ($(mode))"
        if [[ $APPLY -eq 1 ]]; then
            has_rt "$r"   || firewall-cmd --policy="$POLICY" --add-rich-rule="$r" >/dev/null
            has_perm "$r" || firewall-cmd --permanent --policy="$POLICY" --add-rich-rule="$r" >/dev/null
        fi
    done
    if [[ $APPLY -eq 1 ]]; then phase_verify || die "allow 후 검증 실패 (위 [FAIL] 확인)"; fi
}

phase_remove() {
    preflight
    local s r
    for s in $SRCS; do
        r="$(rule "$s")"
        if ! has_rt "$r" && ! has_perm "$r"; then log "${s} 규칙 없음 → 건너뜀"; continue; fi
        log "${s} → ${DEST}:${PORT} 삭제 예정 ($(mode))"
        if [[ $APPLY -eq 1 ]]; then
            firewall-cmd --policy="$POLICY" --remove-rich-rule="$r" >/dev/null 2>&1 || true
            firewall-cmd --permanent --policy="$POLICY" --remove-rich-rule="$r" >/dev/null 2>&1 || true
            if has_rt "$r" || has_perm "$r"; then die "${s} 규칙 삭제 실패"; fi
        fi
    done
    if [[ $APPLY -eq 1 ]]; then
        r="$(rule "$KEEP_SRC")"
        has_rt "$r" && has_perm "$r" || die "기존 ${KEEP_SRC} 규칙이 사라짐 → 수동 확인"
        log "[verify] 추가 규칙 0/2, 기존 ${KEEP_SRC} 유지, ESP $(esp_count)개"
    fi
}

log "단계=${PHASE} 모드=$(mode)"
case "$PHASE" in
    allow)  phase_allow ;;
    verify) phase_verify || die "verify 실패 (위 [FAIL] 확인)" ;;
    remove) phase_remove ;;
esac
log "완료 (${PHASE}, $(mode))"
