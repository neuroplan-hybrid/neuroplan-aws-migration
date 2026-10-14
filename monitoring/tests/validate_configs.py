"""Offline structural checks; never contacts Grafana, AWS or the VM."""
import ast,json,pathlib
import yaml
ROOT=pathlib.Path(__file__).resolve().parents[1]
dashboard=json.loads((ROOT/"cloudwatch-check/neuroplan-cloud-check-provisioned.json").read_text(encoding="utf-8"))
panels=dashboard["panels"]
assert len(panels)==39 and len({p["id"] for p in panels})==39
assert dashboard["uid"]=="neuroplan-aws-check-v1" and dashboard["refresh"]==""
for i,a in enumerate(panels):
    x=a["gridPos"]
    assert 0<=x["x"] and x["x"]+x["w"]<=24
    for b in panels[i+1:]:
        y=b["gridPos"]
        assert not (x["x"]<y["x"]+y["w"] and y["x"]<x["x"]+x["w"] and x["y"]<y["y"]+y["h"] and y["y"]<x["y"]+x["h"])
for p in panels:
    for target in p.get("targets",[]):
        if target.get("namespace")=="AWS/VPN":
            assert set(target["dimensions"])=={"TunnelIpAddress"}
assert {p["id"] for p in panels if p["id"]>=36}=={36,37,38,39}
module=yaml.safe_load("modules:\n"+(ROOT/"blackbox-cloud/blackbox-module.yml").read_text(encoding="utf-8"))
http=module["modules"]["http_2xx_neuroplan_cloud"]["http"]
assert http["tls_config"]["insecure_skip_verify"] is False
assert "headers" not in http and "server_name" not in http["tls_config"]
job=yaml.safe_load("scrape_configs:\n"+(ROOT/"blackbox-cloud/prometheus-job.yml").read_text(encoding="utf-8"))["scrape_configs"][0]
assert job["job_name"]=="blackbox-neuroplan-cloud"
assert sum(len(c["targets"]) for c in job["static_configs"])==3
rules=yaml.safe_load((ROOT/"blackbox-cloud/blackbox-cloud-alerts.yml").read_text(encoding="utf-8"))
assert len(rules["groups"][0]["rules"])==4
for path in ROOT.rglob("*.py"):
    ast.parse(path.read_text(encoding="utf-8"),filename=str(path))
for name in ("neuroplan-rosa-alerts.json","neuroplan-mail-test.json"):
    config=json.loads((ROOT/"grafana-alerting"/name).read_text(encoding="utf-8"))
    assert set(config)=={"apiVersion","groups"}
    for group in config["groups"]:
        for rule in group["rules"]:
            assert rule["noDataState"]=="NoData" and rule["execErrState"]=="Error"
            assert "settings" not in rule["data"][1]["model"]
print("PASS: dashboard layout / VPN dimensions / strict TLS / 3 probes / 4 Blackbox rules / Python syntax / isolated Grafana rule files")
