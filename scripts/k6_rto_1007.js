// k6_rto_1007.js — 사용자 관점 RTO 측정 (User RTO, #22·#53)
//
// 반복(VU별): ① 로그인 → ② 학습 상태 조회 → ③ Step 저장(completed 토글) → 짧은 대기
// 결과 분석은 k6_rto_summary_1007.py
//   - RTO 정의는 #53 (T0 = 장애 주입 실제 적용 시각, 첫 실패 = 보조, T3 = 안정화 시각, User RTO = T3 − T0)
//   - T3의 안정화 조건은 #55에서 새로 정함: 로그인·조회·저장이 30초 동안 연속 성공하는 구간의 시작 시각
//
// 적용 범위·실행 기준 (#55, #56 리뷰)
//   - T3·T6 (복구시간, User RTO): LOGIN_MODE=iter + summary --mode rto
//       매 반복 로그인 → 조회 → 저장 전체 트랜잭션으로 T3 판정 (#55 T3 정의와 직접 일치)
//       → 측정 종료 후 테스트 계정 세션 정리 (운영 사용자 세션은 건드리지 않음, 절차·SQL은 정현)
//   - T1·T2·T5·T8 (연속성): LOGIN_MODE=session + summary --mode continuity
//       사용자 요청 실패 0건(또는 허용 이하) 확인, 세션 누적 최소화
//
// 사전 조건 (#56 리뷰)
//   - 시각 동기화: 장애 주입 PC와 k6 측정 PC 모두 NTP 동기화 확인 (timedatectl → "System clock synchronized: yes")
//     시연 직전 두 PC에서 `date '+%F %T.%N %z'` 비교, T0는 장애 주입 명령이 실제 적용된 시각을 KST로 기록
//   - 세션 누적: /api/auth/login은 호출마다 jwt_sessions에 새 행을 넣음 (Cookie Jar를 지워도 DB 세션은 남음)
//     LOGIN_MODE=iter(기본): 매 반복 로그인 — 로그인까지 포함한 사용자 트랜잭션 전체를 매회 검증하려는 의도적 선택
//       → 세션 수 ≈ 계정당 DURATION/(PAUSE+응답시간), 예: 20분·PAUSE 1초면 계정당 약 1,000건 → T3·T6 종료 후 테스트 계정 세션 정리
//     LOGIN_MODE=session: 처음·실패 직후·SESSION_RENEW(기본 10분)마다 로그인, 나머지는 Cookie 재사용
//       → Access Token TTL 15분 전에 선제 재로그인 → 장애 없이 토큰 만료로 생기는 가짜 401을 막음 (#56 리뷰 3)
//       → 20분 측정 시 로그인 2~3회 + 장애 횟수 수준. /api/auth/refresh는 요청 형식 미확인이라 재로그인으로 갱신
//       → Backend JWT_ACCESS_TTL(현재 15분)을 바꾸면 SESSION_RENEW와 아래 15분 검사도 함께 확인
//
// 실행 위치: 측정용 PC (학원망 밖이 이상적), k6 v0.54+
//   read -rsp 'TEST_PASSWORD: ' TEST_PASSWORD; echo
//   export TEST_PASSWORD
//   K6_CSV_TIME_FORMAT=rfc3339_nano k6 run \
//     -e BASE_URL=https://app.neuroplan.cloud \
//     -e TEST_EMAILS=user1@example.com,user2@example.com \
//     -e DURATION=20m \
//     --out csv=k6_$(date +%m%d-%H%M).csv \
//     scripts/k6_rto_1007.js
//   unset TEST_PASSWORD
//
// 비밀번호는 k6 명령행(-e)에 넣지 않는다 — 실행 중 프로세스 목록(ps)에 인자가 보임 (#56 리뷰).
// 환경변수로 export하면 k6가 __ENV.TEST_PASSWORD로 읽는다 (k6 run 기본: 시스템 환경변수 포함).
// 스크립트·Git·CSV에도 남지 않음 (요청 본문은 CSV에 기록되지 않음).
// 계정마다 비밀번호가 다르면 TEST_PASSWORDS=pw1,pw2 (TEST_EMAILS와 같은 순서, 같은 방식으로 export).
// 시연 전: 테스트 계정으로 DURATION=1m 시험 실행 → Cookie 유지·planId(plans[0].id / plan.id) 추출 확인

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
const LOGIN_MODE = __ENV.LOGIN_MODE || 'iter';       // iter | session (위 "세션 누적" 참고)
const SESSION_RENEW_S = parseDuration(__ENV.SESSION_RENEW || '10m'); // session 모드 선제 재로그인 주기 (Access Token 15분보다 짧게)

