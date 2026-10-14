#!/usr/bin/env python3
"""Read-only metadata checks; never prints SMTP passwords, tokens or full config."""
import json
import pathlib
import re
import sqlite3
import urllib.request

con=sqlite3.connect("file:/var/lib/grafana/grafana.db?mode=ro",uri=True)
print("=== Grafana datasource metadata ===")
for name,uid,kind,raw in con.execute(
    "SELECT name,uid,type,json_data FROM data_source WHERE type IN ('prometheus','alertmanager')"
):
    settings=json.loads(raw or "{}")
    print("name=%s uid=%s type=%s handleGrafanaManagedAlerts=%s"%
          (name,uid,kind,settings.get("handleGrafanaManagedAlerts","unset")))
exists=con.execute("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='alert_rule'").fetchone()[0]
print("GRAFANA_MANAGED_RULE_COUNT=%s"%(con.execute("SELECT count(*) FROM alert_rule").fetchone()[0] if exists else "table absent"))
con.close()

def api(url):
    with urllib.request.urlopen(url,timeout=10) as r:
        return json.load(r)
print("=== Active Prometheus Blackbox rules ===")
try:
    data=api("http://127.0.0.1:9090/api/v1/rules?type=alert")
    for group in data.get("data",{}).get("groups",[]):
        if group.get("name")=="neuroplan.cloud.blackbox":
            for rule in group.get("rules",[]):
                print("name=%s health=%s state=%s"%(rule.get("name"),rule.get("health"),rule.get("state")))
except Exception as e:
    print("RULE_API_CHECK_FAILED=%s"%type(e).__name__)
print("=== On-Prem Alertmanager metadata ===")
try:
    data=api("http://127.0.0.1:9093/api/v2/status")
    config=data.get("config",{}).get("original","")
    print("ALERTMANAGER_API=OK")
    smart=re.search(r"^\s*smtp_smarthost:\s*(.*?)\s*$",config,re.M)
    value=smart.group(1).strip("'\"") if smart else ""
    print("GLOBAL_SMTP_SMARTHOST_CONFIGURED=%s"%bool(value))
    print("EMAIL_RECEIVER_BLOCKS=%s"%len(re.findall(r"^\s*email_configs:\s*$",config,re.M)))
    for line in config.splitlines():
        if re.match(r"^\s*(receiver|name|group_by|group_wait|group_interval|repeat_interval|send_resolved|matchers|severity):",line):
            print(line.strip())
    print("Receiver presence is not proof of SMTP connectivity or email delivery.")
except Exception as e:
    print("ALERTMANAGER_API_CHECK_FAILED=%s"%type(e).__name__)
