// k6_rto_1007.js — 사용자 관점 RTO 측정 (User RTO, #22·#53)
//
// 반복(VU별): ① 로그인 → ② 학습 상태 조회 → ③ Step 저장(completed 토글) → 짧은 대기
// 결과 분석은 k6_rto_summary_1007.py (T0 = 장애 주입 적용 시각, T3 = 3개 요청 30초 연속 성공 시작)
//
// 실행 위치: 측정용 PC (학원망 밖이 이상적), k6 v0.54+
//   k6 run \
//     -e BASE_URL=https://app.neuroplan.cloud \
//     -e TEST_EMAILS=user1@example.com,user2@example.com \
//     -e TEST_PASSWORD="$(read -rsp 'password: ' p; echo "$p")" \
//     -e DURATION=20m \
//     --out csv=k6_$(date +%m%d-%H%M).csv \
//     scripts/k6_rto_1007.js
//
// 비밀번호는 스크립트·Git·CSV에 남기지 않는다 (__ENV로만 전달, 요청 본문은 CSV에 기록되지 않음).
// 계정마다 비밀번호가 다르면 TEST_PASSWORDS=pw1,pw2 (TEST_EMAILS와 같은 순서).

import http from 'k6/http';
import { check, sleep, fail } from 'k6';
import exec from 'k6/execution';
import { Rate, Gauge } from 'k6/metrics';

const BASE_URL = (__ENV.BASE_URL || 'https://app.neuroplan.cloud').replace(/\/$/, '');
const EMAILS = (__ENV.TEST_EMAILS || __ENV.TEST_EMAIL || '').split(',').map((s) => s.trim()).filter(Boolean);
const PASSWORDS = (__ENV.TEST_PASSWORDS || '').split(',').map((s) => s.trim()).filter(Boolean);
const PASSWORD = __ENV.TEST_PASSWORD || '';
const STEP_NO = __ENV.STEP_NO || '1';
const PAUSE = Number(__ENV.PAUSE || '1');            // 반복 사이 대기(초)
const REQ_TIMEOUT = __ENV.REQ_TIMEOUT || '5s';       // 요청별 타임아웃 (장애 중 오래 매달리지 않게)
const INSECURE = (__ENV.INSECURE || 'false') === 'true'; // 테스트 환경(자체 서명)에서만 true

if (EMAILS.length === 0) {
  throw new Error('TEST_EMAILS(또는 TEST_EMAIL)가 비어 있음');
}
if (!PASSWORD && PASSWORDS.length !== EMAILS.length) {
  throw new Error('TEST_PASSWORD 또는 계정 수와 같은 개수의 TEST_PASSWORDS 필요');
}

// 요청 단계별 성공 여부 (분석 기준). tag: step=login|state|save, ip=실제 연결 IP
export const stepOk = new Rate('step_ok');
// 마지막으로 성공한 저장 값 (1 = completed true, 0 = false) → RPO·마지막 쓰기 확인용
export const lastSaved = new Gauge('last_saved_completed');

