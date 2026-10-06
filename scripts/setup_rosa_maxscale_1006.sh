#!/bin/bash
# setup_rosa_maxscale_1006.sh — 하이브리드 단계 ROSA 워커 → 온프렘 MaxScale(192.168.44.21:4006) 경로 허용·제거 (작업일지 1006 1장 4번)
#
# 경로: ROSA 워커(Private ROSA 서브넷 3개) → VGW → S2S VPN → Infra VM(aws-vpn → nw-data 포워딩) → DevOps VM 192.168.44.21:4006
#   ① Infra VM  : 새 policy rosa-to-maxscale (aws-vpn → nw-data, priority -2, target CONTINUE, 규칙 3개)
#                 기존 aws-to-data(priority -1, target DROP)보다 먼저 평가 → 맞으면 accept, 아니면 그대로 aws-to-data로
#   ② DevOps VM : zone nw-data에 ROSA 서브넷 3개 → 4006/tcp rich rule (runtime + permanent, reload 없음)
#   반환: DevOps VM 10.20.0.0/16 via 192.168.44.62 (0929 적용), 응답은 conntrack
# 실행 위치: Infra VM (root). DevOps VM은 SSH(root@192.168.14.21, Mgmt)로 처리
#   bash setup_rosa_maxscale_1006.sh <단계>            # dry-run (기본, 변경 없음)
#   bash setup_rosa_maxscale_1006.sh <단계> --apply    # 적용
# 단계
#   allow   ① + ② 추가 (있으면 기대값과 비교만, 다르면 중단)
#   verify  읽기만: policy·rich rule·nft 반영, DevOps 규칙, MaxScale 4006 LISTEN, ESP 2개
#   remove  Cutover 후 ① policy 삭제 + ② 규칙 3개 삭제 (기대값과 정확히 같을 때만)
# 하지 않는 일
#   - 기존 aws-to-data·data-to-aws·aws-to-dmz policy, nw-data zone의 기존 규칙(워커·monitoring 4006 등) 변경
#   - DB 계정 허용 대역(MaxScale/MariaDB 사용자 host) — 정현
#   - AWS 쪽 라우트·SG (ROSA RT → VGW, VPN static 192.168.44.0/24는 이미 있음)
# 주의: "명령 | grep -q"·"| head" 같은 조기 종료 파이프를 쓰지 않는다 (pipefail 거짓 실패, 작업일지 0930 3.9)
set -euo pipefail

ROSA_SRCS="10.20.16.0/20 10.20.32.0/20 10.20.48.0/20"   # modules/network rosa_subnets 기본값 (10/6 describe-subnets로 확인)
MAXSCALE_IP="192.168.44.21"
PORT=4006
POLICY="rosa-to-maxscale"
PRIORITY=-2
DEVOPS_HOST="${DEVOPS_HOST:-root@192.168.14.21}"
DEVOPS_ZONE="nw-data"

usage() { echo "사용법: bash $0 <allow|verify|remove> [--apply]" >&2; exit 1; }
PHASE="${1:-}"
APPLY=0
case "${2:-}" in "") ;; --apply) APPLY=1 ;; *) usage ;; esac
case "$PHASE" in allow|verify|remove) ;; *) usage ;; esac

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ⚠ %s → 중단\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
mode() { if [[ $APPLY -eq 1 ]]; then echo "APPLY"; else echo "DRY-RUN"; fi; }
[[ $EUID -eq 0 ]] || die "root로 실행"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
ssh_d() { ssh -o ConnectTimeout=10 -o ControlMaster=auto -o "ControlPath=/root/.ssh/cm-%r@%h:%p" -o ControlPersist=120 "$DEVOPS_HOST" "$@"; }

infra_rule() { printf 'rule family="ipv4" source address="%s" destination address="%s" port port="%s" protocol="tcp" accept' "$1" "$MAXSCALE_IP" "$PORT"; }
devops_rule() { printf 'rule family="ipv4" source address="%s" port port="%s" protocol="tcp" accept' "$1" "$PORT"; }
expected_infra() { local c; for c in $ROSA_SRCS; do infra_rule "$c"; echo; done | sort; }
expected_devops() { local c; for c in $ROSA_SRCS; do devops_rule "$c"; echo; done | sort; }
esp_count() { ipsec trafficstatus 2>/dev/null | grep -c 'type=ESP' || true; }

