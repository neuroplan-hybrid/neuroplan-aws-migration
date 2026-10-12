"""Regression checks for CLI account provisioning; no live MariaDB required."""
from pathlib import Path
from types import SimpleNamespace
import re
import sqlite3
import unittest

import yaml
from jinja2 import Environment, StrictUndefined

ANSIBLE_DIR = Path(__file__).resolve().parents[1]
TASK_FILE = ANSIBLE_DIR / "roles/rds_operation/tasks/prepare-inbound-source.yml"
ENV = Environment(undefined=StrictUndefined)
ENV.filters["bool"] = bool
ENV.tests["match"] = lambda value, pattern: re.match(pattern, str(value)) is not None
PASSWORD = "A" * 40


def tasks():
    return yaml.safe_load(TASK_FILE.read_text(encoding="utf-8"))


def values(**overrides):
    result = dict(rds_operation_execute_mutations=True,
                  rds_operation_inbound_repl_hosts=["10.20.100.%", "10.20.101.%"],
                  rds_operation_inbound_repl_username="onprem_to_rds",
                  rds_operation_inbound_repl_password=PASSWORD,
                  rds_operation_socket="/var/lib/mysql/mysql.sock", item="10.20.100.%")
    result.update(overrides)
    return result


def valid(task, context):
    return all(ENV.compile_expression(e)(**context)
               for e in task["ansible.builtin.assert"]["that"])


def command_task(prefix):
    return next(t for t in tasks() if t["name"].startswith(prefix))


class InboundAccountCliTests(unittest.TestCase):
    def test_no_python_mysql_module_or_unused_collection(self):
        self.assertFalse(any("community.mysql.mysql_user" in t for t in tasks()))
        req = yaml.safe_load((ANSIBLE_DIR / "requirements.yml").read_text(encoding="utf-8"))
        self.assertNotIn("community.mysql", [c["name"] for c in req["collections"]])

    def test_password_is_stdin_only_and_no_log(self):
        task = command_task("Create least-privilege")
        command = task["ansible.builtin.command"]
        argv = [ENV.from_string(a).render(**values()) for a in command["argv"]]
        self.assertEqual(argv[0], "mariadb")
        self.assertIn("--protocol=socket", argv)
        self.assertIn("--user=root", argv)
        self.assertIn("--socket=/var/lib/mysql/mysql.sock", argv)
        self.assertNotIn(PASSWORD, " ".join(argv))
        sql = ENV.from_string(command["stdin"]).render(**values())
        self.assertIn(PASSWORD, sql)
        self.assertTrue(task["no_log"])
        self.assertNotIn("shell", command)

    def test_reexecution_targets_same_account_and_resets_direct_privileges(self):
        sql = command_task("Create least-privilege")["ansible.builtin.command"]["stdin"]
        for host in values()["rds_operation_inbound_repl_hosts"]:
            rendered = ENV.from_string(sql).render(**values(item=host))
            account = "'onprem_to_rds'@'" + host + "'"
            self.assertEqual(rendered.count(account), 4)
            self.assertIn("CREATE USER IF NOT EXISTS", rendered)
            self.assertIn("ALTER USER", rendered)
            self.assertIn("REVOKE ALL PRIVILEGES, GRANT OPTION", rendered)
            self.assertIn("GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.*", rendered)
            self.assertEqual(rendered, ENV.from_string(sql).render(**values(item=host)))
            self.assertNotIn("DROP USER", rendered)
            self.assertNotIn("CHANGE MASTER", rendered)

    def test_approval_password_and_username_validation(self):
        task = tasks()[0]
        self.assertTrue(valid(task, values()))
        for override in (
            {"rds_operation_execute_mutations": False},
            {"rds_operation_inbound_repl_password": "centos"},
            {"rds_operation_inbound_repl_password": PASSWORD + "'"},
            {"rds_operation_inbound_repl_password": PASSWORD + "\n"},
            {"rds_operation_inbound_repl_username": "bad'; DROP USER x; --"},
            {"rds_operation_inbound_repl_username": "onprem_to_rds\n"},
            {"rds_operation_inbound_repl_hosts": ["10.20.100.%"]},
        ):
            with self.subTest(override=override):
                self.assertFalse(valid(task, values(**override)))

    def test_host_validation(self):
        task = command_task("Require safe inbound")
        for host in ("10.20.100.%", "10.20.101.%", "rds-host.example"):
            self.assertTrue(valid(task, values(item=host)))
        for host in ("", "10.20.100.%\n", "host'; DROP USER x; --", "host with space", None):
            with self.subTest(host=host):
                self.assertFalse(valid(task, values(item=host)))

    def run_privilege_query(self, privileges):
        task = command_task("Read the replication")
        sql = ENV.from_string(task["ansible.builtin.command"]["stdin"]).render(**values())
        # Execute the actual SELECT predicate with equivalent SQL functions in memory.
        with sqlite3.connect(":memory:") as db:
            db.execute("ATTACH DATABASE ':memory:' AS information_schema")
            db.execute("CREATE TABLE information_schema.USER_PRIVILEGES "
                       "(GRANTEE TEXT, PRIVILEGE_TYPE TEXT, IS_GRANTABLE TEXT)")
            db.create_function("IF", 3, lambda condition, yes, no: yes if condition else no)
            db.create_function("CONCAT", -1, lambda *parts: "".join(parts))
            db.executemany("INSERT INTO information_schema.USER_PRIVILEGES VALUES (?, ?, ?)",
                           [("'onprem_to_rds'@'10.20.100.%'", p, g) for p, g in privileges])
            return db.execute(sql).fetchone()[0]

    def test_privilege_verifier_accepts_mariadb_alias(self):
        for monitor in ("REPLICATION CLIENT", "BINLOG MONITOR"):
            self.assertEqual(self.run_privilege_query([
                ("REPLICATION SLAVE", "NO"), (monitor, "NO")]), "REPLICATION_ACCOUNT_OK")

    def test_privilege_verifier_rejects_missing_extra_and_grant_option(self):
        cases = (
            [],
            [("REPLICATION SLAVE", "NO")],
            [("REPLICATION SLAVE", "NO"), ("BINLOG MONITOR", "YES")],
            [("REPLICATION SLAVE", "NO"), ("BINLOG MONITOR", "NO"), ("SELECT", "NO")],
        )
        for case in cases:
            with self.subTest(case=case):
                self.assertEqual(self.run_privilege_query(case), "REPLICATION_ACCOUNT_INVALID")

    def test_result_assertion_and_readonly_verification(self):
        task = command_task("Require only the intended")
        self.assertTrue(valid(task, values(item=SimpleNamespace(stdout="REPLICATION_ACCOUNT_OK\n"))))
        self.assertFalse(valid(task, values(item=SimpleNamespace(stdout="REPLICATION_ACCOUNT_INVALID"))))
        self.assertFalse(command_task("Read the replication")["changed_when"])
        self.assertTrue(all(t["no_log"] for t in tasks()))


if __name__ == "__main__":
    unittest.main()
