#!/usr/bin/env python3
"""k6_rto_summary_1007.py — k6 CSV에서 User RTO·연속성 판정 (#53 정의, #55 T3 안정화 조건)

적용 범위 (#55) — --mode 로 구분
  --mode rto (기본, T3·T6)          : k6 LOGIN_MODE=iter로 측정한 CSV. T0·첫 실패(보조)·T3·User RTO,
                                      장애 구간(T0→T3) 실패 수·에러율·p95/p99 (실패 0건이면 "User RTO 0초")
  --mode continuity (T1·T2·T5·T8)  : k6 LOGIN_MODE=session 권장. 실패 --allow-fail(기본 0)건 이하면 PASS (RTO 계산 안 함)
사전 조건: 장애 주입 PC와 k6 측정 PC NTP 동기화 (시각 차이가 그대로 RTO 오차)
--t0 는 두 mode 모두 필수 (#56 리뷰): 첫 실패 기준 시간이 공식 User RTO로 쓰이는 것을 막고,
  장애 주입 전 워밍업 구간의 일시 실패를 판정에서 제외한다

정의
  T0  = 장애 주입 실제 적용 시각 (--t0, 직접 기록한 값, 필수)
  첫 실패 = T0 이후 처음으로 step_ok=0 이 기록된 시각 (보조 지표)
  T3  = 로그인 → 조회 → 저장이 30초(--stable) 동안 연속 성공하기 시작한 시각 (#55)
  User RTO = T3 − T0
  장애 구간 = [T0, T3] (T3 미확정이면 [T0, 측정 끝]) — 발표용 실패 수·에러율·p95/p99는 이 구간 기준,
             전체 측정 구간 값은 참고용

실행 위치: 측정용 PC (Python 3.8+, 표준 라이브러리만)
  python3 scripts/k6_rto_summary_1007.py k6_1016-1000.csv --t0 "2026-10-16 10:00:00"
    --mode continuity 예: ... --t0 "2026-10-14 10:00:00" --mode continuity
  (k6 실행 시 K6_CSV_TIME_FORMAT=rfc3339_nano 권장 → 초 미만 정밀도)
"""
import argparse
import csv
import sys
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qsl

KST = timezone(timedelta(hours=9))
STEPS = ("login", "state", "save")


def parse_ts(raw):
    raw = raw.strip()
    try:
        return datetime.fromtimestamp(float(raw), tz=timezone.utc)
    except ValueError:
        pass
    # rfc3339(_nano): 2026-10-16T01:00:00.123456789Z / +09:00
    s = raw.replace("Z", "+00:00")
    if "." in s:
        head, rest = s.split(".", 1)
        frac = ""
        i = 0
        while i < len(rest) and rest[i].isdigit():
            frac += rest[i]
            i += 1
        s = f"{head}.{frac[:6].ljust(6, '0')}{rest[i:]}"
    return datetime.fromisoformat(s)


def parse_t0(raw):
    dt = datetime.fromisoformat(raw.strip().replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=KST)   # 시간대 없으면 KST


def fmt(dt):
    return dt.astimezone(KST).strftime("%H:%M:%S.%f")[:-3] if dt else "-"