export const options = {
  scenarios: {
    rto: {
      executor: 'constant-vus',
      vus: EMAILS.length,                 // 계정 1개 = VU 1개 (계정별로 다른 플랜, 정현 안)
      duration: __ENV.DURATION || '10m',
      gracefulStop: '10s',
    },
  },
  // DNS 전환을 사용자처럼 따라가도록: k6 기본 DNS 캐시 5분 → ELB Alias TTL과 같은 60초
  dns: { ttl: __ENV.DNS_TTL || '60s', select: 'first', policy: 'preferIPv4' },
  insecureSkipTLSVerify: INSECURE,
  // keep-alive 연결은 DNS가 바뀌어도 이전 IP(ROSA)에 붙어 있음 → 장애 쪽이 503을 계속 돌려주면 RTO가 길게 잡힘
  // 기본 false(브라우저와 비슷), 전환 자체만 보고 싶으면 NO_REUSE=true (요청마다 새 연결)
  noConnectionReuse: (__ENV.NO_REUSE || 'false') === 'true',
  // 실패해도 측정은 계속 (임계값은 판정이 아니라 요약 표시용)
  thresholds: {
    step_ok: ['rate>0'],
    'http_req_duration{step:login}': ['p(95)>=0'],
    'http_req_duration{step:state}': ['p(95)>=0'],
    'http_req_duration{step:save}': ['p(95)>=0'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
};

// VU별 상태 (VU마다 독립)
let completedNext = true;

function record(step, res, ok) {
  stepOk.add(ok ? 1 : 0, { step, ip: (res && res.remote_ip) || 'none', code: String((res && res.status) || 0) });
}

function pickPlanId(res) {
  try {
    const body = res.json();
    if (body && Array.isArray(body.plans) && body.plans.length > 0 && body.plans[0].id != null) {
      return String(body.plans[0].id);
    }
    if (body && body.plan && body.plan.id != null) {
      return String(body.plan.id);
    }
  } catch (e) {
    // JSON이 아니면(장애 중 HTML 에러 페이지 등) planId 없음
  }
  return null;
}

export default function () {
  const idx = (exec.vu.idInTest - 1) % EMAILS.length;
  const email = EMAILS[idx];
  const password = PASSWORD || PASSWORDS[idx];
  const jar = http.cookieJar();
  jar.clear(BASE_URL);   // 반복마다 새 로그인 (정현 안: 매 반복 로그인 → 조회 → 저장)

  const common = { timeout: REQ_TIMEOUT, headers: { 'Content-Type': 'application/json' } };

  // ① 로그인
  const login = http.post(
    `${BASE_URL}/api/auth/login`,
    JSON.stringify({ email, password }),
    Object.assign({}, common, { tags: { step: 'login', name: 'login' } }),
  );
  const loginOk = check(login, { 'login 2xx': (r) => r.status >= 200 && r.status < 300 });
  record('login', login, loginOk);
  if (!loginOk) {
    sleep(PAUSE);
    return;
  }

  // ② 핵심 조회
  const state = http.get(
    `${BASE_URL}/api/learning/state`,
    Object.assign({}, common, { tags: { step: 'state', name: 'state' } }),
  );
  const planId = state.status === 200 ? pickPlanId(state) : null;
  const stateOk = check(state, {
    'state 200': (r) => r.status === 200,
    'state has plan': () => planId !== null,
  });
  record('state', state, stateOk);
  if (!stateOk) {
    sleep(PAUSE);
    return;
  }

  // ③ DB 쓰기 (completed 토글 → 데이터가 늘지 않음)
  const value = completedNext;
  const save = http.patch(
    `${BASE_URL}/api/learning/plans/${encodeURIComponent(planId)}/steps/${STEP_NO}`,
    JSON.stringify({ completed: value }),
    Object.assign({}, common, { tags: { step: 'save', name: 'save' } }),
  );
  const saveOk = check(save, { 'save 2xx': (r) => r.status >= 200 && r.status < 300 });
  record('save', save, saveOk);
  if (saveOk) {
    lastSaved.add(value ? 1 : 0, { vu: String(exec.vu.idInTest) });
    completedNext = !completedNext;   // 성공했을 때만 뒤집기 → 다음 저장이 실제 변경이 되도록
  }

  sleep(PAUSE);
}

export function setup() {
  if (!/^https?:\/\//.test(BASE_URL)) {
    fail(`BASE_URL 형식 오류: ${BASE_URL}`);
  }
  console.log(`[k6_rto] 시작 ${new Date().toISOString()} base=${BASE_URL} vus=${EMAILS.length} dns_ttl=${options.dns.ttl}`);
}

export function teardown() {
  console.log(`[k6_rto] 종료 ${new Date().toISOString()}`);
}
