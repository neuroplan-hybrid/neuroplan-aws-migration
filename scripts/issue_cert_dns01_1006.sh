#!/bin/bash
# issue_cert_dns01_1006.sh — DNS-01 인증서 발급 (작업일지 1006 4.1·6.1, 이슈 #34, 스크립트 PR 2/3)
#                            + 예비 CA ZeroSSL Warm Standby (이슈 #59, 1007 멘토링 반영)
#
# 인증서 2개 (환경별 분리, #34) — CA가 달라도 SAN은 같음
#   neuroplan-onprem : app.neuroplan.cloud, dr-health.neuroplan.cloud       → 온프렘 NGF
#   neuroplan-rosa   : app.neuroplan.cloud, primary-health.neuroplan.cloud  → ROSA Route externalCertificate
# 실행 위치: Infra VM (root). certbot은 임시 Role 프로필(AWS_PROFILE=certbot-dns01)로만 Route 53에 접근
#   전제: setup_certbot_role_1006.sh create·verify 완료 (Role neuroplan-certbot-dns01, 세션 1시간)
#   bash issue_cert_dns01_1006.sh <단계> [--ca letsencrypt|zerossl] [--apply]   # 기본: letsencrypt, dry-run
#
# 단계 — Let's Encrypt (--ca letsencrypt, 기본값, 기존 동작·경로 그대로)
#   install        /opt/certbot-venv 에 certbot + certbot-dns-route53 설치 (pip, venv). 저장소는 추가하지 않음
#   staging        LE 시험용(staging)으로 2개 발급 → 발급자 STAGING 확인
#   production     본 발급 2개 (staging 성공 후)
#   status         발급된 인증서 경로·SAN·만료일 (읽기만)
#   purge-staging  LE staging 디렉터리 삭제
#
# 단계 — ZeroSSL (--ca zerossl, 예비 CA, #59)
#   register       EAB로 ZeroSSL ACME 계정 등록 (1회). 성공하면 EAB 파일 삭제
#   production     예비 인증서 2개 발급 (staging 없음 → 이 발급이 DNS-01 실제 검증). SAN을 정의값·LE 사본과 먼저 대조
#   status         예비 인증서 경로·SAN·만료일 (읽기만)
#   purge          ZeroSSL 디렉터리 전체 삭제 (10/26 폐기)
#
# EAB (ZeroSSL 대시보드 → Developer → EAB Credentials) 전달 방식
#   - 명령줄 인자(--eab-kid 등)로 넘기지 않는다 (ps·셸 기록에 남음) → certbot 설정 파일(--config)로만 전달
#   - 파일: /root/certbot-neuroplan/zerossl/eab.ini (root 소유, 600), 형식 2줄:
#       eab-kid = (EAB KID)
#       eab-hmac-key = (EAB HMAC Key)
#     만드는 법: umask 077; vi /root/certbot-neuroplan/zerossl/eab.ini  (값은 채팅·메신저·Git에 붙이지 않음)
#   - 이 스크립트는 값을 출력하지 않는다 (키 이름·권한만 확인)
#
# 보관 (#34·1006 6.1·#59)
#   - LE      : /root/certbot-neuroplan/{staging,prod}/{config,work,logs}
#   - ZeroSSL : /root/certbot-neuroplan/zerossl/prod/{config,work,logs}  (Secret 사전 배포 없음, 10/26 purge)
#   - 디렉터리 700, 키 파일은 certbot이 600으로 생성
#   - 인증서·키·EAB는 Git·Terraform State·셸 기록에 남기지 않음 (이 스크립트는 경로만 출력)
# 하지 않는 일
#   - 자동 갱신 타이머 (90일 유효, 10/26 발표까지 갱신 불필요)
#   - Secret 생성·교체 (LE: deploy_cert_secret_1006.sh / ZeroSSL 비상 교체: 런북 수동 절차)
#   - _acme-challenge TXT를 Terraform으로 관리 (certbot이 만들고 지움)
# 주의: "명령 | grep -q"·"| head" 같은 조기 종료 파이프를 쓰지 않는다 (pipefail 거짓 실패, 작업일지 0930 3.9)
set -euo pipefail

VENV="/opt/certbot-venv"
BASE="/root/certbot-neuroplan"
PROFILE="certbot-dns01"
ROLE="neuroplan-certbot-dns01"
DOMAIN="neuroplan.cloud"
CERTS=("neuroplan-onprem|app.${DOMAIN},dr-health.${DOMAIN}" "neuroplan-rosa|app.${DOMAIN},primary-health.${DOMAIN}")
ZEROSSL_SERVER="https://acme.zerossl.com/v2/DV90"
ZEROSSL_DIR="${BASE}/zerossl"
EAB_FILE="${ZEROSSL_DIR}/eab.ini"