def pct(values, p):
    if not values:
        return None
    v = sorted(values)
    k = (len(v) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def load(path):
    rows, durs, saves = [], {s: [] for s in STEPS}, []
    with open(path, newline="") as f:
        r = csv.DictReader(f)
        need = {"metric_name", "timestamp", "metric_value"}
        if not need.issubset(r.fieldnames or []):
            sys.exit(f"k6 CSV 형식이 아님 (필요한 열: {sorted(need)})")
        for row in r:
            name = row["metric_name"]
            tags = dict(parse_qsl(row.get("extra_tags") or ""))
            step = tags.get("step") or row.get("name") or ""
            ts = parse_ts(row["timestamp"])
            if name == "step_ok" and step in STEPS:
                rows.append((ts, step, float(row["metric_value"]) >= 1, tags.get("ip", ""), tags.get("code", "")))
            elif name == "http_req_duration" and step in STEPS:
                durs[step].append((ts, float(row["metric_value"])))
            elif name == "last_saved_completed":
                saves.append((ts, int(float(row["metric_value"]))))
    rows.sort(key=lambda x: x[0])
    saves.sort(key=lambda x: x[0])
    return rows, durs, saves


def find_t3(rows, start, stable):
    """start 이후, 실패 없이 stable초 이상 이어지고 그 안에 3개 step이 모두 성공한 구간의 시작"""
    cand, seen = None, set()
    for ts, step, ok, _ip, _code in rows:
        if ts < start:
            continue
        if not ok:
            cand, seen = None, set()
            continue
        if cand is None:
            cand = ts
        seen.add(step)
        if seen >= set(STEPS) and (ts - cand).total_seconds() >= stable:
            return cand
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("--t0", required=True,
                    help='장애 주입 실제 적용 시각 (필수), 예: "2026-10-16 10:00:00" (KST) 또는 ISO8601')
    ap.add_argument("--stable", type=float, default=30.0, help="복구 판정 연속 성공 시간(초), 기본 30 (#55 T3 정의)")
    ap.add_argument("--mode", choices=("rto", "continuity"), default="rto",
                    help="rto = T3·T6 User RTO (기본) / continuity = T1·T2·T5·T8 연속성 PASS/FAIL")
    ap.add_argument("--allow-fail", type=int, default=0,
                    help="continuity 모드 허용 실패 건수 (기본 0)")
    a = ap.parse_args()

    rows, durs, saves = load(a.csv)
    if not rows:
        sys.exit("step_ok 행이 없음 — k6_rto_1007.js로 측정한 CSV인지 확인")

    t0 = parse_t0(a.t0)
    if not (rows[0][0] <= t0 <= rows[-1][0]):
        sys.exit(f"T0 {fmt(t0)} 가 측정 구간({fmt(rows[0][0])} ~ {fmt(rows[-1][0])}) 밖 — 날짜·시간대(KST) 확인")
    fails = [r for r in rows if not r[2] and r[0] >= t0]
    first_fail = fails[0][0] if fails else None
    pre_fail = sum(1 for r in rows if not r[2] and r[0] < t0)

    def stats(lo, hi, title):
        win = [r for r in rows if lo <= r[0] <= hi]
        nf = sum(1 for r in win if not r[2])
        rate = f"{nf / len(win) * 100:.2f}%" if win else "-"
        print(f"{title}: {fmt(lo)} ~ {fmt(hi)}  step_ok {len(win)}건, 실패 {nf}건, 에러율 {rate}")
        for s in STEPS:
            n = sum(1 for r in win if r[1] == s)
            sf = sum(1 for r in win if r[1] == s and not r[2])
            d = [v for ts, v in durs[s] if lo <= ts <= hi]
            p95, p99 = pct(d, 95), pct(d, 99)
            p95s = f"{p95:.0f}ms" if p95 is not None else "-"
            p99s = f"{p99:.0f}ms" if p99 is not None else "-"
            print(f"  {s:<5} {n:>6}건  실패 {sf:>5}  p95 {p95s:>8}  p99 {p99s:>8}")

    stats(rows[0][0], rows[-1][0], "[참고] 전체 측정 구간")
    if pre_fail:
        print(f"  ※ T0 이전 실패 {pre_fail}건 (워밍업 등) — 판정에서 제외")

    ips = {}
    for ts, _s, ok, ip, _c in rows:
        if ok and ip:
            ips.setdefault(ip, [ts, ts])[1] = ts
    if ips:
        print("성공 응답 연결 IP (사이트 판별용):")
        for ip, (a1, a2) in sorted(ips.items(), key=lambda x: x[1][0]):
            print(f"  {ip:<16} {fmt(a1)} ~ {fmt(a2)}")

    print()
    print(f"T0 (장애 주입)      : {fmt(t0)}")
    print(f"첫 실패 [보조]      : {fmt(first_fail)}" + (f"  (T0 + {(first_fail - t0).total_seconds():.1f}초)" if first_fail else ""))
    n_login = sum(1 for r in rows if r[1] == "login")
    n_state = sum(1 for r in rows if r[1] == "state")
    if a.mode == "rto" and n_state and n_login < n_state * 0.5:
        print(f"⚠ login {n_login}건 / state {n_state}건 — LOGIN_MODE=session으로 측정한 CSV로 보임. "
              "T3·T6은 LOGIN_MODE=iter 측정 기준(#55·#56) — 결과 해석 주의")

    if a.mode == "continuity":
        verdict = "PASS" if len(fails) <= a.allow_fail else "FAIL"
        print(f"[연속성 T1·T2·T5·T8] {verdict} — T0 이후 사용자 실패 {len(fails)}건 (허용 {a.allow_fail}건)")
        if fails:
            print(f"  실패 구간: {fmt(fails[0][0])} ~ {fmt(fails[-1][0])}, 단계별 " +
                  ", ".join(f"{s} {sum(1 for r in fails if r[1] == s)}" for s in STEPS))
        stats(t0, rows[-1][0], "[발표] T0 이후 구간")
        return

    if not fails:
        print("[복구시간 T3·T6] T0 이후 사용자 실패 없음 → User RTO 0초 (사용자 영향 없음)")
        stats(t0, rows[-1][0], "[발표] T0 이후 구간")
        return
    # 마지막 실패 이후 안정 구간 기준 (중간에 잠깐 회복했다 다시 실패한 경우는 복구로 보지 않음)
    last_fail = fails[-1][0]
    t3 = find_t3(rows, last_fail, a.stable)
    if t3 is None:
        print(f"T3 (안정 복구)      : 미확정 — 마지막 실패 {fmt(last_fail)} 이후 {a.stable:.0f}초 연속 성공 구간 없음")
    else:
        print(f"T3 (안정 복구)      : {fmt(t3)}  (3개 요청 {a.stable:.0f}초 연속 성공 시작)")
        print(f"User RTO           : {(t3 - t0).total_seconds():.1f}초  (T3 − T0)")
    stats(t0, t3 or rows[-1][0], "[발표] 장애·복구 구간 T0→T3" if t3 else "[발표] 장애 구간 T0→측정 끝 (T3 미확정)")

    before = [s for s in saves if s[0] < first_fail]          # 첫 실패 직전까지 성공한 마지막 쓰기
    after = [s for s in saves if t3 and s[0] >= t3]            # 안정 복구 이후 첫 쓰기
    print(f"마지막 저장 (장애 전): {fmt(before[-1][0]) + ' completed=' + str(bool(before[-1][1])) if before else '-'}")
    print(f"첫 저장 (복구 후)    : {fmt(after[0][0]) + ' completed=' + str(bool(after[0][1])) if after else '-'}")
    print("※ RPO는 DR DB에서 장애 직전 저장 값이 조회되는지로 별도 확인 (정현)")


if __name__ == "__main__":
    main()
