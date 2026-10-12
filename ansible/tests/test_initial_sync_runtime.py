"""Regression tests for backup metadata parsing and RDS MariaDB status calls."""
from pathlib import Path
from types import SimpleNamespace
import re
import unittest

import yaml
from jinja2 import Environment, StrictUndefined

TASK_DIR = Path(__file__).resolve().parents[1] / "roles" / "rds_operation" / "tasks"
ENV = Environment(undefined=StrictUndefined)
ENV.tests["match"] = lambda value, pattern: re.match(pattern, value) is not None


def tasks(filename):
    return yaml.safe_load((TASK_DIR / filename).read_text(encoding="utf-8"))


def metadata_task(name):
    return next(t for t in tasks("discover-seed-backup.yml") if t["name"] == name)


def parse_metadata(stdout):
    task = metadata_task("Save selected backup path checksum and GTID")
    values = {"rds_operation_seed_discovery": SimpleNamespace(stdout=stdout)}
    return {
        name: ENV.from_string(expression).render(**values)
        for name, expression in task["ansible.builtin.set_fact"].items()
    }


def accepts_metadata(stdout):
    task = metadata_task("Require selected backup metadata to be unambiguous")
    values = {"rds_operation_seed_discovery": SimpleNamespace(stdout=stdout)}
    return all(ENV.compile_expression(expr)(**values)
               for expr in task["ansible.builtin.assert"]["that"])


class BackupMetadataTests(unittest.TestCase):
    checksum = "a" * 64

    def check_sample(self, path, ending=""):
        stdout = path + "\t" + self.checksum + "\t1-1-2993" + ending
        self.assertTrue(accepts_metadata(stdout.rstrip("\r\n")))
        result = parse_metadata(stdout)
        self.assertEqual(result["rds_operation_seed_sql_gz_onprem"], path)
        self.assertEqual(result["rds_operation_seed_sha256"], self.checksum)
        self.assertEqual(result["rds_operation_inbound_gtid_position"], "1-1-2993")

    def test_actual_tab_separated_metadata(self):
        self.check_sample("/mnt/db-backup/infraready_2026-10-12_133958_db-primary.sql.gz")

    def test_preserve_spaces_inside_backup_path(self):
        self.check_sample("/mnt/db backup/infraready  latest.sql.gz")

    def test_line_ending_does_not_contaminate_checksum_or_gtid(self):
        self.check_sample("/mnt/db-backup/infraready.sql.gz", "\r\n")

    def test_reject_invalid_metadata_before_indexing(self):
        for stdout in (
            "/mnt/backup.sql.gz",
            "/mnt/backup.sql.gz\t" + self.checksum,
            "/mnt/backup.sql.gz\tshort\t1-1-2993",
            "/mnt/backup.sql.gz\t" + self.checksum + "\tinvalid",
            "/mnt/backup.sql.gz\t" + self.checksum + "\t1-1-2993\textra",
        ):
            with self.subTest(stdout=stdout):
                self.assertFalse(accepts_metadata(stdout))


class RdsStatusProcedureTests(unittest.TestCase):
    files = (
        "configure-rds-inbound.yml",
        "verify-rds-inbound.yml",
        "finish-rds-cutover.yml",
    )

    def test_all_rds_status_queries_use_supported_procedure(self):
        for filename in self.files:
            with self.subTest(filename=filename):
                source = (TASK_DIR / filename).read_text(encoding="utf-8")
                self.assertNotIn("rds_show_slave_status", source)
                queries = [t for t in tasks(filename)
                           if "CALL mysql.rds_replica_status;" in t.get("ansible.builtin.shell", "")]
                self.assertEqual(len(queries), 1)

    def test_status_queries_keep_vertical_output_and_secret_protection(self):
        for filename in self.files:
            with self.subTest(filename=filename):
                task = next(t for t in tasks(filename)
                            if "CALL mysql.rds_replica_status;" in t.get("ansible.builtin.shell", ""))
                self.assertIn("--vertical", task["ansible.builtin.shell"])
                self.assertTrue(task["no_log"])
                self.assertFalse(task["changed_when"])
                self.assertIn("RDS_MASTER_PASSWORD", task["environment"])


if __name__ == "__main__":
    unittest.main()
