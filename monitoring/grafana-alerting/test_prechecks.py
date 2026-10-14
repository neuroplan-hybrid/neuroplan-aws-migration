import ast,copy,json,math,pathlib,unittest
from unittest.mock import Mock
ROOT=pathlib.Path(__file__).resolve().parent
cfg=json.loads((ROOT/"neuroplan-rosa-alerts.json").read_text(encoding="utf-8"))
tree=ast.parse((ROOT/"apply_rules.py").read_text(encoding="utf-8"))
node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=="validate")
class PrecheckTests(unittest.TestCase):
    def run_check(self,response,config=None,pipeline=None):
        def mock_api(path,method,body):
            if len(body["queries"])==1:
                return response
            if pipeline is not None:
                return pipeline
            data=response.get("results",{}).get("A",{})
            return {"results":{"A":data,"B":data,"C":data}}
        scope={"copy":copy,"math":math,"api":mock_api}
        exec(compile(ast.Module(body=[node],type_ignores=[]),"validate","exec"),scope)
        c=copy.deepcopy(config or cfg)
        return scope["validate"](c,{r["uid"] for r in cfg["groups"][0]["rules"]})
    def test_numeric_values(self):
        self.assertEqual(len(self.run_check({"results":{"A":{"frames":[{"schema":{"fields":[{"type":"number"}]},"data":{"values":[[0.0]]}}]}}})),3)
    def test_empty_data_rejected(self):
        with self.assertRaises(RuntimeError):self.run_check({"results":{"A":{"frames":[]}}})
    def test_query_error_rejected(self):
        with self.assertRaises(RuntimeError):self.run_check({"results":{"A":{"error":"mock failure"}}})
    def test_nan_rejected(self):
        with self.assertRaises(RuntimeError):self.run_check({"results":{"A":{"frames":[{"schema":{"fields":[{"type":"number"}]},"data":{"values":[[float("nan")]]}}]}}})
    def test_contact_point_change_rejected(self):
        c=copy.deepcopy(cfg);c["contactPoints"]=[]
        with self.assertRaises(RuntimeError):self.run_check({},c)
    def test_unknown_uid_rejected(self):
        c=copy.deepcopy(cfg);c["groups"][0]["rules"][0]["uid"]="some_other_rule"
        with self.assertRaises(RuntimeError):self.run_check({},c)
    def test_thresholds_and_ownership(self):
        rules=cfg["groups"][0]["rules"]
        self.assertEqual(len(rules),3)
        self.assertEqual([r["for"] for r in rules],["1m","2m","5m"])
        self.assertEqual(rules[2]["data"][2]["model"]["conditions"][0]["evaluator"]["params"],[5])
    def test_test_rule_is_isolated(self):
        t=json.loads((ROOT/"neuroplan-mail-test.json").read_text(encoding="utf-8"))["groups"][0]["rules"][0]
        self.assertEqual(t["uid"],"np_notification_test")
        self.assertEqual(t["data"][0]["model"]["expr"],"vector(1)")
        self.assertEqual(t["labels"]["purpose"],"notification-test")
    def test_directory_permissions_explicitly_restored(self):
        function=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=="ensure_provisioning_directory")
        runner=Mock()
        scope={"subprocess":runner}
        exec(compile(ast.Module(body=[function],type_ignores=[]),"directory","exec"),scope)
        directory=Mock()
        reference=pathlib.Path("/etc/grafana/provisioning/datasources/prometheus.yaml")
        scope["ensure_provisioning_directory"](directory,reference)
        directory.mkdir.assert_called_once_with(mode=0o755,exist_ok=True)
        directory.chmod.assert_called_once_with(0o755)
        runner.run.assert_called_once()
    def test_import_verification_is_inside_rollback_guard(self):
        guard=next(n for n in tree.body if isinstance(n,ast.Try) and any(
            isinstance(c,ast.Constant) and c.value=="/api/admin/provisioning/alerting/reload"
            for item in n.body for c in ast.walk(item)))
        self.assertIn("Expected rules missing after import",ast.unparse(guard))
    def test_serialized_strict_mode_rejected(self):
        c=copy.deepcopy(cfg)
        c["groups"][0]["rules"][0]["data"][1]["model"]["settings"]={"mode":"strict"}
        with self.assertRaises(RuntimeError):self.run_check({},c)
    def test_expression_error_rejected_before_import(self):
        value={"results":{"A":{"frames":[{"schema":{"fields":[{"type":"number"}]},"data":{"values":[[1.0]]}}]}}}
        with self.assertRaises(RuntimeError):
            self.run_check(value,pipeline={"results":{"C":{"error":"mock expression failure"}}})
    def test_missing_condition_rejected(self):
        value={"results":{"A":{"frames":[{"schema":{"fields":[{"type":"number"}]},"data":{"values":[[1.0]]}}]}}}
        with self.assertRaises(RuntimeError):self.run_check(value,pipeline={"results":{}})
    def test_all_files_use_default_strict_serialization(self):
        configs=[cfg,json.loads((ROOT/"neuroplan-mail-test.json").read_text(encoding="utf-8"))]
        for config in configs:
            for group in config["groups"]:
                for rule in group["rules"]:
                    self.assertNotIn("settings",rule["data"][1]["model"])
    def test_pause_validation_does_not_require_live_rosa(self):
        failing_api=Mock(side_effect=RuntimeError("ROSA unavailable"))
        scope={"copy":copy,"math":math,"api":failing_api}
        exec(compile(ast.Module(body=[node],type_ignores=[]),"validate","exec"),scope)
        self.assertEqual(len(scope["validate"](copy.deepcopy(cfg),{
            r["uid"] for r in cfg["groups"][0]["rules"]},query_check=False)),3)
        failing_api.assert_not_called()
if __name__=="__main__":unittest.main()
