#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Stock reconciliation batch job.
#
# Puts a noticeable but strictly bounded load on MySQL on a schedule, so the
# demo has a recurring, explainable background workload that an alert rule can
# key on. One START line and one END line per run, so it is obvious in logs
# when a run begins and ends.
#
# SAFETY - this job is deliberately built so it cannot become the problem that
# removeoldquotes.cfm was:
#   * every statement is a bounded aggregate over small tables. No CROSS JOIN,
#     no correlated subqueries, no UUID()/RAND() per row.
#   * the run stops after RECONCILE_MAX_SECONDS whatever is outstanding.
#   * it only ever reads. No INSERT, UPDATE or DELETE.
#   * each statement gets its own short max_execution_time, so a single query
#     cannot hang the run.
#
# Config (all via environment):
#   RECONCILE_INTERVAL_SECONDS  gap between runs        (default 5400 = 90 min)
#   RECONCILE_BATCHES           query batches per run   (default 1500)
#   RECONCILE_MAX_SECONDS       hard ceiling per run    (default 120)

set -uo pipefail

INTERVAL="${RECONCILE_INTERVAL_SECONDS:-5400}"
BATCHES="${RECONCILE_BATCHES:-1500}"
MAX_SECONDS="${RECONCILE_MAX_SECONDS:-120}"
DB="${MYSQL_DATABASE:-quotes}"
HOST="${MYSQL_HOST:-mysql}"
USER="${MYSQL_USER:-quotes_user}"

log() { printf '%s [stock-reconciler] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# 50ms statement ceiling: everything here should be well under 5ms.
SQL_PREFIX="SET SESSION max_execution_time=50;"

run_once() {
  local run_id start_ts elapsed batch queries=0
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  start_ts=$(date +%s)

  log "START run=${run_id} batches=${BATCHES} max_seconds=${MAX_SECONDS}"

  for ((batch = 1; batch <= BATCHES; batch++)); do
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= MAX_SECONDS )); then
      log "ABORT run=${run_id} reason=time_ceiling elapsed=${elapsed}s batch=${batch}/${BATCHES}"
      break
    fi

    # Four bounded aggregates per batch. Each touches small tables only:
    # services (50 rows), customers (50 rows), quote_items, and a LIMITed
    # join. None of these scale with the quotes table the way the old
    # removeoldquotes query did.
    mysql -h "$HOST" -u "$USER" -D "$DB" -N -B >/dev/null 2>&1 <<SQL
${SQL_PREFIX}
SELECT category, COUNT(*), AVG(base_price) FROM services GROUP BY category;
SELECT status, COUNT(*) FROM customers GROUP BY status;
SELECT qi.service_id, COUNT(*), SUM(qi.quantity)
  FROM quote_items qi GROUP BY qi.service_id LIMIT 50;
SELECT s.service_id, s.service_name, COUNT(qi.quote_item_id)
  FROM services s LEFT JOIN quote_items qi ON qi.service_id = s.service_id
  GROUP BY s.service_id, s.service_name LIMIT 50;
SQL
    queries=$(( queries + 4 ))
  done

  elapsed=$(( $(date +%s) - start_ts ))
  log "END run=${run_id} queries=${queries} elapsed=${elapsed}s next_in=${INTERVAL}s"
}

log "stock-reconciler started: interval=${INTERVAL}s batches=${BATCHES} max_seconds=${MAX_SECONDS}"

# Wait one interval before the first run, so a restart does not immediately
# load the database.
while true; do
  sleep "$INTERVAL"
  run_once
done
