#!/usr/bin/env bash
# Read-only collector: bash record_t4_replication.sh [seconds] [new_log_path]
set -euo pipefail
umask 077
duration="${1:-600}"
if [[ ! "$duration" =~ ^[0-9]{1,5}$ ]]; then
  echo 'Duration must be 1..86400 seconds.' >&2; exit 2
fi
duration=$((10#$duration))
if (( duration < 1 || duration > 86400 )); then
  echo 'Duration must be 1..86400 seconds.' >&2; exit 2
fi
for tool in sudo mariadb timeout awk tee date hostname tr sleep; do
  command -v "$tool" >/dev/null || { echo "Missing command: $tool" >&2; exit 2; }
done
log="${2:-$HOME/repl_t4_$(hostname -s)_$(date +%Y%m%d-%H%M%S).log}"
if ! (set -o noclobber; : > "$log") 2>/dev/null; then
  echo "Cannot create a new log: $log" >&2; exit 2
fi
emit() { printf '%s\n' "$1" | tee -a "$log"; }
emit "# host=$(hostname -f) started=$(date --iso-8601=seconds) duration_seconds=$duration"
emit '# Read-only collection. Poll every 1 second after each query; query timeout 8 seconds.'
if ! sudo -v; then
  emit "$(date '+%F %T.%3N %z') QUERY_ERROR sudo_authentication_failed"; exit 1
fi
samples=0
errors=0
finish() { emit "# finished=$(date --iso-8601=seconds) samples=$samples query_errors=$errors log=$log"; }
trap 'exit 130' INT
trap 'exit 143' TERM
trap finish EXIT
start=$SECONDS
while (( SECONDS - start < duration )); do
  timestamp="$(date '+%F %T.%3N %z')"
  if output="$(timeout 8 sudo -n mariadb --protocol=socket --vertical --execute='
    SHOW SLAVE STATUS;
    SELECT @@GLOBAL.read_only AS Read_Only,
           @@GLOBAL.gtid_slave_pos AS Applied_GTID;
  ' 2>&1)"; then
    if [[ "$output" != *"Slave_IO_Running:"* || "$output" != *"Slave_SQL_Running:"* ]]; then
      ((errors+=1)); emit "$timestamp QUERY_ERROR replica_status_missing"
    else
      fields="$(printf '%s\n' "$output" | awk '
        /^[[:space:]]*(Master_Host|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_IO_Errno|Last_IO_Error|Last_SQL_Errno|Last_SQL_Error|Using_Gtid|Gtid_IO_Pos|Read_Only|Applied_GTID):/ {
          sub(/^[[:space:]]+/, ""); gsub(/\t/, " "); printf "%s\t", $0
        }
      ')"
      emit "$timestamp QUERY_OK $fields"
    fi
  else
    rc=$?; ((errors+=1))
    detail="$(printf '%s' "$output" | tr '\r\n\t' '   ')"
    emit "$timestamp QUERY_ERROR rc=$rc detail=$detail"
  fi
  ((samples+=1))
  sleep 1
done
if (( errors > 0 )); then
  exit 1
fi
