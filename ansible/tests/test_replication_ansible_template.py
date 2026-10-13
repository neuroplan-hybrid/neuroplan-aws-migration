"""Use real Ansible templating in Linux CI, not just plain Jinja rendering."""
import re
import unittest

from test_replication_status_patterns import context, status, tasks

try:
    from ansible.parsing.dataloader import DataLoader
    from ansible.template import Templar
except ImportError:
    Templar = None


@unittest.skipIf(Templar is None, "Real Ansible runtime is installed by Linux CI")
class AnsibleSourcePatternTests(unittest.TestCase):
    def render_facts(self, filename, prefix, values):
        task = next(t for t in tasks(filename) if t["name"].startswith(prefix))
        templar = Templar(loader=DataLoader(), variables=values)
        return {name: templar.template(expr)
                for name, expr in task["ansible.builtin.set_fact"].items()}

    def test_source_and_ca_patterns_in_actual_ansible(self):
        for filename in ("configure-onprem-replica.yml", "verify-onprem-replica.yml"):
            for indent, newline in (("", "\n"), ("    ", "\n"), ("\t", "\r\n")):
                output = status(indent, newline)
                values = context(output)
                facts = self.render_facts(filename, "Build exact expected", values)
                if filename == "configure-onprem-replica.yml":
                    facts.update(self.render_facts(filename, "Build expected RDS replication TLS", values))
                for name in ("rds_operation_master_host_pattern", "rds_operation_master_port_pattern",
                             "rds_operation_ssl_ca_pattern"):
                    with self.subTest(filename=filename, name=name, indent=indent):
                        self.assertIsNotNone(re.search(facts[name], output))
                for overrides in ({"Master_Host": "wrong.source"}, {"Master_Port": "33060"}):
                    bad = status(**overrides)
                    self.assertFalse(bool(re.search(facts["rds_operation_master_host_pattern"], bad))
                                     and bool(re.search(facts["rds_operation_master_port_pattern"], bad)))

    def test_reproduces_original_double_escape_false_negative(self):
        original = "{{ '(?m)^[ \\\\t]*Master_Host:[ \\\\t]+' ~ (rds_operation_endpoint | regex_escape) ~ '[ \\\\t]*\\\\r?$' }}"
        rendered = Templar(loader=DataLoader(), variables=context(status())).template(original)
        self.assertIsNone(re.search(rendered, status()))


if __name__ == "__main__":
    unittest.main()
