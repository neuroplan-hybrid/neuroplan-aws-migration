#!/bin/bash
# setup_certbot_role_1006.sh — certbot DNS-01용 임시 IAM Role 생성·검증·정리 (작업일지 1006 4.1·6.1, 이슈 #34)
#
# 방식: 새 Access Key를 만들지 않고, 기존 heejae 프로필이 임시 Role을 assume (세션 1시간)
#   certbot --dns-route53 은 AWS_PROFILE=certbot-dns01 로 실행 → 임시 자격 증명만 사용
# 실행 위치: Infra VM (AWS CLI, 기존 프로필 = IAM 사용자 heejae), 리전 무관(IAM·Route 53은 글로벌)
#   bash setup_certbot_role_1006.sh <단계>            # dry-run (기본, 변경 없음)
#   bash setup_certbot_role_1006.sh <단계> --apply    # 적용
# 단계
#   create   Role + inline 정책 생성, ~/.aws/config에 프로필 certbot-dns01 추가
#   verify   읽기 + 테스트 레코드: assume 확인 → 허용 레코드(_acme-challenge.dr-health TXT) UPSERT·DELETE 성공
#            → 비허용 레코드(_denied-test TXT) UPSERT 거부(AccessDenied) 확인. --apply일 때만 레코드 변경 시도
#            안전장치 (PR #41 리뷰): ① 시작 전 SOURCE_PROFILE로 두 테스트 이름에 기존 TXT가 있는지 확인 → 있으면 변경 없이 중단
#            ② 허용 TXT UPSERT 성공 직후 trap 등록 → 중간 실패·Ctrl+C·종료 시에도 테스트 TXT DELETE 시도, 정상 DELETE 후 trap 해제
#   cleanup  inline 정책·Role 삭제, 프로필 제거 → get-role NoSuchEntity 확인 (두 인증서 배포·검증 후)
#
# 권한 정책 (Action마다 Resource 분리 — 한 ARN에 묶으면 GetChange·ListHostedZones 실패, 정현 조건 1)
#   - route53:ListHostedZones      → "*"  (리소스 단위 제한이 없는 API)
#   - route53:GetChange            → arn:aws:route53:::change/*
#   - route53:ChangeResourceRecordSets → Zone만 + 조건: 이름 _acme-challenge.{app,dr-health,primary-health}.neuroplan.cloud,
#     타입 TXT, 동작 UPSERT·DELETE (certbot-dns-route53은 UPSERT로 추가, DELETE로 삭제)
# 하지 않는 일
#   - Access Key 생성 (셸 기록·파일에 키가 남지 않음)
#   - Terraform 관리 (발급 기간에만 쓰는 임시 리소스 → 수동 예외, 작업일지에 명령·결과 기록)
#   - 계정 ID를 코드에 쓰지 않음 (실행 시 sts로 조회)
# 주의: "명령 | grep -q"·"| head" 같은 조기 종료 파이프를 쓰지 않는다 (pipefail 거짓 실패, 작업일지 0930 3.9)
set -euo pipefail

ROLE="neuroplan-certbot-dns01"
POLICY_NAME="certbot-dns01-route53"
PROFILE="certbot-dns01"
SOURCE_PROFILE="${SOURCE_PROFILE:-default}"
EXPECT_USER="heejae"
ZONE_ID="Z021384539IIHK7FGMEMN"
DOMAIN="neuroplan.cloud"
ALLOWED_NAMES=("_acme-challenge.app.${DOMAIN}" "_acme-challenge.dr-health.${DOMAIN}" "_acme-challenge.primary-health.${DOMAIN}")
TEST_OK="_acme-challenge.dr-health.${DOMAIN}"
TEST_DENY="_denied-test.${DOMAIN}"
AWS_CONFIG="${AWS_CONFIG_FILE:-$HOME/.aws/config}"

usage() { echo "사용법: bash $0 <create|verify|cleanup> [--apply]" >&2; exit 1; }
PHASE="${1:-}"
APPLY=0
case "${2:-}" in "") ;; --apply) APPLY=1 ;; *) usage ;; esac
case "$PHASE" in create|verify|cleanup) ;; *) usage ;; esac

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ⚠ %s → 중단\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
mode() { if [[ $APPLY -eq 1 ]]; then echo "APPLY"; else echo "DRY-RUN"; fi; }
for c in aws python3; do command -v "$c" >/dev/null || die "$c 없음"; done