function parseDuration(v) {
  const m = /^(\d+(?:\.\d+)?)(s|m)?$/.exec(String(v).trim());
  if (!m) throw new Error(`SESSION_RENEW 형식 오류(예: 600s, 10m): ${v}`);
  return Number(m[1]) * (m[2] === 'm' ? 60 : 1);
}

if (LOGIN_MODE === 'session' && SESSION_RENEW_S >= 15 * 60) {
  throw new Error(`SESSION_RENEW(${SESSION_RENEW_S}s)는 Access Token TTL 15분보다 짧아야 함`);
}
if (LOGIN_MODE !== 'iter' && LOGIN_MODE !== 'session') {
  throw new Error(`LOGIN_MODE는 iter 또는 session: ${LOGIN_MODE}`);
}

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
let loggedIn = false;      // LOGIN_MODE=session에서만 사용
let savedCookies = {};     // k6는 반복마다 VU Cookie Jar를 비움 → session 모드는 로그인 Cookie를 직접 보관·복원
let loginAt = 0;           // 마지막 로그인 성공 시각(ms) → SESSION_RENEW 경과 시 선제 재로그인

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
  const common = { timeout: REQ_TIMEOUT, headers: { 'Content-Type': 'application/json' } };

  // ① 로그인 (iter: 매 반복 / session: 처음·실패 직후만)
  const jar = http.cookieJar();
  if (LOGIN_MODE === 'session' && loggedIn && Date.now() - loginAt >= SESSION_RENEW_S * 1000) {
    loggedIn = false;   // 토큰 만료 전 선제 재로그인
  }
  if (LOGIN_MODE === 'session' && loggedIn) {
    for (const [k, v] of Object.entries(savedCookies)) jar.set(BASE_URL, k, v);
  }
  if (LOGIN_MODE === 'iter' || !loggedIn) {
    jar.clear(BASE_URL);
    const login = http.post(
      `${BASE_URL}/api/auth/login`,
      JSON.stringify({ email, password }),
      Object.assign({}, common, { tags: { step: 'login', name: 'login' } }),
    );
    const loginOk = check(login, { 'login 2xx': (r) => r.status >= 200 && r.status < 300 });
    record('login', login, loginOk);
    loggedIn = loginOk;
    if (loginOk && LOGIN_MODE === 'session') {
      loginAt = Date.now();
      savedCookies = {};
      for (const [k, arr] of Object.entries(login.cookies)) {
        if (arr.length > 0) savedCookies[k] = arr[0].value;
      }
    }
    if (!loginOk) {
      sleep(PAUSE);
      return;
    }
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
    loggedIn = false;   // session 모드: 실패 직후 재로그인 → 복구 판정 구간에 로그인이 포함됨
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
  } else {
    loggedIn = false;
  }

  sleep(PAUSE);
}

export function setup() {
  if (!/^https?:\/\//.test(BASE_URL)) {
    fail(`BASE_URL 형식 오류: ${BASE_URL}`);
  }
  const now = new Date();
  const kst = new Date(now.getTime() + 9 * 3600 * 1000).toISOString().replace('T', ' ').replace('Z', ' KST');
  console.log(`[k6_rto] 시작 ${kst} (UTC ${now.toISOString()}) base=${BASE_URL} vus=${EMAILS.length} login=${LOGIN_MODE}${LOGIN_MODE === 'session' ? `(renew ${SESSION_RENEW_S}s)` : ''} dns_ttl=${options.dns.ttl}`);
  console.log('[k6_rto] 이 PC와 장애 주입 PC의 시각 차이가 RTO 오차가 됨 — NTP 동기화 확인 후 진행');
}

export function teardown() {
  console.log(`[k6_rto] 종료 ${new Date().toISOString()}`);
}
