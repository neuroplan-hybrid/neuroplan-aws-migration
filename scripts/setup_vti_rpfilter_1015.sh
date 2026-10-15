#!/usr/bin/env bash
# setup_vti_rpfilter_1015.sh
# 목적: Infra VM의 vti1·vti2 rp_filter=2 를 재부팅 후에도 유지 (10/15 VPN 장애 ③ 재발 방지)
# 실행 위치: Infra VM (root). 기본은 읽기 전용(DRY-RUN), 실제 변경은 --apply 가 있을 때만.
#
# 사용법
#   setup_vti_rpfilter_1015.sh status             현재 값과 충돌 가능 설정 조회 (변경 없음). vti 가 없으면 SKIP(검증 안 됨)으로 표시
#   setup_vti_rpfilter_1015.sh status --strict    위와 같되 SKIP 이 하나라도 있으면 종료 코드 1 (실행 중 값까지 확인할 때)
#   setup_vti_rpfilter_1015.sh apply              DRY-RUN: 무엇을 바꿀지만 출력
#   setup_vti_rpfilter_1015.sh apply --apply      실제 적용 (설정 파일 생성 + 현재 값 즉시 반영)
#   setup_vti_rpfilter_1015.sh rollback --apply   설정 파일 철회 (완전 원복 아님: 실행 중 값은 유지, 이전 백업은 자동 복원 안 함)
#
# 원인 근거 (10/15 16:12 Infra VM 조회, 읽기 전용):
#   /usr/lib/sysctl.d/50-default.conf  net.ipv4.conf.*.rp_filter = 2   (systemd 기본)
#   /usr/lib/sysctl.d/50-redhat.conf   net.ipv4.conf.*.rp_filter = 1   (RHEL 기본, 파일명 순서상 나중이라 이쪽이 이김)
#   현재 conf.default = 1 → 새로 생기는 인터페이스는 1로 시작하고, 생성 시 systemd-sysctl 이 '*' 항목을 적용하면 1이 됨
#   updown 이 2를 쓰는 시점과 이 적용의 선후가 매번 같지 않으면 vti2 가 1로 남을 수 있음 (선후 자체는 로그로 확인 못함)
#   → 99-* 파일은 systemd-sysctl 이 적용할 때 50-redhat.conf 뒤에 읽혀 그 경로에서는 최종값이 2
#   ※ 수동 sysctl·다른 설정 파일 등 다른 프로세스의 덮어쓰기까지 막는다고 단정하지 않음. 재부팅 후 유지는 미실측
#
# 건드리는 것: /etc/sysctl.d/99-neuroplan-vti-rpfilter.conf 1개, vti1·vti2 의 rp_filter 값
# 건드리지 않는 것: ipsec 재시작, 라우트, firewalld, conf.all / conf.default, 다른 sysctl 항목
# 종료 코드: 0 정상, 1 검증 실패(--strict 에서는 SKIP 포함), 2 사용법/권한 오류
# ※ status 통과는 VPN 정상 판정이 아님. 적용 후 check_vpn_state_0930.sh --aws, 역복제 상태는 별도 확인
set -euo pipefail

IFACES=(vti1 vti2)
WANT=2
CONF_FILE="${NP_SYSCTL_DIR:-/etc/sysctl.d}/99-neuroplan-vti-rpfilter.conf"
PROC_CONF="${NP_PROC_CONF:-/proc/sys/net/ipv4/conf}"
SEARCH_PATHS="${NP_SEARCH_PATHS:-/etc/sysctl.d /run/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d /etc/sysctl.conf}"

MODE="${1:-}"
APPLY=0
STRICT=0

usage() { sed -n '2,24p' "$0"; exit 2; }
[[ "$MODE" == "status" || "$MODE" == "apply" || "$MODE" == "rollback" ]] || usage
case "${2:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  --strict) STRICT=1 ;;
  *) usage ;;
esac
if [[ "$MODE" == "status" && $APPLY -eq 1 ]]; then usage; fi
if [[ "$MODE" != "status" && $STRICT -eq 1 ]]; then usage; fi

read_val() {  # $1=all|default|vtiN → 값, 없으면 -
  local f="$PROC_CONF/$1/rp_filter"
  if [[ -r "$f" ]]; then tr -d '[:space:]' < "$f"; else echo "-"; fi
}

desired_content() {
  cat <<CONF
# NeuroPlan: 비대칭 경로(온프렘→AWS 는 vti1, AWS→온프렘 응답은 vti2 로 수신)에서
# rp_filter=1(strict) 이면 vti2 입구에서 패킷이 버려짐 (10/15 장애 ③). 설계값은 2(loose).
# 항목 앞의 '-' 는 부팅 시점에 인터페이스가 아직 없어도 오류로 치지 않는다는 뜻.
# 파일 이름 99-* 는 OS 기본 설정(50-* 등)보다 나중에 적용되게 하려는 것.
CONF
  for i in "${IFACES[@]}"; do
    echo "-net.ipv4.conf.${i}.rp_filter = ${WANT}"
  done
}

