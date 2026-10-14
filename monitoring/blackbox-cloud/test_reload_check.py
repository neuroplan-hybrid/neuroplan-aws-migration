"""Offline tests of install.sh reload gate; no VM/network changes."""
import contextlib
import io
import json
import pathlib
import re
import sys
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).with_name("install.sh").read_text(encoding="utf-8")
BLOCKS = re.findall(r"<<'PY'\n(.*?)\nPY", SCRIPT, re.S)
RELOAD_CODE = compile(BLOCKS[1], "reload-check", "exec")

class ReloadCheckTests(unittest.TestCase):
    def run_case(self, success, timestamp, job_present=True):
        def response(url, timeout=5):
            if url.endswith("/metrics"):
                return io.BytesIO((
                    "prometheus_config_last_reload_successful %s\n"
                    "prometheus_config_last_reload_success_timestamp_seconds %s\n"
                    % (success, timestamp)
                ).encode())
            if url.endswith("/api/v1/status/config"):
                text = "job_name: blackbox-neuroplan-cloud" if job_present else "job_name: prometheus"
                return io.BytesIO(json.dumps({"status":"success", "data":{"yaml":text}}).encode())
            raise AssertionError("Must not query delayed TSDB self-metrics: "+url)
        with patch("urllib.request.urlopen", side_effect=response), patch("time.sleep"), patch.object(sys, "argv", ["check","100"]), contextlib.redirect_stdout(io.StringIO()):
            exec(RELOAD_CODE, {"__name__":"__main__"})
    def test_direct_live_success(self):
        self.run_case(1,101)
    def test_old_success_is_rejected(self):
        with self.assertRaises(SystemExit): self.run_case(1,99)
    def test_reload_failure_is_rejected(self):
        with self.assertRaises(SystemExit): self.run_case(0,101)
    def test_cloud_job_missing_is_rejected(self):
        with self.assertRaises(SystemExit): self.run_case(1,101,False)

if __name__ == "__main__":
    unittest.main()
