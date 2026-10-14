#!/usr/bin/env bash
# Run on Monitoring VM: sudo bash /tmp/blackbox-cloud/install.sh
set -euo pipefail
test "$(id -u)" = 0 || { echo "Run with sudo bash"; exit 1; }
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BB=/etc/blackbox_exporter/blackbox.yml
PROM=/etc/prometheus/prometheus.yml
RULE=/etc/prometheus/rules/blackbox-cloud-alerts.yml
test -f "$BB"
test -f "$PROM"
test -f /etc/prometheus/rules/blackbox-alerts.yml
test ! -e "$RULE" || { echo "Cloud rules already exist; stop to avoid overwrite."; exit 1; }
for name in blackbox-module.yml prometheus-job.yml blackbox-cloud-alerts.yml; do
  test -f "$BASE/$name"
done
grep -q 'http_2xx_neuroplan_cloud:' "$BB" && { echo "Module already exists; stop."; exit 1; }
grep -q 'job_name: blackbox-neuroplan-cloud' "$PROM" && { echo "Job already exists; stop."; exit 1; }
grep -q '^  - /etc/prometheus/rules/\*.yml$' "$PROM" || { echo "Unexpected rule_files pattern; stop."; exit 1; }
podman exec prometheus /bin/promtool check config "$PROM"
install -d -m 700 /var/backups/neuroplan-monitoring
BACKUP="$(mktemp -d /var/backups/neuroplan-monitoring/cloud-blackbox.XXXXXX)"
cp -a "$BB" "$BACKUP/blackbox.yml"
cp -a "$PROM" "$BACKUP/prometheus.yml"
printf 'BACKUP_DIR=%s\n' "$BACKUP"
BB_STAGE="$(mktemp /etc/blackbox_exporter/cloud-candidate.XXXXXX)"
PROM_STAGE="$(mktemp /etc/prometheus/cloud-candidate.XXXXXX)"
RULE_STAGE="$(mktemp /etc/prometheus/cloud-rules-candidate.XXXXXX)"
CHANGED=0
finish() {
  code=$?
  trap - EXIT
  if test "$code" != 0 && test "$CHANGED" = 1; then
    echo "Failure after install: restoring original config; backup retained."
    cp -a "$BACKUP/blackbox.yml" "$BB"
    cp -a "$BACKUP/prometheus.yml" "$PROM"
    rm -f -- "$RULE"
    podman kill --signal HUP blackbox-exporter >/dev/null || true
    podman kill --signal HUP prometheus >/dev/null || true
    echo "ROLLBACK_ATTEMPTED: verify logs and old targets."
  fi
  rm -f -- "$BB_STAGE" "$PROM_STAGE" "$RULE_STAGE"
  exit "$code"
}
trap finish EXIT
python3 - "$BB" "$PROM" "$BASE" "$BB_STAGE" "$PROM_STAGE" <<'PY'
import pathlib,re,sys
bb,prom,base,bb_stage,prom_stage=map(pathlib.Path,sys.argv[1:])
for src,fragment,target,last_key in [
    (bb,base/"blackbox-module.yml",bb_stage,"modules"),
    (prom,base/"prometheus-job.yml",prom_stage,"scrape_configs"),
]:
    text=src.read_text()
    keys=re.findall(r"^([A-Za-z_][A-Za-z_0-9]*):",text,re.M)
    if not keys or keys[-1]!=last_key:
        raise SystemExit("STOP: unexpected trailing top-level section: "+str(src))
    target.write_text(text.rstrip()+"\n\n"+fragment.read_text(),encoding="utf-8")
