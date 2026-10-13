#!/usr/bin/env python3
"""Read-only MariaDB CLI snapshots and fail-closed reverse-seed comparison.

No driver dependencies, data dumps, passwords in argv, or GTID mutation here.
Row fingerprints cover every column and duplicate row, independent of row order.
An explicit deployment/DDL freeze remains required across hosts (not atomic).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys


def identifier(value):
    return '`' + value.replace('`', '``') + '`'


def gtid_map(value):
    result = {}
    for item in value.split(',') if value else []:
        item = item.strip()
        if not re.fullmatch(r'[0-9]+-[0-9]+-[0-9]+', item):
            raise ValueError('Invalid GTID format')
        domain, server, sequence = map(int, item.split('-'))
        if domain in result:
            raise ValueError('Duplicate GTID domain')
        result[domain] = (server, sequence)
    return result


def row_digest(rows):
    # Fixed-width SHA-256 row digests, sorted; duplicates are retained.
    hashes = sorted(hashlib.sha256(row.encode('ascii')).digest() for row in rows)
    return hashlib.sha256(b''.join(hashes)).hexdigest()


def compare(before, local, after):
    if not before['tables'] or before['tables'] != local['tables'] or before['tables'] != after['tables']:
        raise ValueError('All-table schema/count/content comparison failed; do not advance GTID')
    if local['read_only'] != 1:
        raise ValueError('On-Prem must remain read_only=1')
    for snap in (before, local, after):
        if snap['active_writers'] != 0:
            raise ValueError('Active database write transaction observed')
    if before['database'] != local['database'] or before['database'] != after['database']:
        raise ValueError('Database identity mismatch')
    start = gtid_map(before['gtid'])
    end = gtid_map(after['gtid'])
    current = gtid_map(local['gtid'])
    applied = gtid_map(local['applied_gtid'])
    # This project has On-Prem application domain 1 and RDS local domain 0.
    # Other topologies are deliberately rejected rather than silently skipped.
    if set(start) != {0, 1} or set(end) != {0, 1} or set(current) - {0, 1}:
        raise ValueError('Unsupported GTID domains; expected RDS 0+1 and On-Prem 1 (optional 0)')
    if 1 not in current or start[1] != current[1] or start[1] != end[1]:
        raise ValueError('On-Prem domain 1 must match and remain unchanged on RDS')
    if start[0][0] != end[0][0] or start[0][1] > end[0][1]:
        raise ValueError('RDS domain 0 identity regressed/changed')
    if before['log_bin'] != 1 or before['log_slave_updates'] != 1:
        raise ValueError('RDS binlog prerequisites not met')
    for domain, position in applied.items():
        if domain not in start or position[0] != start[domain][0] or position[1] > start[domain][1]:
            raise ValueError('Would erase, regress, or cross an existing applied domain')
    for domain, position in current.items():
        if domain not in start or position[0] != start[domain][0] or position[1] > start[domain][1]:
            raise ValueError('Would overwrite divergent local GTID history')
    # The baseline must still be available after the comparison completes.
    floor = gtid_map(after['oldest_gtid'])
    for domain, position in floor.items():
        if domain not in start or position[0] != start[domain][0] or position[1] > start[domain][1]:
            raise ValueError('Baseline binlog already purged; compare again, do not guess')
    if floor.keys() - {0, 1}:
        raise ValueError('Unknown retained binlog domain')
    return {'baseline_gtid': before['gtid'], 'database': before['database'],
            'tables': len(before['tables']), 'rows': sum(t['rows'] for t in before['tables'].values()),
            'matched': True}


def snapshot(args):
    if not re.fullmatch(r'[A-Za-z0-9]+', args.database):
        raise ValueError('Unsafe database name (wildcard-free names only)')
    command = ['mariadb', '--batch', '--raw', '--skip-column-names',
               '--default-character-set=utf8mb4', '--connect-timeout=10']
    env = os.environ.copy()
    if args.host:
        if not args.user or not args.ca:
            raise ValueError('RDS snapshots require user and verified CA')
        command += ['--protocol=tcp', '--host=' + args.host, '--port=' + str(args.port),
                    '--user=' + args.user, '--ssl', '--ssl-ca=' + args.ca,
                    '--ssl-verify-server-cert']
        env['MYSQL_PWD'] = env.pop('RDS_PROBE_PASSWORD')
    else:
        command += ['--protocol=socket', '--socket=' + args.socket]

    def sql(query):
        proc = subprocess.run(command, input="SET SESSION time_zone='+00:00';\n" + query,
                              text=True, capture_output=True, env=env, timeout=300)
        if proc.returncode:
            # Do not expose row values, full queries or connection credentials.
            raise ValueError('MariaDB CLI query failed (exit %d); inspect DB separately' % proc.returncode)
        return proc.stdout.splitlines()

    db = args.database
    tables = sql("SELECT TABLE_NAME,ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='%s' "
                 "AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME;" % db)
    if not tables:
        raise ValueError('No application tables')
    manifest = {}
    queries = ["SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;",
               "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY;",
               "SELECT CONCAT('META|',@@global.gtid_current_pos,'|',@@global.gtid_slave_pos,'|',"
               "@@global.read_only,'|',@@global.log_bin,'|',@@global.log_slave_updates);",
               "SELECT CONCAT('WRITERS|',COUNT(*)) FROM information_schema.INNODB_TRX "
               "WHERE trx_rows_modified>0 AND trx_mysql_thread_id<>CONNECTION_ID();"]
    for index, record in enumerate(tables):
        name, engine = record.split('\t')
        if engine != 'InnoDB':
            raise ValueError('Non-InnoDB application table: ' + name)
        columns = sql("SELECT COLUMN_NAME,COLUMN_TYPE,COALESCE(CHARACTER_SET_NAME,''),"
                      "COALESCE(COLLATION_NAME,''),IS_NULLABLE,EXTRA FROM information_schema.COLUMNS "
                      "WHERE TABLE_SCHEMA='%s' AND TABLE_NAME=CONVERT(0x%s USING utf8mb4) "
                      "ORDER BY ORDINAL_POSITION;" % (db, name.encode().hex()))
        if not columns:
            raise ValueError('Table columns disappeared')
        manifest[str(index)] = {'name': name, 'schema': hashlib.sha256('\n'.join(columns).encode()).hexdigest()}
        fields = [identifier(c.split('\t')[0]) for c in columns]
        # NULL != empty; hexadecimal is unambiguous for BLOB/text/newlines/UTF-8.
        cells = ["IF(%s IS NULL,'N',CONCAT('V',HEX(CAST(%s AS BINARY))))" % (c, c) for c in fields]
        queries += ["SELECT 'TABLE|%d';" % index,
                    "SELECT CONCAT_WS(':',%s) FROM %s.%s;" % (','.join(cells), identifier(db), identifier(name))]
    queries += ['COMMIT;']
    output = sql('\n'.join(queries))
    _, gtid, applied, read_only, log_bin, log_slave_updates = output[0].split('|')
    if not output[1].startswith('WRITERS|'):
        raise ValueError('Malformed snapshot header')
    result = {'database': db, 'gtid': gtid, 'applied_gtid': applied,
              'read_only': int(read_only), 'log_bin': int(log_bin),
              'log_slave_updates': int(log_slave_updates), 'active_writers': int(output[1].split('|')[1]),
              'tables': {}, 'oldest_gtid': ''}
    groups, index = {}, None
    for row in output[2:]:
        if row.startswith('TABLE|'):
            index = row.split('|')[1]
            if index not in manifest or index in groups:
                raise ValueError('Malformed table marker')
            groups[index] = []
        elif index is not None:
            groups[index].append(row)
        else:
            raise ValueError('Unmarked row')
    if set(groups) != set(manifest):
        raise ValueError('Incomplete application snapshot')
    for index, rows in groups.items():
        info = manifest[index]
        result['tables'][info['name']] = {'schema': info['schema'], 'rows': len(rows), 'sha256': row_digest(rows)}
    if args.host:
        logs = sql('SHOW BINARY LOGS;')
        oldest = logs[0].split('\t')[0]
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', oldest):
            raise ValueError('Unsafe binlog filename')
        events = sql("SHOW BINLOG EVENTS IN '%s' LIMIT 4;" % oldest)
        lists = [r.split('\t')[-1].strip('[]') for r in events if r.split('\t')[2] == 'Gtid_list']
        if len(lists) != 1:
            raise ValueError('Cannot establish oldest binlog GTID boundary')
        result['oldest_gtid'] = lists[0]
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--compare', action='store_true')
    parser.add_argument('--database', default='infraready')
    parser.add_argument('--host')
    parser.add_argument('--user')
    parser.add_argument('--port', type=int, default=3306)
    parser.add_argument('--ca')
    parser.add_argument('--socket', default='/var/lib/mysql/mysql.sock')
    args = parser.parse_args()
    try:
        if args.compare:
            data = json.load(sys.stdin)
            result = compare(data['before'], data['local'], data['after'])
        else:
            result = snapshot(args)
        print(json.dumps(result, sort_keys=True))
    except (ValueError, KeyError, IndexError, OSError, subprocess.TimeoutExpired) as exc:
        print('Reverse-seed check refused: ' + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
