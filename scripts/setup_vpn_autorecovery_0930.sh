#!/bin/bash
# setup_vpn_autorecovery_0930.sh — Infra VM 부팅 시 VPN 자동 복구 구성 (작업일지 0930 9장)
#
# 실행 위치: Infra VM (root). 레포의 scripts/ 폴더째 복사한 뒤 실행
#   bash setup_vpn_autorecovery_0930.sh            # dry-run (기본, 변경 없음)
#   bash setup_vpn_autorecovery_0930.sh --apply    # 적용
#
# 하는 일 (여러 번 실행해도 결과 동일)
#   1) ipsec 부팅 시 자동 시작 (systemctl enable)
#   2) updown 래퍼 설치: onprem/neuroplan-vti-updown → /usr/local/sbin (0755, SELinux bin_t)
#   3) aws.conf 'conn aws-common'의 vti-routing=no 다음 줄에 leftupdown= 추가 (백업 후)
#   4) ipsec addconn --checkconfig
# 하지 않는 일
#   - 터널 재기동: 적용은 재부팅, 또는 한 터널씩 'ipsec auto --replace aws-tunN && ipsec auto --up aws-tunN'
#   - aws.secrets, right=, leftikeport 수정 (7단계 범위)
#   - ip_forward 영구화, firewalld zone (이미 영구 설정됨. check_vpn_state_0930.sh로 확인)
set -euo pipefail

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_WRAPPER="${SCRIPT_DIR}/onprem/neuroplan-vti-updown"
DST_WRAPPER="/usr/local/sbin/neuroplan-vti-updown"
AWS_CONF="/etc/ipsec.d/aws.conf"
BACKUP="/root/aws.conf.bak_$(date +%m%d_%H%M%S)"

run() {
    if (( APPLY )); then echo "  + $*"; "$@"; else echo "  [dry-run] $*"; fi
}

(( EUID == 0 ))        || { echo "root로 실행해야 합니다" >&2; exit 1; }
[[ -f "$SRC_WRAPPER" ]] || { echo "래퍼 원본 없음: $SRC_WRAPPER" >&2; exit 1; }
[[ -f "$AWS_CONF" ]]    || { echo "설정 파일 없음: $AWS_CONF" >&2; exit 1; }
bash -n "$SRC_WRAPPER"

echo "== 모드: $( (( APPLY )) && echo APPLY || echo DRY-RUN )"

# 1) ipsec 자동 시작
echo "[1] ipsec 자동 시작"
if [[ "$(systemctl is-enabled ipsec 2>/dev/null || true)" == "enabled" ]]; then
    echo "  이미 enabled"
else
    run systemctl enable ipsec
fi

# 2) updown 래퍼 설치
echo "[2] updown 래퍼 ($DST_WRAPPER)"
if [[ -f "$DST_WRAPPER" ]] && cmp -s "$SRC_WRAPPER" "$DST_WRAPPER"; then
    echo "  이미 동일 (sha256 $(sha256sum "$DST_WRAPPER" | cut -c1-16)…)"
else
    run install -m 0755 -o root -g root "$SRC_WRAPPER" "$DST_WRAPPER"
    run restorecon -v "$DST_WRAPPER"
fi

# 3) leftupdown= 추가
echo "[3] $AWS_CONF leftupdown="
if grep -qE '^\s*leftupdown=' "$AWS_CONF"; then
    cur="$(grep -E '^\s*leftupdown=' "$AWS_CONF" | head -1 | tr -d '[:space:]')"
    if [[ "$cur" == "leftupdown=${DST_WRAPPER}" ]]; then
        echo "  이미 설정"
    else
        echo "  다른 leftupdown이 있음: $cur → 중단 (수동 확인)" >&2
        exit 1
    fi
else
    grep -qE '^\s*vti-routing=no' "$AWS_CONF" || { echo "  vti-routing=no 줄 없음 → 중단 (수동 확인)" >&2; exit 1; }
    run cp -p "$AWS_CONF" "$BACKUP"
    run sed -i "/^\s*vti-routing=no/a\\    leftupdown=${DST_WRAPPER}" "$AWS_CONF"
fi

# 4) 설정 검사 (읽기 전용)
echo "[4] 설정 검사"
ipsec addconn --checkconfig && echo "  CONFIG_OK"
grep -nE 'vti-routing|leftupdown' "$AWS_CONF" | sed 's/^/  /'
ls -lZ "$DST_WRAPPER" 2>/dev/null | sed 's/^/  /' || echo "  (래퍼 미설치)"

echo "== 완료. 터널 반영: 재부팅 또는 한 터널씩 --replace/--up → check_vpn_state_0930.sh로 확인"