usage() {
    echo "사용법: bash $0 <단계> [--ca letsencrypt|zerossl] [--apply]" >&2
    echo "  letsencrypt: install | staging | production | status | purge-staging" >&2
    echo "  zerossl    : register | production | status | purge" >&2
    exit 1
}
PHASE="${1:-}"
[[ -n "$PHASE" ]] || usage
shift
CA="letsencrypt"
APPLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --ca) [[ $# -ge 2 ]] || usage; CA="$2"; shift ;;
        *) usage ;;
    esac
    shift
done
case "$CA" in
    letsencrypt) case "$PHASE" in install|staging|production|status|purge-staging) ;; *) usage ;; esac ;;
    zerossl)     case "$PHASE" in register|production|status|purge) ;; *) usage ;; esac ;;
    *) usage ;;
esac

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ⚠ %s → 중단\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
mode() { if [[ $APPLY -eq 1 ]]; then echo "APPLY"; else echo "DRY-RUN"; fi; }
[[ $EUID -eq 0 ]] || die "root로 실행 (AWS 원래 자격 증명이 root에 있음, #34 정정)"
umask 077
log "CA=${CA} 단계=${PHASE} 모드=$(mode)"

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

dirs_for() {  # $1 staging|prod|zerossl
    case "$1" in
        zerossl) echo "${ZEROSSL_DIR}/prod" ;;
        *)       echo "${BASE}/$1" ;;
    esac
}

make_dirs() {  # $1 디렉터리 (config·work·logs 생성, 700)
    mkdir -p "$1/config" "$1/work" "$1/logs"
    chmod 700 "$BASE" "$1" "$1/config" "$1/work" "$1/logs"
    [[ "$1" == "${ZEROSSL_DIR}/"* ]] && chmod 700 "$ZEROSSL_DIR"
    return 0
}

# certbot 결과물의 SAN 목록 (정렬, 쉼표 구분)
san_of() {  # $1 fullchain.pem
    openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' | sed -n 's/^ *DNS://p' | sort | paste -sd, -
}

issue() {  # $1 staging|prod|zerossl
    local env="$1" d extra=()
    d="$(dirs_for "$env")"
    case "$env" in
        staging) extra=(--test-cert) ;;
        zerossl) extra=(--server "$ZEROSSL_SERVER") ;;
    esac
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
        make_dirs "$d"
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
    # 인증서·개인 키 쌍 일치 (공개 키 해시 비교, 키 원문은 출력하지 않음)
    local live_key cert_pub key_pub
    live_key="$(dirs_for "$1")/config/live/$2/privkey.pem"
    if [[ -f "$live_key" ]]; then
        cert_pub="$(openssl x509 -in "$f" -noout -pubkey | openssl sha256 | awk '{print $NF}')"
        key_pub="$(openssl pkey -in "$live_key" -pubout | openssl sha256 | awk '{print $NF}')"
        if [[ "$cert_pub" == "$key_pub" ]]; then log "    키 쌍 일치 ✅"; else log "    ⚠ 키 쌍 불일치"; fi
    fi
    local issuer
    issuer="$(openssl x509 -in "$f" -noout -issuer)"
    case "$1" in
        staging) if [[ "$issuer" == *STAGING* ]]; then log "    발급자 STAGING 확인 ✅"; else log "    ⚠ 발급자에 STAGING 없음"; fi ;;
        zerossl) if [[ "$issuer" == *ZeroSSL* ]]; then log "    발급자 ZeroSSL 확인 ✅"; else log "    ⚠ 발급자에 ZeroSSL 없음"; fi ;;
    esac
    return 0
}