policy_exists() { local p; for p in $(firewall-cmd --permanent --get-policies); do [[ "$p" == "$POLICY" ]] && return 0; done; return 1; }
policy_rules() { firewall-cmd --permanent --policy="$POLICY" --list-rich-rules | sort; }
policy_field() { firewall-cmd --permanent --policy="$POLICY" "$1"; }
devops_has_rule() { ssh_d "firewall-cmd --permanent --zone=$DEVOPS_ZONE --query-rich-rule='$1' >/dev/null 2>&1"; }
devops_runtime_has_rule() { ssh_d "firewall-cmd --zone=$DEVOPS_ZONE --query-rich-rule='$1' >/dev/null 2>&1"; }

preflight() {
    local z
    for z in aws-vpn nw-data; do
        firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -cx "$z" >/dev/null || die "Infra zone ${z} 없음"
    done
    local ad
    ad="$(firewall-cmd --permanent --policy=aws-to-data --get-priority 2>/dev/null || echo '?')"
    [[ "$ad" == "-1" ]] || die "aws-to-data priority=${ad} (기대 -1) → 평가 순서 재검토"
    ssh_d true || die "DevOps VM SSH 실패: ${DEVOPS_HOST}"
    local lis
    lis="$(ssh_d "ss -ltn 'sport = :$PORT'" | awk 'NR>1{print $4}' | sort -u | paste -sd' ')"
    [[ "$lis" == *"${MAXSCALE_IP}:${PORT}"* ]] || die "DevOps VM에서 ${MAXSCALE_IP}:${PORT} LISTEN 없음 (${lis:-없음})"
    ssh_d "firewall-cmd --get-active-zones" | grep -cx "$DEVOPS_ZONE" >/dev/null || die "DevOps VM zone ${DEVOPS_ZONE} 비활성"
    log "전제 OK: Infra aws-vpn·nw-data, aws-to-data priority -1 / DevOps ${MAXSCALE_IP}:${PORT} LISTEN, ${DEVOPS_ZONE} 활성 / ESP $(esp_count)개"
}

phase_allow() {
    preflight
    # ① Infra policy
    if policy_exists; then
        [[ "$(policy_rules)" == "$(expected_infra)" ]] || die "policy ${POLICY}가 이미 있으나 규칙이 기대값과 다름 → 수동 확인"
        [[ "$(policy_field --get-priority)" == "$PRIORITY" && "$(policy_field --get-target)" == "CONTINUE" ]] || die "policy ${POLICY} priority/target이 다름"
        log "① Infra policy ${POLICY} 이미 있음 (기대값 일치) → 건너뜀"
    else
        log "① Infra policy ${POLICY} 생성 예정: aws-vpn → nw-data, priority ${PRIORITY}, target CONTINUE ($(mode))"
        expected_infra | sed 's/^/     /'
        if [[ $APPLY -eq 1 ]]; then
            local before after c
            before="$(esp_count)"
            firewall-cmd --permanent --new-policy="$POLICY" >/dev/null
            firewall-cmd --permanent --policy="$POLICY" --add-ingress-zone=aws-vpn >/dev/null
            firewall-cmd --permanent --policy="$POLICY" --add-egress-zone=nw-data >/dev/null
            firewall-cmd --permanent --policy="$POLICY" --set-priority="$PRIORITY" >/dev/null
            firewall-cmd --permanent --policy="$POLICY" --set-target=CONTINUE >/dev/null
            for c in $ROSA_SRCS; do firewall-cmd --permanent --policy="$POLICY" --add-rich-rule="$(infra_rule "$c")" >/dev/null; done
            firewall-cmd --reload >/dev/null
            sleep 2; after="$(esp_count)"
            log "   생성·reload 완료, ESP ${before} → ${after}"
            [[ "$after" -ge "$before" ]] || log "   ⚠ ESP 감소 → ipsec trafficstatus 확인"
        fi
    fi
    # ② DevOps rules (runtime + permanent)
    local c r
    for c in $ROSA_SRCS; do
        r="$(devops_rule "$c")"
        if devops_has_rule "$r" && devops_runtime_has_rule "$r"; then
            log "② DevOps ${DEVOPS_ZONE}: ${c} → ${PORT} 이미 있음 → 건너뜀"
            continue
        fi
        log "② DevOps ${DEVOPS_ZONE}: ${c} → ${PORT}/tcp 추가 예정 (runtime + permanent, reload 없음) ($(mode))"
        if [[ $APPLY -eq 1 ]]; then
            ssh_d "firewall-cmd --zone=$DEVOPS_ZONE --add-rich-rule='$r' >/dev/null 2>&1 || true; firewall-cmd --permanent --zone=$DEVOPS_ZONE --add-rich-rule='$r' >/dev/null 2>&1 || true"
            devops_has_rule "$r" && devops_runtime_has_rule "$r" || die "DevOps 규칙 추가 확인 실패: ${c}"
        fi
    done
    [[ $APPLY -eq 1 ]] && phase_verify
    return 0
}

