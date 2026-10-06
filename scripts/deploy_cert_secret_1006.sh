#!/bin/bash
# deploy_cert_secret_1006.sh — 발급한 인증서를 K8s/OpenShift TLS Secret으로 등록하고 Infra VM 사본 정리 (작업일지 1006 4.1, 이슈 #34, 스크립트 PR 3/3)
#
# 실행 위치: Infra VM (root). 인증서는 issue_cert_dns01_1006.sh production 결과(/root/certbot-neuroplan/prod)
#   Secret은 SSH로 kubectl/oc가 있는 호스트에 stdin으로 넘겨 생성 → 대상 호스트 디스크·명령줄에 키가 남지 않음
#   bash deploy_cert_secret_1006.sh <단계>            # dry-run (기본, 변경 없음)
#   bash deploy_cert_secret_1006.sh <단계> --apply    # 적용
# 단계
#   onprem        neuroplan-onprem → 온프렘 K8s Secret application/neuroplan-cloud-onprem-tls (CP1_HOST 필요)
#   rosa          neuroplan-rosa   → OpenShift Secret neuroplan/neuroplan-cloud-rosa-tls (ROSA_HOST 필요, 10/12 이후)
#   status        로컬 인증서와 원격 Secret의 지문(SHA256) 비교 (읽기만)
#   purge-onprem  원격 Secret 지문이 로컬과 같을 때만 Infra VM의 neuroplan-onprem 사본 삭제
#   purge-rosa    위와 같음 (neuroplan-rosa)
# 환경 변수
#   CP1_HOST   온프렘 kubectl 호스트 SSH 대상 (예: root@<cp1 Mgmt 주소>)
#   ROSA_HOST  oc 로그인된 호스트 SSH 대상 (10/12 이후)
#
# 확인 (적용 전, 하나라도 어긋나면 중단)
#   - 운영 인증서(발급자에 STAGING 없음), SAN 기대값과 정확히 일치, 만료 14일 이상 남음
#   - 개인 키와 인증서 공개 키 일치, 키 파일 권한 600
#   - SSH 접속(ConnectTimeout 10), 원격 CLI·namespace 존재
#   - 원격 Secret이 이미 있으면: 같은 인증서면 건너뜀, 다르면 덮어쓰지 않고 중단
# 하지 않는 일
#   - kubectl apply (last-applied annotation에 키가 한 벌 더 저장됨) → create만 사용
#   - Gateway listener·HTTPRoute 연결 (setup_dr_health_1006.sh gateway·route), ROSA Route 연결 (예린)
#   - 키 내용 출력·파일 저장 (지문만 출력)
# 주의: "명령 | grep -q"·"| head" 같은 조기 종료 파이프를 쓰지 않는다 (pipefail 거짓 실패, 작업일지 0930 3.9)
set -euo pipefail

BASE="/root/certbot-neuroplan/prod/config"
DOMAIN="neuroplan.cloud"
LABEL_K="neuroplan.io/owner"
LABEL_V="heejae-cert"
MIN_DAYS=14

usage() { echo "사용법: bash $0 <onprem|rosa|status|purge-onprem|purge-rosa> [--apply]" >&2; exit 1; }
PHASE="${1:-}"
APPLY=0
case "${2:-}" in "") ;; --apply) APPLY=1 ;; *) usage ;; esac

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ⚠ %s → 중단 (변경 없음)\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
mode() { if [[ $APPLY -eq 1 ]]; then echo "APPLY"; else echo "DRY-RUN"; fi; }
[[ $EUID -eq 0 ]] || die "root로 실행"
umask 077
mkdir -p /root/.ssh && chmod 700 /root/.ssh

# 대상별 설정: cert_name|host_var|cli|namespace|secret|SAN(정렬, 쉼표)
target() {
    case "$1" in
        onprem) echo "neuroplan-onprem|CP1_HOST|kubectl|application|neuroplan-cloud-onprem-tls|app.${DOMAIN},dr-health.${DOMAIN}" ;;
        rosa)   echo "neuroplan-rosa|ROSA_HOST|oc|neuroplan|neuroplan-cloud-rosa-tls|app.${DOMAIN},primary-health.${DOMAIN}" ;;
        *) usage ;;
    esac
}
load() {  # $1 onprem|rosa → 전역 변수 설정
    IFS='|' read -r CERT HOSTVAR CLI NS SECRET SANS <<<"$(target "$1")"
    HOST="${!HOSTVAR:-}"
    CRT="${BASE}/live/${CERT}/fullchain.pem"
    KEY="${BASE}/live/${CERT}/privkey.pem"
}
# 연결 1개를 재사용 (비밀번호 접속이어도 처음 1회만 입력)
ssh_t() { ssh -o ConnectTimeout=10 -o ControlMaster=auto -o "ControlPath=/root/.ssh/cm-%r@%h:%p" -o ControlPersist=120 "$HOST" "$@"; }
fp_local() { openssl x509 -in "$CRT" -noout -fingerprint -sha256 | cut -d= -f2; }
fp_remote() {  # 원격 Secret 인증서 지문 (없으면 빈 문자열)
    ssh_t "$CLI -n $NS get secret $SECRET -o jsonpath='{.data.tls\\.crt}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2" || true
}

