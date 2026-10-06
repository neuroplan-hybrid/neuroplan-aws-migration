#!/bin/bash
# issue_cert_dns01_1006.sh — Let's Encrypt DNS-01 인증서 발급 (작업일지 1006 4.1·6.1, 이슈 #34, 스크립트 PR 2/3)
#
# 인증서 2개 (환경별 분리, #34)
#   neuroplan-onprem : app.neuroplan.cloud, dr-health.neuroplan.cloud       → 온프렘 NGF (PR 3/3에서 배포)
#   neuroplan-rosa   : app.neuroplan.cloud, primary-health.neuroplan.cloud  → ROSA Route (10/12 이후, 예린)
# 실행 위치: Infra VM (root). certbot은 임시 Role 프로필(AWS_PROFILE=certbot-dns01)로만 Route 53에 접근
#   전제: setup_certbot_role_1006.sh create·verify 완료 (Role neuroplan-certbot-dns01, 세션 1시간)
#   bash issue_cert_dns01_1006.sh <단계>            # dry-run (기본, 변경 없음)
#   bash issue_cert_dns01_1006.sh <단계> --apply    # 적용
# 단계 (순서대로)
#   install     /opt/certbot-venv 에 certbot + certbot-dns-route53 설치 (pip, venv). EPEL 등 저장소는 추가하지 않음
#   staging     Let's Encrypt 시험용(staging)으로 2개 발급 → 발급자 이름에 STAGING 확인 (발급 횟수 제한 회피용 사전 확인)
#   production  본 발급 2개 (staging 성공 후)
#   status      발급된 인증서 경로·SAN·만료일 (읽기만)
#   purge-staging  staging 디렉터리 삭제 (--apply)
#
# 보관 (#34·1006 6.1, root 실행은 #34 정정 댓글)
#   - certbot 디렉터리: /root/certbot-neuroplan/{staging,prod}/{config,work,logs}, 권한 700 (키 파일은 certbot이 600으로 생성)
#   - 개인 키는 Secret 등록 후 Infra VM에서 삭제 (PR 3/3). ROSA용은 10/12 등록 전까지만 보관
#   - 인증서·키는 Git·Terraform State·셸 기록에 남기지 않음 (이 스크립트는 경로만 출력)
# 하지 않는 일
#   - 자동 갱신 타이머 (90일 유효, 10/26 발표까지 갱신 불필요)
#   - Secret 생성·배포 (PR 3/3)
#   - _acme-challenge TXT를 Terraform으로 관리 (certbot이 만들고 지움)
# 주의: "명령 | grep -q"·"| head" 같은 조기 종료 파이프를 쓰지 않는다 (pipefail 거짓 실패, 작업일지 0930 3.9)
set -euo pipefail

VENV="/opt/certbot-venv"
BASE="/root/certbot-neuroplan"
PROFILE="certbot-dns01"
ROLE="neuroplan-certbot-dns01"
DOMAIN="neuroplan.cloud"
CERTS=("neuroplan-onprem|app.${DOMAIN},dr-health.${DOMAIN}" "neuroplan-rosa|app.${DOMAIN},primary-health.${DOMAIN}")

usage() { echo "사용법: bash $0 <install|staging|production|status|purge-staging> [--apply]" >&2; exit 1; }
PHASE="${1:-}"
APPLY=0
case "${2:-}" in "") ;; --apply) APPLY=1 ;; *) usage ;; esac
case "$PHASE" in install|staging|production|status|purge-staging) ;; *) usage ;; esac

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ⚠ %s → 중단\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
mode() { if [[ $APPLY -eq 1 ]]; then echo "APPLY"; else echo "DRY-RUN"; fi; }
[[ $EUID -eq 0 ]] || die "root로 실행 (AWS 원래 자격 증명이 root에 있음, #34 정정)"
umask 077
log "단계=${PHASE} 모드=$(mode)"