# ---------- 전제: 실행 주체 ----------
CALLER="$(aws sts get-caller-identity --profile "$SOURCE_PROFILE" --query Arn --output text)" || die "sts 실패 (프로필 ${SOURCE_PROFILE})"
[[ "$CALLER" == arn:aws:iam::*:user/${EXPECT_USER} ]] || die "실행 주체 ${CALLER} (기대 user/${EXPECT_USER})"
ACCOUNT="$(aws sts get-caller-identity --profile "$SOURCE_PROFILE" --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE}"
log "단계=${PHASE} 모드=$(mode) 실행 주체=user/${EXPECT_USER} (계정 ID는 출력하지 않음)"

trust_json() {
    python3 - "$ACCOUNT" "$EXPECT_USER" <<'EOF'
import json, sys
acct, user = sys.argv[1], sys.argv[2]
print(json.dumps({"Version": "2012-10-17", "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": f"arn:aws:iam::{acct}:user/{user}"},
    "Action": "sts:AssumeRole"}]}, sort_keys=True))
EOF
}

policy_json() {
    python3 - "$ZONE_ID" "${ALLOWED_NAMES[@]}" <<'EOF'
import json, sys
zone, names = sys.argv[1], sys.argv[2:]
print(json.dumps({"Version": "2012-10-17", "Statement": [
    {"Sid": "ListZones", "Effect": "Allow", "Action": "route53:ListHostedZones", "Resource": "*"},
    {"Sid": "GetChange", "Effect": "Allow", "Action": "route53:GetChange", "Resource": "arn:aws:route53:::change/*"},
    {"Sid": "AcmeTxtOnly", "Effect": "Allow", "Action": "route53:ChangeResourceRecordSets",
     "Resource": f"arn:aws:route53:::hostedzone/{zone}",
     "Condition": {"ForAllValues:StringEquals": {
         "route53:ChangeResourceRecordSetsNormalizedRecordNames": names,
         "route53:ChangeResourceRecordSetsRecordTypes": ["TXT"],
         "route53:ChangeResourceRecordSetsActions": ["UPSERT", "DELETE"]}}}]}, sort_keys=True))
EOF
}

norm() { python3 -c 'import json,sys,urllib.parse; d=sys.stdin.read().strip(); d=urllib.parse.unquote(d) if d.startswith("%7B") else d; print(json.dumps(json.loads(d), sort_keys=True))'; }
role_exists() { aws iam get-role --role-name "$ROLE" --profile "$SOURCE_PROFILE" >/dev/null 2>&1; }
profile_exists() { [[ -f "$AWS_CONFIG" ]] && python3 - "$AWS_CONFIG" "$PROFILE" <<'EOF'
import configparser, sys
c = configparser.RawConfigParser(); c.read(sys.argv[1])
sys.exit(0 if c.has_section(f"profile {sys.argv[2]}") else 1)
EOF
}

# ---------- create ----------
phase_create() {
    if role_exists; then
        local t p
        t="$(aws iam get-role --role-name "$ROLE" --profile "$SOURCE_PROFILE" --query Role.AssumeRolePolicyDocument --output json | norm)"
        p="$(aws iam get-role-policy --role-name "$ROLE" --policy-name "$POLICY_NAME" --profile "$SOURCE_PROFILE" --query PolicyDocument --output json 2>/dev/null | norm || echo none)"
        [[ "$t" == "$(trust_json)" ]] || die "Role ${ROLE}가 이미 있으나 trust 정책이 다름 → 수동 확인"
        [[ "$p" == "$(policy_json)" ]] || die "Role ${ROLE}가 이미 있으나 inline 정책이 다르거나 없음 → 수동 확인"
        log "Role ${ROLE} 이미 있음 (trust·정책 일치) → 건너뜀"
    else
        log "Role ${ROLE} 생성 예정 (세션 1시간, 태그 Project=NeuroPlan Owner=heejae Purpose=certbot-dns01)"
        log "trust: $(trust_json | sed "s/${ACCOUNT}/<ACCOUNT_ID>/")"
        log "policy: $(policy_json)"
        if [[ $APPLY -eq 1 ]]; then
            aws iam create-role --profile "$SOURCE_PROFILE" --role-name "$ROLE" --max-session-duration 3600 \
                --assume-role-policy-document "$(trust_json)" \
                --description "certbot DNS-01 temporary role (issue #34), delete after issuance" \
                --tags Key=Project,Value=NeuroPlan Key=Owner,Value=heejae Key=Purpose,Value=certbot-dns01 \
                --query Role.RoleName --output text
            aws iam put-role-policy --profile "$SOURCE_PROFILE" --role-name "$ROLE" \
                --policy-name "$POLICY_NAME" --policy-document "$(policy_json)"
            log "Role·정책 생성 완료"
        fi
    fi

    if profile_exists; then
        local ra
        ra="$(aws configure get role_arn --profile "$PROFILE")"
        [[ "$ra" == "$ROLE_ARN" ]] || die "프로필 ${PROFILE}가 이미 있으나 role_arn이 다름 → 수동 확인"
        log "프로필 ${PROFILE} 이미 있음 → 건너뜀"
    else
        log "프로필 ${PROFILE} 추가 예정 (${AWS_CONFIG}, role_arn=…:role/${ROLE}, source_profile=${SOURCE_PROFILE}, 키 입력 없음)"
        if [[ $APPLY -eq 1 ]]; then
            mkdir -p "$(dirname "$AWS_CONFIG")"
            [[ -f "$AWS_CONFIG" ]] && cp -p "$AWS_CONFIG" "${AWS_CONFIG}.bak-$(date +%m%d%H%M)"
            printf '\n[profile %s]\nrole_arn = %s\nsource_profile = %s\nduration_seconds = 3600\nregion = ap-northeast-2\n' \
                "$PROFILE" "$ROLE_ARN" "$SOURCE_PROFILE" >> "$AWS_CONFIG"
            chmod 600 "$AWS_CONFIG"
        fi
    fi
}