PY
cp "$BASE/blackbox-cloud-alerts.yml" "$RULE_STAGE"
chmod 644 "$BB_STAGE" "$PROM_STAGE" "$RULE_STAGE"
chcon --reference="$BB" "$BB_STAGE"
chcon --reference="$PROM" "$PROM_STAGE"
chcon --reference=/etc/prometheus/rules/blackbox-alerts.yml "$RULE_STAGE"
# Unsupported config.check or validation errors stop BEFORE live files change.
podman exec blackbox-exporter /bin/blackbox_exporter --config.file="$BB_STAGE" --config.check
podman exec prometheus /bin/promtool check rules "$RULE_STAGE"
podman exec prometheus /bin/promtool check config "$PROM_STAGE"
# Preserve original owner, mode and SELinux/MCS labels.
chown --reference="$BB" "$BB_STAGE"
chmod --reference="$BB" "$BB_STAGE"
chown --reference="$PROM" "$PROM_STAGE"
chmod --reference="$PROM" "$PROM_STAGE"
CHANGED=1
cp --preserve=all "$BB_STAGE" "$BB"
cp --preserve=all "$PROM_STAGE" "$PROM"
install -o root -g root -m 644 "$RULE_STAGE" "$RULE"
chcon --reference=/etc/prometheus/rules/blackbox-alerts.yml "$RULE"
podman exec prometheus /bin/promtool check config "$PROM"
RELOAD_STARTED="$(date +%s)"
podman kill --signal HUP blackbox-exporter >/dev/null
podman kill --signal HUP prometheus >/dev/null
if python3 - "$RELOAD_STARTED" <<'PY'
import json,sys,time,urllib.request
def reload_state():
    # Read exporter metrics directly, not TSDB samples awaiting the next self-scrape.
    with urllib.request.urlopen("http://127.0.0.1:9090/metrics",timeout=5) as r:
        text=r.read().decode()
    values={}
    for line in text.splitlines():
        fields=line.split()
        if len(fields)==2 and fields[0] in (
            "prometheus_config_last_reload_successful",
            "prometheus_config_last_reload_success_timestamp_seconds",
        ):
            values[fields[0]]=float(fields[1])
    return values
start=int(sys.argv[1])
last={}
for attempt in range(10):
    last=reload_state()
    if (last.get("prometheus_config_last_reload_successful")==1 and
            last.get("prometheus_config_last_reload_success_timestamp_seconds",-1)>=start):
        with urllib.request.urlopen("http://127.0.0.1:9090/api/v1/status/config",timeout=5) as r:
            data=json.load(r)
        if data.get("status")=="success" and "job_name: blackbox-neuroplan-cloud" in data.get("data",{}).get("yaml",""):
            print("PROMETHEUS_RELOAD=OK (direct metrics + active cloud job)")
            break
    time.sleep(1)
else:
    print("RELOAD_STATE="+str(last))
    raise SystemExit("Prometheus did not confirm successful new reload/active cloud job")
PY
then
  :
else
  podman logs --since 2m --tail 30 prometheus >&2 || true
  exit 1
fi
echo "Waiting 35 seconds for the first scrape..."
sleep 35
python3 - <<'PY'
import json,urllib.parse,urllib.request
def get(path,params=None):
    url="http://127.0.0.1:9090"+path
    if params: url+="?"+urllib.parse.urlencode(params)
    with urllib.request.urlopen(url,timeout=10) as r: return json.load(r)
data=get("/api/v1/query",{"query":'probe_success{job=~"blackbox-neuroplan|blackbox-neuroplan-cloud"}'})
rows=data.get("data",{}).get("result",[])
for row in rows:
    m=row["metric"]
    print("job=%s target=%s success=%s"%(m.get("job"),m.get("instance"),row["value"][1]))
new=[r for r in rows if r["metric"].get("job")=="blackbox-neuroplan-cloud"]
print("CLOUD_TARGET_COUNT=%s EXPECTED=3"%len(new))
if len(new)!=3 or any(r["value"][1]!="1" for r in new):
    print("PROBE_VERIFY=NEEDS_CHECK (config is kept; endpoint failure is not silently hidden)")
else: print("PROBE_VERIFY=PASS")
am=get("/api/v1/alertmanagers").get("data",{})
print("ACTIVE_ALERTMANAGER_COUNT=%s"%len(am.get("activeAlertmanagers",[])))
print("This is not proof of email delivery. SMTP/routing and firing/resolved tests remain.")
PY
CHANGED=0
echo "CONFIG_INSTALL=OK (review PROBE_VERIFY separately)"
