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
        "rds_operation_database": "infraready",
        "rds_operation_replication_ca_file": "/etc/my.cnf.d/rds-ca/ca-bundle.pem",
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
        "Master_SSL_Allowed": "Yes",
        "Master_SSL_CA_File": "/etc/my.cnf.d/rds-ca/ca-bundle.pem",
        "Master_SSL_Verify_Server_Cert": "Yes",
        "Read_Only": "1",
        "Replicate_Do_DB": "infraready",
        "Replicate_Wild_Do_Table": "infraready.%",
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
            {"Slave_IO_Running": "Connecting"},
            {"Seconds_Behind_Master": "NULL"},
            {"Seconds_Behind_Master": "5"},
            {"Read_Only": "0"},
            {"Master_SSL_Allowed": "No"},
            {"Master_SSL_CA_File": ""},
            {"Master_SSL_CA_File": "/wrong/ca.pem"},
            {"Master_SSL_Verify_Server_Cert": "No"},
            {"Replicate_Do_DB": ""},
            {"Replicate_Wild_Do_Table": "mysql.%"},
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



def renamed_status(indent="    ", newline="\n", **overrides):
    return (status(indent, newline, **overrides)
            .replace("Master_Host:", "Source_Host:")
            .replace("Master_Port:", "Source_Port:")
            .replace("Slave_IO_Running:", "Replica_IO_Running:")
            .replace("Slave_SQL_Running:", "Replica_SQL_Running:"))


class RdsStatusNamingTests(unittest.TestCase):
    def test_documented_replica_format_passes_inbound_and_cutover(self):
        for filename, task_name in InboundAndCutoverTests.checks:
            for indent, newline in (("", "\n"), ("    ", "\n"), ("\t", "\r\n")):
                with self.subTest(filename=filename, indent=indent):
                    self.assertTrue(assertion_passes(
                        filename, task_name, renamed_status(indent, newline)))

    def test_documented_replica_format_rejects_unhealthy_or_missing_fields(self):
        cases = (
            {"Slave_IO_Running": "No"},
            {"Slave_IO_Running": "Connecting"},
            {"Slave_IO_Running": "YesButNotHealthy"},
            {"Slave_SQL_Running": "No"},
            {"Slave_SQL_Running": None},
            {"Seconds_Behind_Master": "12"},
            {"Seconds_Behind_Master": "NULL"},
            {"Seconds_Behind_Master": None},
        )
        for filename, task_name in InboundAndCutoverTests.checks:
            for overrides in cases:
                with self.subTest(filename=filename, overrides=overrides):
                    self.assertFalse(assertion_passes(
                        filename, task_name, renamed_status(**overrides)))

    def test_both_host_names_trigger_reset_approval_gate(self):
        task = next(t for t in tasks("configure-rds-inbound.yml")
                    if t["name"] == "Require explicit reset approval for an existing RDS inbound replica")
        for factory in (status, renamed_status):
            for indent, newline in (("", "\n"), ("    ", "\n"), ("\t", "\r\n")):
                values = {
                    "rds_operation_existing_inbound_status": SimpleNamespace(stdout=factory(indent, newline)),
                    "rds_operation_allow_reset_replica": False,
                }
                with self.subTest(format=factory.__name__, indent=indent):
                    self.assertTrue(ENV.compile_expression(task["when"])(**values))
                    self.assertFalse(ENV.compile_expression(
                        task["ansible.builtin.assert"]["that"][0])(**values))
                    values["rds_operation_allow_reset_replica"] = True
                    self.assertTrue(ENV.compile_expression(
                        task["ansible.builtin.assert"]["that"][0])(**values))

    def test_all_existing_replica_guards_detect_both_host_names(self):
        expressions = []
        for task in tasks("configure-rds-inbound.yml"):
            conditions = task.get("when", [])
            if isinstance(conditions, str):
                conditions = [conditions]
            expressions.extend(c for c in conditions
                               if "rds_operation_existing_inbound_status.stdout" in c)
        self.assertEqual(len(expressions), 6)
        for expression in expressions:
            for factory in (status, renamed_status):
                self.assertTrue(ENV.compile_expression(expression)(
                    rds_operation_existing_inbound_status=SimpleNamespace(stdout=factory())))
            for output in ("", "Source_Host: \n", "Master_Host: \n",
                           "Not_Source_Host: 192.168.44.51\n"):
                self.assertFalse(ENV.compile_expression(expression)(
                    rds_operation_existing_inbound_status=SimpleNamespace(stdout=output)))

if __name__ == "__main__":
    unittest.main()