# ---------- verify ----------
change_txt() {  # $1 action, $2 name → change id 또는 에러 메시지
    local batch
    batch="$(printf '{"Changes":[{"Action":"%s","ResourceRecordSet":{"Name":"%s","Type":"TXT","TTL":60,"ResourceRecords":[{"Value":"\\"certbot-role-verify\\""}]}}]}' "$1" "$2")"
    aws route53 change-resource-record-sets --profile "$PROFILE" --hosted-zone-id "$ZONE_ID" \
        --change-batch "$batch" --query ChangeInfo.Id --output text 2>&1
}
txt_exists() {  # $1 name → 기존 TXT RRset 수 (SOURCE_PROFILE, 읽기만)
    aws route53 list-resource-record-sets --profile "$SOURCE_PROFILE" --hosted-zone-id "$ZONE_ID" \
        --start-record-name "$1" --start-record-type TXT --max-items 1 \
        --query "length(ResourceRecordSets[?Name=='${1}.' && Type=='TXT'])" --output text
}
TEST_TXT_PENDING=0
cleanup_test_txt() {  # trap: 테스트 TXT가 남았을 수 있으면 삭제 시도 (Role → 실패 시 SOURCE_PROFILE)
    local rc=$?
    trap - EXIT INT TERM
    if [[ $TEST_TXT_PENDING -eq 1 ]]; then
        log "중단 감지 → 테스트 TXT ${TEST_OK} 삭제 시도"
        local out
        out="$(change_txt DELETE "$TEST_OK")" || true
        if [[ "$out" != /change/* ]]; then
            out="$(PROFILE="$SOURCE_PROFILE" change_txt DELETE "$TEST_OK")" || true
        fi
        if [[ "$out" == /change/* ]]; then log "  삭제 요청 OK (${out##*/})"
        else log "  ⚠ 삭제 실패 → 콘솔에서 ${TEST_OK} TXT(\"certbot-role-verify\") 확인·삭제: ${out}"; fi
    fi
    exit "$rc"
}
on_signal() { log "신호 수신 (Ctrl+C 등)"; exit 130; }

wait_insync() {
    local i s
    for i in $(seq 1 20); do
        s="$(aws route53 get-change --profile "$PROFILE" --id "$1" --query ChangeInfo.Status --output text)"
        [[ "$s" == "INSYNC" ]] && { log "  get-change ${1##*/}: INSYNC (${i}회)"; return 0; }
        sleep 3
    done
    die "get-change ${1} INSYNC 대기 시간 초과"
}