check_local() {
    [[ -f "$CRT" && -f "$KEY" ]] || die "${CERT} 운영 인증서 없음 (${CRT}) → issue_cert_dns01_1006.sh production 먼저"
    local issuer san end_days kp cp perm
    issuer="$(openssl x509 -in "$CRT" -noout -issuer)"
    [[ "$issuer" != *STAGING* ]] || die "${CERT}가 staging 인증서 (${issuer})"
    san="$(openssl x509 -in "$CRT" -noout -ext subjectAltName | tr -d ' ' | tr ',' '\n' | sed -n 's/^DNS://p' | sort | paste -sd,)"
    [[ "$san" == "$SANS" ]] || die "${CERT} SAN=${san} (기대 ${SANS})"
    openssl x509 -in "$CRT" -noout -checkend $((MIN_DAYS*86400)) >/dev/null || die "${CERT} 만료까지 ${MIN_DAYS}일 미만"
    end_days=$(( ( $(date -d "$(openssl x509 -in "$CRT" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
    kp="$(openssl pkey -in "$KEY" -pubout 2>/dev/null | sha256sum | cut -c1-16)"
    cp="$(openssl x509 -in "$CRT" -noout -pubkey | sha256sum | cut -c1-16)"
    [[ -n "$kp" && "$kp" == "$cp" ]] || die "${CERT} 개인 키와 인증서 공개 키 불일치"
    perm="$(stat -L -c '%a' "$KEY")"
    [[ "$perm" == "600" ]] || die "${CERT} 키 권한 ${perm} (기대 600)"
    log "로컬 ${CERT}: ${issuer#issuer=}, SAN ${san}, 남은 ${end_days}일, 키·인증서 일치, 키 600"
    log "  지문 SHA256 $(fp_local)"
}

check_remote() {
    [[ -n "$HOST" ]] || die "${HOSTVAR} 환경 변수 없음 (예: ${HOSTVAR}=root@<주소> bash $0 ${PHASE})"
    ssh_t true || die "SSH 접속 실패: ${HOST}"
    ssh_t "command -v $CLI >/dev/null" || die "${HOST}에 ${CLI} 없음"
    ssh_t "$CLI get namespace $NS >/dev/null 2>&1" || die "${HOST}: namespace ${NS} 없음 또는 권한 없음"
    log "원격 ${HOST}: ${CLI} OK, namespace ${NS} OK"
}

secret_yaml() {
cat <<EOF
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: ${SECRET}
  namespace: ${NS}
  labels:
    ${LABEL_K}: ${LABEL_V}
  annotations:
    neuroplan.io/source: "Let's Encrypt DNS-01 ${CERT} (issue_cert_dns01_1006.sh), 작업일지 1006 4.1"
data:
  tls.crt: $(base64 -w0 "$CRT")
  tls.key: $(base64 -w0 "$KEY")
EOF
}

deploy() {
    load "$1"
    log "단계=${PHASE} 모드=$(mode) 대상=${CLI} ${NS}/${SECRET}"
    check_local
    check_remote
    local rfp lfp
    lfp="$(fp_local)"; rfp="$(fp_remote)"
    if [[ -n "$rfp" ]]; then
        [[ "$rfp" == "$lfp" ]] || die "Secret ${NS}/${SECRET}가 이미 있고 다른 인증서 (원격 ${rfp}) → 덮어쓰지 않음, 수동 확인"
        log "Secret ${NS}/${SECRET} 이미 같은 인증서로 있음 → 건너뜀"
        return 0
    fi
    log "Secret ${NS}/${SECRET} 생성 예정 (kubectl create, stdin 전달 — 원격 디스크·명령줄에 키 없음)"
    if [[ $APPLY -eq 1 ]]; then
        secret_yaml | ssh_t "$CLI create -f -"
    else
        secret_yaml | ssh_t "$CLI create --dry-run=server -f - -o name"
        return 0
    fi
    rfp="$(fp_remote)"
    [[ "$rfp" == "$lfp" ]] || die "생성 후 지문 불일치 (원격 ${rfp:-없음})"
    log "확인: 원격 Secret 지문 = 로컬 (${lfp})"
    log "다음: onprem이면 setup_dr_health_1006.sh gateway → route → verify, 확인 후 purge-onprem --apply"
}

purge() {
    load "$1"
    log "단계=${PHASE} 모드=$(mode) 대상=${CERT}"
    local d="$BASE"
    [[ -d "${d}/live/${CERT}" ]] || { log "${CERT} 사본 없음 → 할 일 없음"; return 0; }
    check_remote
    local rfp lfp
    lfp="$(fp_local)"; rfp="$(fp_remote)"
    [[ -n "$rfp" && "$rfp" == "$lfp" ]] || die "원격 Secret ${NS}/${SECRET} 지문이 로컬과 다르거나 없음 → 사본을 지우지 않음"
    log "원격 Secret 확인 (지문 일치) → 삭제 예정: ${d}/{live,archive}/${CERT}, ${d}/renewal/${CERT}.conf"
    [[ $APPLY -eq 1 ]] || return 0
    rm -rf "${d}/live/${CERT}" "${d}/archive/${CERT}" "${d}/renewal/${CERT}.conf"
    [[ ! -e "${d}/archive/${CERT}" ]] && log "삭제 완료 (개인 키 사본 없음)"
}

status() {
    local t
    for t in onprem rosa; do
        load "$t"
        if [[ -f "$CRT" ]]; then log "${CERT} 로컬: $(fp_local)"; else log "${CERT} 로컬: 없음"; fi
        if [[ -n "$HOST" ]] && ssh_t true 2>/dev/null; then
            log "  원격 ${HOST} ${NS}/${SECRET}: $(fp_remote || true)"
        else
            log "  원격: ${HOSTVAR} 미설정 또는 접속 불가 → 건너뜀"
        fi
    done
}

case "$PHASE" in
    onprem|rosa)   deploy "$PHASE" ;;
    purge-onprem)  purge onprem ;;
    purge-rosa)    purge rosa ;;
    status)        status ;;
    *)             usage ;;
esac
log "완료 (${PHASE}, $(mode))"