# ---------- Let's Encrypt ----------
phase_staging()    { issue staging; }
phase_production_letsencrypt() {
    local s n
    for s in "${CERTS[@]}"; do
        n="${s%%|*}"
        [[ -f "$(dirs_for staging)/config/live/${n}/fullchain.pem" ]] || die "staging/${n} 없음 → staging 성공 확인 후 본 발급"
    done
    issue prod
}
phase_status_letsencrypt() {
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

# ---------- ZeroSSL (#59) ----------
zerossl_account_exists() {
    [[ -d "$(dirs_for zerossl)/config/accounts/acme.zerossl.com" ]]
}

check_eab_file() {
    [[ -f "$EAB_FILE" ]] || die "EAB 파일 없음: ${EAB_FILE} (헤더 주석의 형식대로 root·600으로 생성)"
    [[ "$(stat -c '%a %U' "$EAB_FILE")" == "600 root" ]] || die "EAB 파일 권한이 600 root가 아님: $(stat -c '%a %U' "$EAB_FILE") → chmod 600 ${EAB_FILE}"
    local keys
    keys="$(sed -n 's/^[[:space:]]*\([a-z-]*\)[[:space:]]*=.*/\1/p' "$EAB_FILE" | sort | paste -sd, -)"
    [[ "$keys" == "eab-hmac-key,eab-kid" ]] || die "EAB 파일 키 이름이 다름 (필요: eab-kid, eab-hmac-key / 현재: ${keys:-없음})"
    log "EAB 파일 확인: ${EAB_FILE} (600 root, 키 2개, 값은 출력하지 않음)"
}

phase_register() {
    [[ -x "${VENV}/bin/certbot" ]] || die "certbot 없음 (install 먼저)"
    local d
    d="$(dirs_for zerossl)"
    if zerossl_account_exists; then
        log "ZeroSSL ACME 계정 이미 등록됨 → 건너뜀"
        [[ -f "$EAB_FILE" ]] && log "EAB 파일이 남아 있음 → 필요 없으면 삭제: rm -f ${EAB_FILE}"
        return 0
    fi
    check_eab_file
    log "등록 예정: server ${ZEROSSL_SERVER}, config-dir ${d}/config ($(mode))"
    [[ $APPLY -eq 1 ]] || return 0
    make_dirs "$d"
    "${VENV}/bin/certbot" register --config "$EAB_FILE" \
        --server "$ZEROSSL_SERVER" --non-interactive --agree-tos --register-unsafely-without-email \
        --config-dir "${d}/config" --work-dir "${d}/work" --logs-dir "${d}/logs"
    zerossl_account_exists || die "등록 후 계정 디렉터리 없음 → ${d}/logs/letsencrypt.log 확인"
    rm -f "$EAB_FILE"
    log "등록 완료, EAB 파일 삭제 (재발급은 ZeroSSL 대시보드에서)"
}

# 발급 전 SAN 대조 (staging이 없으므로 production 발급 전에 대상부터 확인, 정현 #59)
compare_san_before_issue() {
    local pair name want le have
    for pair in "${CERTS[@]}"; do
        name="${pair%%|*}"
        want="$(tr ',' '\n' <<<"${pair##*|}" | sort | paste -sd, -)"
        le="$(dirs_for prod)/config/live/${name}/fullchain.pem"
        if [[ -f "$le" ]]; then
            have="$(san_of "$le")"
            [[ "$have" == "$want" ]] || die "${name}: 발급 대상 SAN(${want}) ≠ LE 운영 인증서 SAN(${have})"
            log "${name}: 발급 대상 SAN = LE 운영 인증서 SAN ✅ (${want})"
        else
            log "${name}: LE 사본 없음 (Secret 등록 후 purge됨) → 정의값 기준 ${want} (런북: 운영 Secret과 대조)"
        fi
    done
}

phase_production_zerossl() {
    zerossl_account_exists || die "ZeroSSL ACME 계정 없음 → register 먼저"
    compare_san_before_issue
    issue zerossl
}

phase_status_zerossl() {
    local pair
    if zerossl_account_exists; then log "ZeroSSL ACME 계정: 등록됨"; else log "ZeroSSL ACME 계정: 없음"; fi
    if [[ -f "$EAB_FILE" ]]; then log "EAB 파일: 있음 (등록 후 삭제 대상)"; else log "EAB 파일: 없음"; fi
    for pair in "${CERTS[@]}"; do show_cert zerossl "${pair%%|*}"; done
}

phase_purge() {
    [[ -d "$ZEROSSL_DIR" ]] || { log "ZeroSSL 디렉터리 없음"; return 0; }
    log "삭제 예정: ${ZEROSSL_DIR} (예비 인증서·개인 키·ACME 계정·EAB 전부, $(mode))"
    [[ $APPLY -eq 1 ]] && rm -rf "$ZEROSSL_DIR" && log "삭제 완료"
    return 0
}

case "${CA}:${PHASE}" in
    letsencrypt:production) phase_production_letsencrypt ;;
    letsencrypt:status)     phase_status_letsencrypt ;;
    zerossl:production)     phase_production_zerossl ;;
    zerossl:status)         phase_status_zerossl ;;
    *)                      "phase_${PHASE//-/_}" ;;
esac
log "완료 (CA=${CA}, ${PHASE}, $(mode))"