phase_verify() {
    role_exists || die "Role ${ROLE} 없음 (create 먼저)"
    profile_exists || die "프로필 ${PROFILE} 없음 (create 먼저)"
    local arn i
    for i in $(seq 1 12); do   # IAM 전파 대기 (최대 약 60초)
        if arn="$(aws sts get-caller-identity --profile "$PROFILE" --query Arn --output text 2>/dev/null)"; then break; fi
        sleep 5
    done
    [[ "${arn:-}" == *":assumed-role/${ROLE}/"* ]] || die "assume 실패 또는 예상 밖 ARN: ${arn:-없음}"
    log "① assume OK: assumed-role/${ROLE}/…"
    local zones
    zones="$(aws route53 list-hosted-zones --profile "$PROFILE" --query "HostedZones[?Name=='${DOMAIN}.'].Id" --output text)"
    [[ "$zones" == *"$ZONE_ID"* ]] || die "ListHostedZones에서 ${ZONE_ID} 안 보임: ${zones}"
    log "② ListHostedZones OK (${ZONE_ID})"

    local n name
    for name in "$TEST_OK" "$TEST_DENY"; do
        n="$(txt_exists "$name")" || die "기존 레코드 조회 실패 (${name})"
        [[ "$n" == "0" ]] || die "${name}에 기존 TXT가 있음 (${n}) → 덮어쓰지 않도록 변경 없이 중단, 기존 값 확인 필요"
    done
    log "기존 TXT 없음 확인: ${TEST_OK}, ${TEST_DENY} (SOURCE_PROFILE 조회)"

    if [[ $APPLY -ne 1 ]]; then
        log "DRY-RUN: ③ 허용 TXT UPSERT·DELETE(${TEST_OK}), ④ 비허용 TXT UPSERT 거부(${TEST_DENY})는 --apply에서 실행"
        return 0
    fi
    local out
    trap on_signal INT TERM
    out="$(change_txt UPSERT "$TEST_OK")" || true
    [[ "$out" == /change/* ]] || die "③ 허용 레코드 UPSERT 실패: ${out}"
    TEST_TXT_PENDING=1
    trap cleanup_test_txt EXIT
    wait_insync "$out"
    out="$(change_txt DELETE "$TEST_OK")" || true
    [[ "$out" == /change/* ]] || die "③ 허용 레코드 DELETE 실패: ${out}"
    wait_insync "$out"
    TEST_TXT_PENDING=0
    trap - EXIT INT TERM
    log "③ 허용 레코드 ${TEST_OK} TXT UPSERT·DELETE OK (GetChange 포함, trap 해제)"

    out="$(change_txt UPSERT "$TEST_DENY")" || true
    if [[ "$out" == /change/* ]]; then
        log "⚠ ④ 비허용 레코드가 생성됨 → 즉시 삭제 시도 (정책 범위 오류)"
        change_txt DELETE "$TEST_DENY" || true
        die "④ 정책이 비허용 레코드를 막지 못함 → cleanup 후 정책 재검토"
    fi
    [[ "$out" == *AccessDenied* ]] || die "④ 예상한 AccessDenied가 아님: ${out}"
    log "④ 비허용 레코드 ${TEST_DENY} UPSERT → AccessDenied (최소 권한 확인)"
}

# ---------- cleanup ----------
phase_cleanup() {
    local has_role=0 has_profile=0
    role_exists && has_role=1
    profile_exists && has_profile=1
    log "정리 대상: Role=${has_role} 프로필=${has_profile} ($(mode))"
    if [[ $has_role -eq 1 ]]; then
        local tag
        tag="$(aws iam list-role-tags --role-name "$ROLE" --profile "$SOURCE_PROFILE" --query "Tags[?Key=='Purpose'].Value" --output text)"
        [[ "$tag" == "certbot-dns01" ]] || die "Role ${ROLE} Purpose 태그='${tag}' → 이 스크립트가 만든 Role이 아님"
    fi
    [[ $APPLY -eq 1 ]] || { log "DRY-RUN: 실행은 --apply"; return 0; }
    if [[ $has_role -eq 1 ]]; then
        aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY_NAME" --profile "$SOURCE_PROFILE" 2>/dev/null || true
        aws iam delete-role --role-name "$ROLE" --profile "$SOURCE_PROFILE"
    fi
    if [[ $has_profile -eq 1 ]]; then
        cp -p "$AWS_CONFIG" "${AWS_CONFIG}.bak-$(date +%m%d%H%M)"
        python3 - "$AWS_CONFIG" "$PROFILE" <<'EOF'
import sys
path, prof = sys.argv[1], sys.argv[2]
out, skip = [], False
for line in open(path):
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        skip = (s == f"[profile {prof}]")
    if not skip:
        out.append(line)
open(path, "w").writelines(out)
EOF
    fi
    local gr
    gr="$(aws iam get-role --role-name "$ROLE" --profile "$SOURCE_PROFILE" 2>&1)" || true
    [[ "$gr" == *NoSuchEntity* ]] || die "Role이 아직 조회됨"
    log "확인: get-role → NoSuchEntity"
    profile_exists && die "프로필이 남아 있음" || log "확인: 프로필 ${PROFILE} 없음"
}

"phase_${PHASE}"
log "완료 (${PHASE}, $(mode))"
