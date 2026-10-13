"""Exercise actual TLS tasks and recovery predicates without DB mutations."""
from types import SimpleNamespace
import re
import unittest

from test_replication_status_patterns import ENV, context, source_patterns, status, tasks

ENV.tests["match"] = lambda value, pattern: re.match(pattern, str(value)) is not None


class ReplicationTlsTests(unittest.TestCase):
    def values(self, output, ca_changed=False):
        values = source_patterns("configure-onprem-replica.yml", context(output))
        task = next(t for t in tasks("configure-onprem-replica.yml")
                    if t["name"] == "Build expected RDS replication TLS status patterns")
        for name, expr in task["ansible.builtin.set_fact"].items():
            values[name] = ENV.from_string(expr).render(**values).strip()
        values["rds_operation_replication_ca_install"] = SimpleNamespace(changed=ca_changed)
        return values

    def repairs(self, output, ca_changed=False):
        task = next(t for t in tasks("configure-onprem-replica.yml")
                    if t["name"].startswith("Repair TLS"))
        values = self.values(output, ca_changed)
        return all(ENV.compile_expression(e)(**values) for e in task["when"])

    def test_real_certificate_failure_repairs_without_reset_or_password_change(self):
        output = status(Master_SSL_CA_File="", Slave_IO_Running="Connecting",
                        Seconds_Behind_Master="NULL",
                        Last_IO_Error="SSL connection error: Failed to verify the server certificate")
        self.assertTrue(self.repairs(output))
        task = next(t for t in tasks("configure-onprem-replica.yml")
                    if t["name"].startswith("Repair TLS"))
        sql = task["ansible.builtin.command"]["argv"][-1]
        self.assertIn("MASTER_SSL_VERIFY_SERVER_CERT=1", sql)
        self.assertIn("MASTER_SSL_CA=", sql)
        for forbidden in ("RESET", "gtid_slave_pos", "MASTER_PASSWORD", "MASTER_HOST", "MASTER_USE_GTID"):
            self.assertNotIn(forbidden, sql)

    def test_no_tls_reconfigure_when_already_correct(self):
        self.assertFalse(self.repairs(status()))

    def test_changed_ca_or_disabled_verification_triggers_repair(self):
        self.assertTrue(self.repairs(status(), ca_changed=True))
        self.assertTrue(self.repairs(status(Master_SSL_Verify_Server_Cert="No")))
        self.assertTrue(self.repairs(status(Master_SSL_Allowed="No")))

    def test_tls_repair_never_targets_a_different_source(self):
        self.assertFalse(self.repairs(status(Master_Host="old.source", Master_SSL_CA_File="")))
        self.assertFalse(self.repairs(status(Master_Port="33060", Master_SSL_CA_File="")))
        self.assertFalse(self.repairs(""))

    def test_ca_download_verified_pinned_and_controller_only(self):
        block = tasks("prepare-replication-tls.yml")[1]
        download = next(t for t in block["block"] if "ansible.builtin.get_url" in t)
        options = download["ansible.builtin.get_url"]
        self.assertTrue(options["validate_certs"])
        self.assertTrue(options["checksum"].startswith("sha256:"))
        self.assertEqual(options["url"],
                         "https://truststore.pki.rds.amazonaws.com/ap-northeast-2/ap-northeast-2-bundle.pem")
        self.assertIn("rds_controller", download["delegate_to"])
        self.assertFalse(download["become"])
        self.assertEqual(block["always"][0]["ansible.builtin.file"]["state"], "absent")

    def test_reject_disabled_tls_unsafe_path_or_checksum(self):
        checks = tasks("prepare-replication-tls.yml")[0]["ansible.builtin.assert"]["that"]
        values = dict(rds_operation_replication_use_ssl=True,
                      rds_operation_aws_region="ap-northeast-2",
                      rds_operation_replication_ca_file="/etc/my.cnf.d/rds-ca/ca-bundle.pem",
                      rds_operation_replication_ca_sha256="a" * 64)
        self.assertTrue(all(ENV.compile_expression(e)(**values) for e in checks))
        for key, value in (("rds_operation_replication_use_ssl", False),
                           ("rds_operation_aws_region", "us-east-1"),
                           ("rds_operation_replication_ca_file", "/tmp/ca';bad.pem"),
                           ("rds_operation_replication_ca_sha256", "bad")):
            with self.subTest(key=key):
                modified = dict(values, **{key: value})
                self.assertFalse(all(ENV.compile_expression(e)(**modified) for e in checks))

    def test_ca_install_precedes_any_replication_stop_and_verify_stays_read_only(self):
        configuration = tasks("configure-onprem-replica.yml")
        names = [t["name"] for t in configuration]
        self.assertLess(names.index("Prepare verified RDS replication TLS before changing DB state"),
                        names.index("Configure this On-Prem DB as an RDS GTID replica"))
        self.assertEqual(configuration[-1]["ansible.builtin.import_tasks"], "verify-onprem-replica.yml")
        verify = tasks("verify-onprem-replica.yml")
        read = next(t for t in verify if t["name"] == "Read On-Prem replica status")
        self.assertFalse(read["changed_when"])
        for forbidden in ("CHANGE MASTER", "STOP SLAVE", "RESET", "START SLAVE"):
            self.assertNotIn(forbidden, read["ansible.builtin.shell"])
        for expression in read["until"]:
            self.assertTrue(ENV.compile_expression(expression)(**context(status())))
        self.assertFalse(all(ENV.compile_expression(e)(**context(status(Slave_IO_Running="Connecting")))
                             for e in read["until"]))


if __name__ == "__main__":
    unittest.main()
