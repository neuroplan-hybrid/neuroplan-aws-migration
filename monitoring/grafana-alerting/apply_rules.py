#!/usr/bin/env python3
"""Run with sudo on Monitoring VM. No SMTP, policy, datasource or DB mutation."""
import argparse,base64,copy,getpass,json,math,os,pathlib,sqlite3,subprocess,tempfile,time
import urllib.request,urllib.error
BASE=pathlib.Path(__file__).resolve().parent
DIR=pathlib.Path("/etc/grafana/provisioning/alerting")
GRAFANA="http://192.168.14.73:3000"
REFERENCE=pathlib.Path("/etc/grafana/provisioning/datasources/prometheus.yaml")
OPERATING_UIDS={"np_rosa_scrape_failed","np_rosa_ready_short","np_rosa_http_5xx_high"}
TEST_UID="np_notification_test"

def api(path,method="GET",body=None):
    raw=None if body is None else json.dumps(body).encode()
    req=urllib.request.Request(GRAFANA+path,data=raw,method=method,
        headers={"Authorization":AUTH,"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req,timeout=45) as r:
            payload=r.read()
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as e:
        # Never echo arbitrary response bodies or credentials.
        raise RuntimeError("Grafana API %s returned HTTP %s"%(path,e.code)) from None

def validate(config,allowed,query_check=True):
    def numbers_from(data):
        numbers=[]
        for frame in data.get("frames",[]):
            fields=frame.get("schema",{}).get("fields",[])
            values=frame.get("data",{}).get("values",[])
            for i,field in enumerate(fields):
                if field.get("type")=="number" and i<len(values):
                    numbers.extend(v for v in values[i] if isinstance(v,(int,float)) and math.isfinite(v))
        return numbers
    if set(config)!={"apiVersion","groups"} or config["apiVersion"]!=1:
        raise RuntimeError("Only rule groups can be imported")
    uids=set()
    for group in config["groups"]:
        if group["orgId"]!=1: raise RuntimeError("Only expected org 1 is supported")
        for rule in group["rules"]:
            uid=rule["uid"]
            if uid in uids or uid not in allowed: raise RuntimeError("Unexpected/duplicate rule UID")
            uids.add(uid)
            if rule["data"][0]["datasourceUid"]!="ag16e60k8yzggd": raise RuntimeError("Unexpected datasource")
            for query in rule["data"]:
                model=query["model"]
                mode=model.get("settings",{}).get("mode")
                if model.get("type")=="reduce" and mode not in (None,"","dropNN","replaceNN"):
                    raise RuntimeError("Unsupported serialized reducer mode for "+uid)
            if not query_check:
                continue
            model=copy.deepcopy(rule["data"][0]["model"])
            result=api("/api/ds/query","POST",{"from":"now-10m","to":"now","queries":[model]})
            data=result.get("results",{}).get("A",{})
            if data.get("error"): raise RuntimeError("Query failed for "+uid)
            numbers=numbers_from(data)
            if not numbers: raise RuntimeError("No finite query values for "+uid+"; nothing installed")
            print("QUERY_CHECK=%s PASS"%uid)
            pipeline=api("/api/ds/query","POST",{
                "from":"now-10m","to":"now",
                "queries":[copy.deepcopy(q["model"]) for q in rule["data"]],
            })
            results=pipeline.get("results",{})
            if any(value.get("error") for value in results.values()):
                raise RuntimeError("Expression evaluation failed for "+uid+"; nothing installed")
            if not numbers_from(results.get(rule["condition"],{})):
                raise RuntimeError("Condition expression returned no finite values for "+uid)
            print("EXPRESSION_CHECK=%s PASS"%uid)
    if uids!=allowed: raise RuntimeError("Unexpected rule set")
    return uids

def install_blob(path,obj):
    fd,tmp=tempfile.mkstemp(prefix=".neuroplan-",dir=str(DIR))
    try:
        with os.fdopen(fd,"w") as f: json.dump(obj,f,ensure_ascii=False,indent=2)
        os.chmod(tmp,0o644)
        subprocess.run(["chcon","--reference="+str(REFERENCE),tmp],check=True)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def ensure_provisioning_directory(path,reference):
    path.mkdir(mode=0o755,exist_ok=True)
    # Restore traversal permission masked by the root-private backup umask.
    path.chmod(0o755)
    subprocess.run(["chcon","--reference="+str(reference.parent),str(path)],check=True)

parser=argparse.ArgumentParser()
parser.add_argument("action",choices=["install","pause","test-fire","test-retry","test-resolve","remove-test"])
args=parser.parse_args()
if os.geteuid()!=0: raise SystemExit("Use sudo python3")
os.umask(0o077)
username=input("Grafana server-admin username [admin]: ").strip() or "admin"
password=getpass.getpass("Grafana password (not printed/stored): ")
AUTH="Basic "+base64.b64encode((username+":"+password).encode()).decode()
del password
user=api("/api/user")
if not user.get("isGrafanaAdmin") or user.get("orgId")!=1:
    raise SystemExit("A Grafana server-admin in org 1 is required")
sources=api("/api/datasources")
if not any(d.get("uid")=="ag16e60k8yzggd" and d.get("type")=="prometheus" for d in sources):
    raise SystemExit("Expected ROSA Thanos datasource missing")
if not any(d.get("type")=="alertmanager" and d.get("jsonData",{}).get("handleGrafanaManagedAlerts") for d in sources):
    raise SystemExit("Alertmanager Receive Grafana Alerts setting is missing")
existing=api("/api/v1/provisioning/alert-rules")
is_operating=args.action in ("install","pause")
name="neuroplan-rosa-alerts.json" if is_operating else "neuroplan-mail-test.json"
target=DIR/name
allowed=OPERATING_UIDS if is_operating else {TEST_UID}
collision=[r["uid"] for r in existing if r.get("uid") in allowed]
if collision and not target.exists():
    raise SystemExit("Rule UID exists outside our provisioning file; stop")
if args.action=="pause" and not target.exists():
    raise SystemExit("No owned operating rule file exists")
if args.action=="test-fire" and target.exists() and collision:
    raise SystemExit("Test rule already imported. Resolve/remove it before starting another.")
if args.action in ("test-retry","test-resolve","remove-test") and not target.exists():
    raise SystemExit("No managed test file exists")
if args.action=="test-retry":
    old=json.loads(target.read_text(encoding="utf-8"))
    old_uids={r["uid"] for g in old.get("groups",[]) for r in g.get("rules",[])}
    if set(old)!={"apiVersion","groups"} or old_uids!={TEST_UID}:
        raise SystemExit("Existing file is not our isolated test; stop")
if args.action=="remove-test":
    config={"apiVersion":1,"deleteRules":[{"orgId":1,"uid":TEST_UID}]}
else:
    config=json.loads((target if args.action=="pause" else BASE/name).read_text(encoding="utf-8"))
    if args.action=="pause":
        for group in config["groups"]:
            for rule in group["rules"]:
                rule["isPaused"]=True
    if args.action=="test-resolve":
        config["groups"][0]["rules"][0]["data"][0]["model"]["expr"]="vector(0)"
    validate(config,allowed,query_check=args.action!="pause")
    if args.action=="test-fire" and target.exists():
        if json.loads(target.read_text(encoding="utf-8"))!=config:
            raise SystemExit("Unimported test file differs from expected content; stop")
        print("RESUMING_UNIMPORTED_TEST_FILE=OK")
if not REFERENCE.is_file(): raise SystemExit("Missing known Grafana SELinux reference file")
backup_root=pathlib.Path("/var/backups/neuroplan-grafana")
backup_root.mkdir(mode=0o700,parents=True,exist_ok=True)
backup=pathlib.Path(tempfile.mkdtemp(prefix="before-rosa-alerts-",dir=str(backup_root)))
db=sqlite3.connect("file:/var/lib/grafana/grafana.db?mode=ro",uri=True)
out=sqlite3.connect(str(backup/"grafana.db"))
db.backup(out)
if out.execute("PRAGMA integrity_check").fetchone()[0]!="ok": raise RuntimeError("DB backup check failed")
out.close();db.close()
previous=target.read_bytes() if target.exists() else None
if previous is not None: (backup/name).write_bytes(previous)
print("BACKUP_DIR="+str(backup))
# umask 077 protects backups but also masks mkdir(0755) to 0700.
# This directory contains our readable provisioning config, not credentials.
ensure_provisioning_directory(DIR,REFERENCE)
install_blob(target,config)
try:
    api("/api/admin/provisioning/alerting/reload","POST",{})
    imported=api("/api/v1/provisioning/alert-rules")
    seen={r.get("uid") for r in imported}
    if args.action=="remove-test":
        if TEST_UID in seen:
            raise RuntimeError("Test UID still exists after reload")
    elif not allowed.issubset(seen):
        raise RuntimeError("Expected rules missing after import; check Grafana provisioning logs")
except Exception:
    if previous is not None:
        install_blob(target,json.loads(previous))
    else:
        # Best-effort removal of only our newly introduced UIDs after partial import.
        install_blob(target,{"apiVersion":1,"deleteRules":[{"orgId":1,"uid":u} for u in sorted(allowed)]})
    try:
        api("/api/admin/provisioning/alerting/reload","POST",{})
        if previous is None: target.unlink()
        print("OUR_PROVISIONING_ROLLBACK=OK")
    except Exception:
        print("ROLLBACK_NEEDS_MANUAL_CHECK; backup retained. Do not restore a live SQLite DB automatically.")
    raise
if args.action=="remove-test":
    target.unlink()
    remaining=api("/api/v1/provisioning/alert-rules")
    if any(r.get("uid")==TEST_UID for r in remaining): raise RuntimeError("Test UID still exists")
    print("TEST_RULE_REMOVED=OK (operating rules preserved)")
else:
    print("RULE_IMPORT=OK action="+args.action)
    print("Grafana Alerting > Alert rules: check evaluation state and errors.")
    if args.action in ("test-fire","test-retry"):
        print("Intentional TEST alert only. Wait roughly 1-2 minutes for evaluation/routing/email.")
    elif args.action=="test-resolve":
        print("Test now returns 0; wait for Normal/Resolved. Resolved email requires send_resolved=true in the existing receiver.")
    elif args.action=="pause":
        print("ROSA_OPERATING_RULES_PAUSED=OK (existing Prometheus/Blackbox rules unchanged)")
    else:
        print("Operating rules active. Real conditions, datasource NoData/errors may notify.")
print("No SMTP/receiver/notification-policy/datasource settings were changed; no service restart.")
