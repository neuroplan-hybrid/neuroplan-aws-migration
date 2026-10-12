"""Test actual inventory/source expressions without SSH, AWS or DB mutations."""
from pathlib import Path
import re
import unittest

import yaml
from jinja2 import Environment, StrictUndefined

ANSIBLE_DIR = Path(__file__).resolve().parents[1]
TASK_DIR = ANSIBLE_DIR / "roles" / "rds_operation" / "tasks"
ENV = Environment(undefined=StrictUndefined)
ENV.tests["match"] = lambda value, pattern: re.match(pattern, str(value)) is not None


def tasks(filename):
    return yaml.safe_load((TASK_DIR / filename).read_text(encoding="utf-8"))


def context(ssh="192.168.14.51", address="192.168.44.51", include=True):
    host = {"ansible_host": ssh}
    if include:
        host["rds_operation_replication_host"] = address
    return {"groups": {"onprem_primary": ["db-primary"]},
            "hostvars": {"db-primary": host}}


def resolve(values):
    for task in tasks("resolve-inbound-source.yml"):
        if "ansible.builtin.assert" in task:
            for expression in task["ansible.builtin.assert"]["that"]:
                if not ENV.compile_expression(expression)(**values):
                    raise ValueError(task["ansible.builtin.assert"]["fail_msg"])
        elif "ansible.builtin.set_fact" in task:
            for name, expression in task["ansible.builtin.set_fact"].items():
                values[name] = ENV.from_string(expression).render(**values).strip()
    return values


class ReplicationSourceTests(unittest.TestCase):
    def test_source_uses_data_address_not_ssh(self):
        result = resolve(context())
        self.assertEqual(result["rds_operation_inbound_source_host"], "192.168.44.51")
        self.assertEqual(result["rds_operation_inbound_source_inventory_hostname"], "db-primary")

    def test_ssh_change_does_not_change_source_or_marker_identity(self):
        before = resolve(context())
        after = resolve(context(ssh="other-management-host"))
        self.assertEqual(before["rds_operation_inbound_source_host"],
                         after["rds_operation_inbound_source_host"])
        marker_task = next(t for t in tasks("seed.yml")
                           if t["name"] == "Require prior marker identity to match the current initial-sync target")
        after.update(rds_operation_identifier="neuroplan-rds-operation",
                     rds_operation_database="infraready",
                     rds_operation_initial_sync_marker_data={
                         "rds_identifier": "neuroplan-rds-operation",
                         "database": "infraready",
                         "source_inventory_hostname": "db-primary",
                         "source_host": before["rds_operation_inbound_source_host"]})
        checks = marker_task["ansible.builtin.assert"]["that"]
        self.assertTrue(all(ENV.compile_expression(e)(**after) for e in checks))
        after["rds_operation_initial_sync_marker_data"]["source_host"] = "192.168.14.51"
        self.assertFalse(all(ENV.compile_expression(e)(**after) for e in checks))

    def test_missing_replication_address_never_falls_back_to_ssh(self):
        with self.assertRaises(ValueError):
            resolve(context(include=False))

    def test_reject_empty_nonstring_and_unsafe_addresses(self):
        for address in ("", " ", " 192.168.44.51", "192.168.44.51\n",
                        None, 123, [], "host'; DROP USER x; --", "host:3306"):
            with self.subTest(address=address), self.assertRaises(ValueError):
                resolve(context(address=address))

    def test_allow_explicit_dns_source(self):
        result = resolve(context(address="db-primary.nplan.local"))
        self.assertEqual(result["rds_operation_inbound_source_host"], "db-primary.nplan.local")

    def test_require_exactly_one_primary(self):
        for hosts in ([], ["db-primary", "db-replica"]):
            values = context()
            values["groups"]["onprem_primary"] = hosts
            with self.subTest(hosts=hosts), self.assertRaises(ValueError):
                resolve(values)

    def test_example_inventory_separates_addresses_in_every_group(self):
        text = (ANSIBLE_DIR / "inventory" / "rds-operation.ini.example").read_text(encoding="utf-8")
        rows = [line.split() for line in text.splitlines() if line.startswith("db-")]
        self.assertEqual(len(rows), 3)
        for row in rows:
            values = dict(item.split("=", 1) for item in row[1:])
            suffix = "51" if row[0] == "db-primary" else "52"
            self.assertEqual(values["ansible_host"], "192.168.14." + suffix)
            self.assertEqual(values["rds_operation_replication_host"], "192.168.44." + suffix)


if __name__ == "__main__":
    unittest.main()
