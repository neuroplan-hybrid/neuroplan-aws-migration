"""Regression tests for the actual RDS role status predicates (no DB connection)."""
from pathlib import Path
from types import SimpleNamespace
import re
import unittest

import yaml
from jinja2 import Environment, StrictUndefined

TASK_DIR = Path(__file__).resolve().parents[1] / "roles" / "rds_operation" / "tasks"
ENDPOINT = "sample.abc.ap-northeast-2.rds.amazonaws.com"
ENV = Environment(undefined=StrictUndefined)
# Ansible's search test delegates to Python re.search.
ENV.tests["search"] = lambda value, pattern: re.search(pattern, value) is not None
ENV.filters["regex_escape"] = re.escape
ENV.filters["bool"] = bool


def tasks(filename):
    return yaml.safe_load((TASK_DIR / filename).read_text(encoding="utf-8"))


def context(stdout):
    result = SimpleNamespace(stdout=stdout)
    return {
        "rds_operation_endpoint": ENDPOINT,
        "rds_operation_port": 3306,
        "rds_operation_inbound_status": result,
        "rds_operation_cutover_status": result,
        "rds_operation_onprem_replica_status": result,
        "rds_operation_existing_slave_status": result,
        "rds_operation_allow_reset_replica": False,
    }


def source_patterns(filename, values):
    task = next(t for t in tasks(filename) if t["name"].startswith("Build exact expected"))
    for name, expression in task["ansible.builtin.set_fact"].items():
        values[name] = ENV.from_string(expression).render(**values).strip()
    return values


def assertion_passes(filename, task_name, stdout):
    values = context(stdout)
    if filename == "verify-onprem-replica.yml":
        source_patterns(filename, values)
    task = next(t for t in tasks(filename) if t["name"] == task_name)
    return all(ENV.compile_expression(expr)(**values) for expr in task["ansible.builtin.assert"]["that"])


def status(indent="    ", newline="\n", **overrides):
    fields = {
        "Master_Host": ENDPOINT,
        "Master_Port": "3306",
        "Slave_IO_Running": "Yes",
        "Slave_SQL_Running": "Yes",
        "Seconds_Behind_Master": "0",
        "Using_Gtid": "Slave_Pos",
        "Last_IO_Error": "",
        "Last_SQL_Error": "",
    }
    fields.update(overrides)
    return newline.join(
        f"{indent}{name}: {value}" for name, value in fields.items() if value is not None
    ) + newline


class InboundAndCutoverTests(unittest.TestCase):
    checks = (
        ("verify-rds-inbound.yml", "Require healthy RDS inbound replication"),
        ("finish-rds-cutover.yml", "Require zero replication lag at cutover"),
    )

    def test_healthy_spaces_tabs_and_crlf(self):
        for filename, task in self.checks:
            for indent, newline in (("", "\n"), ("    ", "\n"), ("\t", "\r\n")):
                with self.subTest(filename=filename, indent=indent, newline=newline):
                    self.assertTrue(assertion_passes(filename, task, status(indent, newline)))

    def test_reject_unhealthy_incomplete_and_prefix_values(self):
        cases = (
            {"Slave_IO_Running": "No"},
            {"Slave_IO_Running": "Connecting"},
            {"Slave_SQL_Running": "No"},
            {"Seconds_Behind_Master": "12"},
            {"Seconds_Behind_Master": "01"},
            {"Seconds_Behind_Master": "NULL"},
            {"Slave_IO_Running": "YesButNotHealthy"},
            {"Slave_SQL_Running": None},
        )
        for filename, task in self.checks:
            for values in cases:
                with self.subTest(filename=filename, values=values):
                    self.assertFalse(assertion_passes(filename, task, status(**values)))


class OnPremReplicaTests(unittest.TestCase):
    filename = "verify-onprem-replica.yml"
    task = "Require healthy RDS to On-Prem replication"

    def test_healthy_and_empty_error_fields(self):
        for indent, newline in (("", "\n"), ("    ", "\n"), ("\t", "\r\n")):
            with self.subTest(indent=indent, newline=newline):
                self.assertTrue(assertion_passes(self.filename, self.task, status(indent, newline)))

    def test_reject_io_sql_gtid_and_replication_errors(self):
        cases = (
            {"Slave_IO_Running": "No"},
            {"Slave_SQL_Running": "No"},
            {"Using_Gtid": "No"},
            {"Last_IO_Error": "error connecting to master"},
            {"Last_SQL_Error": "Duplicate entry"},
            {"Last_IO_Error": "   connection failed"},
            {"Last_SQL_Error": "X"},
        )
        for values in cases:
            with self.subTest(values=values):
                self.assertFalse(assertion_passes(self.filename, self.task, status(**values)))

    def test_exact_source_with_indentation(self):
        for filename in ("configure-onprem-replica.yml", self.filename):
            values = source_patterns(filename, context(status()))
            host = values["rds_operation_master_host_pattern"]
            port = values["rds_operation_master_port_pattern"]
            for indent, newline in (("", "\n"), ("    ", "\n"), ("\t", "\r\n")):
                with self.subTest(filename=filename, indent=indent):
                    self.assertRegex(status(indent, newline), host)
                    self.assertRegex(status(indent, newline), port)
            for overrides in (
                {"Master_Host": ENDPOINT + ".wrong"},
                {"Master_Host": ENDPOINT.replace(".", "X", 1)},
                {"Master_Port": "33060"},
            ):
                output = status(**overrides)
                self.assertFalse(bool(re.search(host, output)) and bool(re.search(port, output)))

    def test_existing_correct_source_does_not_need_reset_approval(self):
        filename = "configure-onprem-replica.yml"
        task_name = "Reject replacement of an unexpected existing replica source"
        for overrides, expected in (({}, True), ({"Master_Host": "old.source"}, False)):
            values = source_patterns(filename, context(status(**overrides)))
            task = next(t for t in tasks(filename) if t["name"] == task_name)
            result = ENV.compile_expression(task["ansible.builtin.assert"]["that"][0])(**values)
            self.assertEqual(bool(result), expected)


if __name__ == "__main__":
    unittest.main()
