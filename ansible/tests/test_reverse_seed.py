import copy
import importlib.util
from pathlib import Path
import unittest
from types import SimpleNamespace
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / 'roles/rds_operation/files/reverse_seed_probe.py'
SPEC = importlib.util.spec_from_file_location('reverse_seed_probe', PATH)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


def snapshot(gtid='0-1822967101-448,1-1-3076'):
    return {'database': 'infraready', 'gtid': gtid, 'applied_gtid': '1-1-3076',
            'read_only': 1, 'active_writers': 0, 'log_bin': 1, 'log_slave_updates': 1,
            'oldest_gtid': '0-1822967101-428,1-1-3076',
            'tables': {'users': {'schema': 'abc', 'rows': 2, 'sha256': PROBE.row_digest(['V31:N', 'V32:V'])},
                       'plan_steps': {'schema': 'def', 'rows': 0, 'sha256': PROBE.row_digest([])}}}


class ReverseSeedTests(unittest.TestCase):
    def test_actual_1236_missing_domain_zero_can_choose_compared_full_boundary(self):
        before, local, after = snapshot(), snapshot('1-1-3076'), snapshot('0-1822967101-449,1-1-3076')
        result = PROBE.compare(before, local, after)
        self.assertEqual(result['baseline_gtid'], '0-1822967101-448,1-1-3076')
        self.assertEqual(result['tables'], 2)
        self.assertEqual(result['rows'], 2)

    def test_same_count_different_data_or_columns_is_rejected(self):
        for field, bad in [('sha256', 'different-content'), ('schema', 'different-column')]:
            local = snapshot('1-1-3076')
            local['tables']['users'][field] = bad
            with self.assertRaises(ValueError):
                PROBE.compare(snapshot(), local, snapshot())

    def test_missing_extra_and_empty_tables_are_rejected(self):
        for table_map in [{}, {'users': snapshot()['tables']['users']},
                          dict(snapshot()['tables'], extra={})]:
            local = snapshot('1-1-3076')
            local['tables'] = table_map
            with self.assertRaises(ValueError):
                PROBE.compare(snapshot(), local, snapshot())

    def test_never_advances_local_domain_one_to_hide_missing_application_writes(self):
        for gtid in ['1-1-3075', '1-1-3077', '1-99-3076', '2-1-3076', '']:
            with self.subTest(gtid=gtid), self.assertRaises(ValueError):
                PROBE.compare(snapshot(), snapshot(gtid), snapshot())

    def test_rejects_rds_application_drift_between_snapshots(self):
        after = snapshot('0-1822967101-449,1-1-3076')
        after['tables']['users']['sha256'] = 'changed'
        with self.assertRaises(ValueError):
            PROBE.compare(snapshot(), snapshot('1-1-3076'), after)

    def test_rejects_unknown_or_duplicate_domains(self):
        for gtid in ['0-1822967101-448,1-1-3076,2-7-1', '0-1822967101-448,1-1-3076,0-9-1']:
            with self.subTest(gtid=gtid), self.assertRaises(ValueError):
                PROBE.compare(snapshot(gtid), snapshot('1-1-3076'), snapshot(gtid))

    def test_rejects_regression_and_server_change(self):
        for gtid in ['0-1822967101-447,1-1-3076', '0-99-449,1-1-3076', '0-1822967101-449,1-1-3077']:
            with self.subTest(gtid=gtid), self.assertRaises(ValueError):
                PROBE.compare(snapshot(), snapshot('1-1-3076'), snapshot(gtid))
        local = snapshot('0-1822967101-450,1-1-3076')
        local['applied_gtid'] = local['gtid']
        with self.assertRaises(ValueError):
            PROBE.compare(snapshot(), local, snapshot())

    def test_rejects_purged_baseline_or_new_domain_in_retained_log(self):
        for floor in ['0-1822967101-449,1-1-3076', '0-1822967101-428,1-1-3077', '2-1-1']:
            after = snapshot()
            after['oldest_gtid'] = floor
            with self.subTest(floor=floor), self.assertRaises(ValueError):
                PROBE.compare(snapshot(), snapshot('1-1-3076'), after)

    def test_rejects_active_writers_non_readonly_and_disabled_binlog(self):
        for which, field, value in [('local', 'read_only', 0), ('local', 'active_writers', 1),
                                   ('before', 'active_writers', 1), ('after', 'active_writers', 1),
                                   ('before', 'log_bin', 0), ('before', 'log_slave_updates', 0)]:
            inputs = dict(before=snapshot(), local=snapshot('1-1-3076'), after=snapshot())
            inputs[which][field] = value
            with self.subTest(which=which, field=field), self.assertRaises(ValueError):
                PROBE.compare(**inputs)

    def test_row_hash_is_order_independent_and_retains_duplicates_null_empty_boundaries(self):
        self.assertEqual(PROBE.row_digest(['V01:N', 'V02:V']), PROBE.row_digest(['V02:V', 'V01:N']))
        self.assertNotEqual(PROBE.row_digest(['N']), PROBE.row_digest(['V']))
        self.assertNotEqual(PROBE.row_digest(['V01']), PROBE.row_digest(['V01', 'V01']))
        self.assertNotEqual(PROBE.row_digest(['V01:V02']), PROBE.row_digest(['V0102:V']))

    def test_gtid_parser(self):
        self.assertEqual(PROBE.gtid_map('0-9-1, 1-1-3076')[1], (1, 3076))
        for invalid in ['not-a-gtid', '0-1-2,0-1-3', "0-1-2';RESET MASTER"]:
            with self.assertRaises(ValueError):
                PROBE.gtid_map(invalid)

    def test_cli_snapshot_is_read_only_uses_ca_and_never_puts_password_in_argv(self):
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            query = kwargs['input']
            if 'information_schema.TABLES' in query:
                stdout = 'users\tInnoDB\n'
            elif 'information_schema.COLUMNS' in query:
                stdout = 'id\tint(11)\t\t\tNO\t\n'
            elif 'START TRANSACTION' in query:
                stdout = 'META|0-9-448,1-1-3076|1-1-3076|0|1|1\nWRITERS|0\nTABLE|0\nV31\nV32\n'
            elif 'SHOW BINARY LOGS' in query:
                stdout = 'mysql-bin-changelog.000317\t773\n'
            elif 'SHOW BINLOG EVENTS' in query:
                stdout = 'mysql-bin-changelog.000317\t256\tGtid_list\t9\t315\t[0-9-428,1-1-3076]\n'
            else:
                self.fail('Unexpected SQL')
            return SimpleNamespace(returncode=0, stdout=stdout)

        args = SimpleNamespace(database='infraready', host='sample.rds.amazonaws.com', port=3306,
                               user='neuroplanadmin', ca='/tmp/verified-ca.pem', socket='/unused')
        with patch.dict(PROBE.os.environ, {'RDS_PROBE_PASSWORD': 'NEVER_IN_ARGV'}), patch.object(PROBE.subprocess, 'run', side_effect=run):
            result = PROBE.snapshot(args)
        self.assertEqual(result['tables']['users']['rows'], 2)
        self.assertEqual(result['oldest_gtid'], '0-9-428,1-1-3076')
        for argv, kwargs in calls:
            self.assertNotIn('NEVER_IN_ARGV', ' '.join(argv))
            self.assertIn('--ssl-verify-server-cert', argv)
            self.assertIn('--ssl-ca=/tmp/verified-ca.pem', argv)
            self.assertEqual(kwargs['env']['MYSQL_PWD'], 'NEVER_IN_ARGV')
            self.assertNotIn('RDS_PROBE_PASSWORD', kwargs['env'])
            self.assertNotIn('SET GLOBAL', kwargs['input'])
            self.assertNotIn('CHANGE MASTER', kwargs['input'])
        self.assertTrue(any('WITH CONSISTENT SNAPSHOT, READ ONLY' in c[1]['input'] for c in calls))

    def test_cli_failure_does_not_expose_sql_rows_or_password(self):
        args = SimpleNamespace(database='infraready', host=None, socket='/test.sock')
        with patch.object(PROBE.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout='PRIVATE ROW', stderr='PRIVATE PASSWORD')):
            with self.assertRaisesRegex(ValueError, '^MariaDB CLI query failed') as raised:
                PROBE.snapshot(args)
        self.assertNotIn('PRIVATE', str(raised.exception))

    def test_recovery_task_has_gate_fresh_comparison_and_no_reset(self):
        import yaml
        path = PATH.parents[1] / 'tasks/configure-onprem-replica.yml'
        tasks = yaml.safe_load(path.read_text(encoding='utf8'))
        names = [t['name'] for t in tasks]
        compare_name = 'Compare full application data before any approved GTID baseline change'
        apply_name = 'Apply freshly compared reverse-seed GTID only with explicit recovery approval'
        self.assertLess(names.index(compare_name), names.index(apply_name))
        apply = tasks[names.index(apply_name)]
        self.assertEqual(apply['when'], 'rds_operation_reverse_seed_recovery_approved | bool')
        self.assertIn('rds_reverse_baseline.baseline_gtid', apply['ansible.builtin.command']['argv'][-1])
        self.assertNotIn('RESET', apply['ansible.builtin.command']['argv'][-1])

    def test_guard_patterns_are_facts_not_escaped_jinja_literals(self):
        import re
        import yaml
        path = PATH.parents[1] / 'tasks/configure-onprem-replica.yml'
        tasks = yaml.safe_load(path.read_text(encoding='utf8'))
        facts = next(t['ansible.builtin.set_fact'] for t in tasks
                     if t['name'] == 'Build reverse-seed guard patterns outside Jinja string literals')
        self.assertRegex('\tSlave_IO_Running: Connecting\r\n', facts['rds_reverse_io_active_pattern'])
        self.assertIsNone(re.search(facts['rds_reverse_sql_error_pattern'], ' Last_SQL_Error: \n Last_IO_Error: \n'))
        self.assertRegex(' Last_SQL_Error: Duplicate entry\n', facts['rds_reverse_sql_error_pattern'])
        self.assertRegex(' Replicate_Ignore_DB: mysql\n', facts['rds_reverse_conflict_pattern'])
        self.assertEqual([x.strip() for x in re.findall(facts['rds_reverse_db_filter_pattern'], '\tReplicate_Do_DB: infraready\r\n')], ['infraready'])
        self.assertTrue(all("search('" not in str(t) and "regex_findall('" not in str(t)
                            for t in tasks if t['name'] in {
                                'Reject GTID recovery on a running or unhealthy SQL replica',
                                'Require frozen writes and reject conflicting existing replication filters',
                                'Apply application-only filters with replication threads stopped'}))

    def test_demote_and_tls_configuration_cannot_start_before_exact_gtid_guard(self):
        import yaml
        from types import SimpleNamespace
        from jinja2 import Environment
        path = PATH.parents[1] / 'tasks/configure-onprem-replica.yml'
        tasks = yaml.safe_load(path.read_text(encoding='utf8'))
        names = [t['name'] for t in tasks]
        configure = next(t for t in tasks if t['name'] == 'Configure this On-Prem DB as an RDS GTID replica')
        repair = next(t for t in tasks if t['name'].startswith('Repair TLS'))
        self.assertIn('MASTER_DEMOTE_TO_SLAVE=1', configure['ansible.builtin.shell'])
        self.assertNotIn('START SLAVE', configure['ansible.builtin.shell'])
        self.assertNotIn('START SLAVE', repair['ansible.builtin.command']['argv'][-1])
        read_name = 'Read applied GTID after source configuration and before replica start'
        guard_name = 'Require approved GTID preserved after CHANGE MASTER before START SLAVE'
        start_name = 'Ensure a configured RDS replica is read only and started'
        self.assertLess(names.index(configure['name']), names.index(read_name))
        self.assertLess(names.index(repair['name']), names.index(read_name))
        self.assertLess(names.index(read_name), names.index(guard_name))
        self.assertLess(names.index(guard_name), names.index(start_name))
        guard = tasks[names.index(guard_name)]
        self.assertEqual(guard['when'], 'rds_operation_reverse_seed_recovery_approved | bool')
        predicate = Environment().compile_expression(guard['ansible.builtin.assert']['that'][0])
        expected = '0-1822967101-448,1-1-3076'
        for actual, accepted in [(expected+'\n', True), ('1-1-3076', False),
                                 ('0-1822967101-448,1-1-3077', False),
                                 ('0-1822967101-449,1-1-3076', False),
                                 (expected+',2-9-1', False)]:
            self.assertEqual(predicate(rds_reverse_configured_gtid=SimpleNamespace(stdout=actual),
                                       rds_reverse_baseline={'baseline_gtid': expected}), accepted)


if __name__ == '__main__':
    unittest.main()