show_status() {
  echo "== 현재 rp_filter (유효값 = all 과 인터페이스 값 중 큰 값)"
  local all def
  all="$(read_val all)"; def="$(read_val default)"
  printf '  all=%s  default=%s\n' "$all" "$def"
  local bad=0 i v eff
  local skipped=()
  for i in "${IFACES[@]}"; do
    v="$(read_val "$i")"
    if [[ "$v" == "-" ]]; then
      printf '  %-5s SKIP (인터페이스 없음 → 현재 값 검증 안 됨. 터널 DOWN 이면 정상)\n' "$i"
      skipped+=("$i"); continue
    fi
    eff=$v; [[ "$all" =~ ^[0-9]+$ && "$all" -gt "$eff" ]] && eff=$all
    if [[ "$v" == "$WANT" ]]; then
      printf '  %-5s %s (유효 %s)  OK\n' "$i" "$v" "$eff"
    else
      printf '  %-5s %s (유효 %s)  FAIL (기대 %s)\n' "$i" "$v" "$eff" "$WANT"; bad=1
    fi
  done
  echo "== 현재 값 검증 요약"
  if (( ${#skipped[@]} )); then
    echo "  검증 안 됨(SKIP): ${skipped[*]}"
    [[ $STRICT -eq 1 ]] && { echo "  --strict: SKIP 이 있어 실패로 처리"; bad=1; }
  else
    echo "  vti1·vti2 모두 현재 값 검증함"
  fi
  echo "== 설정 파일"
  if [[ -f "$CONF_FILE" ]]; then
    if [[ "$(desired_content)" == "$(cat "$CONF_FILE")" ]]; then echo "  있음, 내용 일치: $CONF_FILE"
    else echo "  있음, 내용 다름: $CONF_FILE"; bad=1; fi
  else
    echo "  없음: $CONF_FILE"; bad=1
  fi
  echo "== rp_filter 를 건드리는 다른 설정 (원인 확인용, 우리 파일 제외)"
  # shellcheck disable=SC2086
  grep -rnH 'rp_filter' $SEARCH_PATHS 2>/dev/null | grep -v "$(basename "$CONF_FILE")" | sed 's/^/  /' || true
  echo "※ status 통과는 VPN 정상 판정이 아님. check_vpn_state_0930.sh --aws 와 역복제 상태를 별도로 확인할 것"
  return $bad
}

need_root() {
  if [[ $APPLY -eq 1 && "${NP_ALLOW_NONROOT:-0}" != "1" && $EUID -ne 0 ]]; then
    echo "[ERROR] --apply 는 root 로 실행하세요" >&2; exit 2
  fi
}

do_apply() {
  need_root
  local tag="[DRY-RUN]"; [[ $APPLY -eq 1 ]] && tag="[APPLY]"
  echo "$tag 설정 파일: $CONF_FILE"
  if [[ -f "$CONF_FILE" && "$(desired_content)" == "$(cat "$CONF_FILE")" ]]; then
    echo "$tag 파일 내용이 이미 같음 → 변경 없음"
  else
    if [[ $APPLY -eq 1 ]]; then
      if [[ -f "$CONF_FILE" ]]; then
        cp -p "$CONF_FILE" "$CONF_FILE.bak.$(date +%m%d-%H%M%S)"; echo "$tag 기존 파일 백업 완료"
      fi
      desired_content > "$CONF_FILE.tmp" && chmod 0644 "$CONF_FILE.tmp" && mv "$CONF_FILE.tmp" "$CONF_FILE"
      echo "$tag 파일 기록 완료"
    else
      echo "$tag 아래 내용으로 생성/교체 예정:"; desired_content | sed 's/^/    /'
    fi
  fi
  local i v
  for i in "${IFACES[@]}"; do
    v="$(read_val "$i")"
    if [[ "$v" == "-" ]]; then
      echo "$tag $i 없음 → 지금은 건너뜀 (생성 시 설정 파일이 적용됨)"
    elif [[ "$v" == "$WANT" ]]; then
      echo "$tag $i 이미 $WANT"
    elif [[ $APPLY -eq 1 ]]; then
      echo "$WANT" > "$PROC_CONF/$i/rp_filter"; echo "$tag $i $v → $WANT 즉시 반영"
    else
      echo "$tag $i 현재 $v → $WANT 로 변경 예정"
    fi
  done
  if [[ $APPLY -eq 1 ]]; then
    echo; show_status
  else
    echo; echo "$tag 실제 적용은 'apply --apply'. 이 모드에서는 아무것도 바꾸지 않았음"
  fi
}

do_rollback() {
  need_root
  local tag="[DRY-RUN]"; [[ $APPLY -eq 1 ]] && tag="[APPLY]"
  if [[ ! -f "$CONF_FILE" ]]; then echo "$tag 설정 파일 없음 → 할 일 없음"; return 0; fi
  if [[ $APPLY -eq 1 ]]; then
    mv "$CONF_FILE" "$CONF_FILE.removed.$(date +%m%d-%H%M%S)"
    echo "$tag 설정 파일을 .removed.* 로 옮김. 이는 추가한 영구 설정의 철회이며 완전 원복이 아님"
    echo "$tag 실행 중 rp_filter 값은 그대로 유지됨. 재부팅 후에는 OS 기본값(50-redhat.conf 의 1)이 다시 적용될 수 있음"
  else
    echo "$tag $CONF_FILE 를 .removed.* 로 옮길 예정 (철회일 뿐 완전 원복 아님, 실행 중 값은 유지)"
  fi
  local baks=()
  shopt -s nullglob
  baks=("$CONF_FILE".bak.*)
  shopt -u nullglob
  if (( ${#baks[@]} )); then
    echo "$tag 이전 백업이 있음 (자동 복원하지 않음): ${baks[*]}"
    echo "$tag 복원하려면 직접: mv <위 백업 중 하나> $CONF_FILE"
  fi
}

case "$MODE" in
  status)   show_status && rc=0 || rc=$?; exit $rc ;;
  apply)    do_apply; if [[ $APPLY -eq 1 ]]; then show_status >/dev/null && exit 0 || exit 1; fi ;;
  rollback) do_rollback ;;
esac