phase_verify() {
    log "[verify]"
    if policy_exists; then
        log "  Infra ${POLICY}: priority $(policy_field --get-priority), target $(policy_field --get-target), ingress $(policy_field --list-ingress-zones), egress $(policy_field --list-egress-zones)"
        [[ "$(policy_rules)" == "$(expected_infra)" ]] && log "  규칙 3개 = 기대값 ✅" || log "  ⚠ 규칙이 기대값과 다름"
        local rt
        rt="$(firewall-cmd --policy="$POLICY" --list-rich-rules 2>/dev/null | sort)"
        [[ "$rt" == "$(expected_infra)" ]] && log "  runtime = permanent ✅" || log "  ⚠ runtime 규칙이 permanent와 다름 (reload 필요?)"
        local n
        n="$(nft list ruleset 2>/dev/null | grep -c "${MAXSCALE_IP} tcp dport ${PORT}" || true)"
        log "  nft 반영 규칙 ${n}개 (기대 3)"
    else
        log "  Infra ${POLICY}: 없음"
    fi
    local c r ok=0
    for c in $ROSA_SRCS; do
        r="$(devops_rule "$c")"
        if devops_has_rule "$r" && devops_runtime_has_rule "$r"; then ok=$((ok+1)); fi
    done
    log "  DevOps ${DEVOPS_ZONE} ROSA→${PORT} 규칙 ${ok}/3 (runtime·permanent 모두)"
    log "  기존 aws-to-data 규칙: $(firewall-cmd --policy=aws-to-data --list-rich-rules | wc -l)개 (변경 없음 확인용)"
    log "  ESP $(esp_count)개"
    log "  실제 연결 확인은 ROSA 생성 후 (예린/정현): oc debug node/<워커> -- chroot /host bash -c 'timeout 5 bash -c \"</dev/tcp/${MAXSCALE_IP}/${PORT}\" && echo OPEN'"
}

phase_remove() {
    preflight
    if policy_exists; then
        [[ "$(policy_rules)" == "$(expected_infra)" ]] || die "policy ${POLICY} 규칙이 기대값과 다름 → 자동 삭제하지 않음"
        log "① Infra policy ${POLICY} 삭제 예정 ($(mode))"
        if [[ $APPLY -eq 1 ]]; then
            firewall-cmd --permanent --delete-policy="$POLICY" >/dev/null
            firewall-cmd --reload >/dev/null
            log "   삭제·reload 완료, ESP $(esp_count)"
        fi
    else
        log "① Infra policy ${POLICY} 없음 → 건너뜀"
    fi
    local c r
    for c in $ROSA_SRCS; do
        r="$(devops_rule "$c")"
        if devops_has_rule "$r" || devops_runtime_has_rule "$r"; then
            log "② DevOps ${DEVOPS_ZONE}: ${c} → ${PORT} 삭제 예정 ($(mode))"
            [[ $APPLY -eq 1 ]] && ssh_d "firewall-cmd --zone=$DEVOPS_ZONE --remove-rich-rule='$r' >/dev/null 2>&1 || true; firewall-cmd --permanent --zone=$DEVOPS_ZONE --remove-rich-rule='$r' >/dev/null 2>&1 || true"
        else
            log "② DevOps ${DEVOPS_ZONE}: ${c} 규칙 없음 → 건너뜀"
        fi
    done
    [[ $APPLY -eq 1 ]] && phase_verify
    return 0
}

log "단계=${PHASE} 모드=$(mode)"
"phase_${PHASE}"
log "완료 (${PHASE}, $(mode))"