phase_install() {
    command -v python3 >/dev/null || die "python3 없음"
    if [[ -x "${VENV}/bin/certbot" ]]; then
        log "이미 설치됨: $("${VENV}/bin/certbot" --version 2>&1)"
        "${VENV}/bin/python" -c "import certbot_dns_route53" || die "route53 플러그인 없음 → ${VENV} 삭제 후 다시 install"
        return 0
    fi
    log "설치 예정: python3 -m venv ${VENV} → pip install certbot certbot-dns-route53 ($(mode))"
    log "python3: $(python3 --version 2>&1)"
    [[ $APPLY -eq 1 ]] || return 0
    python3 -m venv "$VENV" || die "venv 생성 실패 → dnf install -y python3-pip 후 다시 실행"
    "${VENV}/bin/pip" install -q --upgrade pip
    "${VENV}/bin/pip" install -q certbot certbot-dns-route53
    log "설치 완료: $("${VENV}/bin/certbot" --version 2>&1), 플러그인 $("${VENV}/bin/pip" show certbot-dns-route53 | sed -n 's/^Version: //p')"
    "${VENV}/bin/certbot" plugins 2>/dev/null | sed -n '/dns-route53/,+1p'
}

preflight() {
    [[ -x "${VENV}/bin/certbot" ]] || die "certbot 없음 (install 먼저)"
    local arn
    arn="$(AWS_PROFILE="$PROFILE" aws sts get-caller-identity --query Arn --output text 2>&1)" || die "임시 Role assume 실패: ${arn}"
    [[ "$arn" == *":assumed-role/${ROLE}/"* ]] || die "예상 밖 자격 증명: ${arn}"
    log "자격 증명: assumed-role/${ROLE}/… (AWS_PROFILE=${PROFILE})"
}

dirs_for() { echo "${BASE}/$1"; }   # $1 staging|prod

issue() {  # $1 staging|prod
    local env="$1" d extra=()
    d="$(dirs_for "$env")"
    [[ "$env" == "staging" ]] && extra=(--test-cert)
    preflight
    local pair name domains
    for pair in "${CERTS[@]}"; do
        name="${pair%%|*}"; domains="${pair##*|}"
        if [[ -f "${d}/config/live/${name}/fullchain.pem" ]]; then
            log "${env}/${name} 이미 있음 → 건너뜀 (재발급하지 않음, 필요하면 수동 확인)"
            continue
        fi
        log "${env}/${name} 발급 예정: ${domains} ($(mode))"
        [[ $APPLY -eq 1 ]] || continue
        mkdir -p "${d}/config" "${d}/work" "${d}/logs"
        chmod 700 "$BASE" "$d" "${d}/config" "${d}/work" "${d}/logs"
        AWS_PROFILE="$PROFILE" "${VENV}/bin/certbot" certonly \
            --dns-route53 --non-interactive --agree-tos --register-unsafely-without-email \
            --config-dir "${d}/config" --work-dir "${d}/work" --logs-dir "${d}/logs" \
            --cert-name "$name" -d "$domains" --key-type ecdsa "${extra[@]}"
        show_cert "$env" "$name"
    done
}

show_cert() {  # $1 env, $2 name
    local f
    f="$(dirs_for "$1")/config/live/$2/fullchain.pem"
    [[ -f "$f" ]] || { log "$1/$2: 없음"; return 0; }
    log "$1/$2: ${f}"
    openssl x509 -in "$f" -noout -issuer -enddate -ext subjectAltName | sed 's/^/    /'
    local key
    key="$(dirs_for "$1")/config/archive/$2"
    log "    키 권한: $(stat -c '%a %U' "${key}"/privkey*.pem 2>/dev/null | sort -u | tr '\n' ' ')"
    if [[ "$1" == "staging" ]]; then
        openssl x509 -in "$f" -noout -issuer | grep -c STAGING >/dev/null && log "    발급자 STAGING 확인 ✅" || log "    ⚠ 발급자에 STAGING 없음"
    fi
}

phase_staging()    { issue staging; }
phase_production() {
    local s n
    for s in "${CERTS[@]}"; do
        n="${s%%|*}"
        [[ -f "$(dirs_for staging)/config/live/${n}/fullchain.pem" ]] || die "staging/${n} 없음 → staging 성공 확인 후 본 발급"
    done
    issue prod
}
phase_status() {
    local env pair
    for env in staging prod; do for pair in "${CERTS[@]}"; do show_cert "$env" "${pair%%|*}"; done; done
}
phase_purge_staging() {
    local d
    d="$(dirs_for staging)"
    [[ -d "$d" ]] || { log "staging 디렉터리 없음"; return 0; }
    log "삭제 예정: ${d} ($(mode))"
    [[ $APPLY -eq 1 ]] && rm -rf "$d" && log "삭제 완료"
    return 0
}

"phase_${PHASE//-/_}"
log "완료 (${PHASE}, $(mode))"
