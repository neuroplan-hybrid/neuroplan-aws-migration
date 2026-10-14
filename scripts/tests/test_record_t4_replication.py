"""Linux-only mock tests: never connect to an actual DB or run actual sudo."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'record_t4_replication.sh'
if not SCRIPT.exists():
    SCRIPT = Path(__file__).resolve().parent / 'record_t4_replication.sh'

STATUS = '''                   Master_Host: example.rds.amazonaws.com
              Slave_IO_Running: Yes
             Slave_SQL_Running: Yes
         Seconds_Behind_Master: 0
                 Last_IO_Errno: 0
                 Last_IO_Error:
                Last_SQL_Errno: 0
                Last_SQL_Error:
                    Using_Gtid: Slave_Pos
                   Gtid_IO_Pos: 0-9-42,1-1-3076
                    Read_Only: 1
                 Applied_GTID: 0-9-42,1-1-3076
'''


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'evidence.log'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}')
        self.env['MOCK_ROOT'] = str(self.root)
        self.env['MOCK_STATUS'] = STATUS
        self.mock('sudo', '''#!/usr/bin/env bash
if [[ "$1" == -v ]]; then exit "${MOCK_AUTH_RC:-0}"; fi
[[ "$1" == -n ]] || exit 90
shift
exec "$@"
''')
        self.mock('mariadb', '''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$MOCK_ROOT/calls"
printf '%s' "$MOCK_STATUS"
if [[ "${MOCK_QUERY_RC:-0}" != 0 ]]; then echo 'mock query failure' >&2; fi
exit "${MOCK_QUERY_RC:-0}"
''')

    def tearDown(self):
        self.temp.cleanup()

    def mock(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_script(self, seconds='1'):
        return subprocess.run(['bash', str(SCRIPT), seconds, str(self.log)],
                              env=self.env, capture_output=True, text=True, timeout=15)

    def test_success_display_file_and_read_only_sql(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = self.log.read_text()
        for token in ['QUERY_OK', 'Slave_IO_Running: Yes', 'Applied_GTID:', 'query_errors=0']:
            self.assertIn(token, saved)
            self.assertIn(token, result.stdout)
        self.assertEqual(self.log.stat().st_mode & 0o777, 0o600)
        calls = (self.root / 'calls').read_text()
        self.assertIn('--protocol=socket', calls)
        self.assertIn('SHOW SLAVE STATUS', calls)
        self.assertIn('SELECT @@GLOBAL.read_only', calls)
        for mutation in ['STOP SLAVE', 'START SLAVE', 'CHANGE MASTER', 'RESET SLAVE', 'INSERT ', 'UPDATE ', 'SET GLOBAL']:
            self.assertNotIn(mutation, calls)

    def test_query_failure_is_logged_and_nonzero(self):
        self.env['MOCK_QUERY_RC'] = '1'
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn('QUERY_ERROR rc=1', self.log.read_text())
        self.assertNotIn('QUERY_OK', result.stdout)

    def test_missing_status_is_not_success(self):
        self.env['MOCK_STATUS'] = 'Read_Only: 1\n'
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn('replica_status_missing', result.stdout)

    def test_null_lag_and_error_message_preserved(self):
        self.env['MOCK_STATUS'] = STATUS.replace('Seconds_Behind_Master: 0', 'Seconds_Behind_Master: NULL').replace('Last_IO_Error:', 'Last_IO_Error: connection lost')
        result = self.run_script()
        self.assertEqual(result.returncode, 0)
        self.assertIn('Seconds_Behind_Master: NULL', result.stdout)
        self.assertIn('Last_IO_Error: connection lost', result.stdout)
        # QUERY_OK means query succeeded, not that replication is healthy.

    def test_existing_evidence_is_not_overwritten(self):
        self.log.write_text('existing evidence')
        self.assertEqual(self.run_script().returncode, 2)
        self.assertEqual(self.log.read_text(), 'existing evidence')
        self.assertFalse((self.root / 'calls').exists())

    def test_auth_failure_no_query(self):
        self.env['MOCK_AUTH_RC'] = '1'
        self.assertEqual(self.run_script().returncode, 1)
        self.assertIn('sudo_authentication_failed', self.log.read_text())
        self.assertFalse((self.root / 'calls').exists())

    def test_invalid_duration_no_query(self):
        for seconds in ['0', '-1', 'abc', '86401', '9999999999999999999999']:
            self.assertEqual(self.run_script(seconds).returncode, 2)
        self.assertFalse((self.root / 'calls').exists())

    def test_timeout_return_code_is_recorded(self):
        self.mock('timeout', '#!/usr/bin/env bash\nexit 124\n')
        self.assertEqual(self.run_script().returncode, 1)
        self.assertIn('QUERY_ERROR rc=124', self.log.read_text())


if __name__ == '__main__':
    unittest.main()
