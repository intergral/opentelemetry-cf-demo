#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Webinar control script. Every command prints what it did and the UTC timestamp.
#
#   ./demo.sh status              current flags, current toxics, container health
#   ./demo.sh baseline            all flags off, all toxics removed
#   ./demo.sh slow-db [ms]        add latency (default 800ms +/- jitter) on payment -> MySQL
#   ./demo.sh slow-db-ramp        ramp latency 0 -> 800ms over 5 minutes
#   ./demo.sh flag <name> <variant>   turn one flagd fault on or off
#   ./demo.sh fail-db [ms]        time out ~30% of payment's DB calls (default 1760ms)
#   ./demo.sh deploy-bad          "deploy" payment 2.0.3 (N+1 queries per charge)
#   ./demo.sh deploy-bad-v2       "deploy" payment 2.1.0 (a DIFFERENT N+1: quotes JOIN customers)
#   ./demo.sh rollback            roll payment back to 2.0.2
#   ./demo.sh reset               same as baseline; idempotent, safe any time
#   ./demo.sh baseline-toxic      re-apply only the 4ms baseline link latency
#
# Flag changes go through the flagd JSON file, which flagd watches, so no
# container restarts. Toxics go through the Toxiproxy control API, reached with
# `docker exec` so the API stays unpublished.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAGD_FILE="${REPO_DIR}/src/flagd/demo.flagd.json"
PROXY_NAME="payment-mysql"
TOXIC_NAME="payment-mysql-latency"
# Permanent, realistic network distance between payment and its database.
# Applied BY baseline/reset, not removed by them - a database on the other end
# of a real network is never 0ms away, and a few ms of it is what makes the
# N+1 deploy scenario land in a believable latency range.
BASELINE_TOXIC_NAME="payment-mysql-baseline"
# fail-db: a jittery latency toxic that pushes a share of queries past payment's
# per-query deadline (PAYMENT_QUERY_TIMEOUT_MS, 2000ms).
#
# The naive model is P = (latency + jitter - timeout) / (2 * jitter), but it
# UNDERSTATES the real rate badly, because timeouts feed back: each one destroys
# its connection, the replacement has to re-handshake across the slow link, and
# other charges queue behind it and time out too. Measured on 2026-11-12:
#     1760 +/- 600  model 30%  ->  actual 45.5%
#     1600 +/- 600  model 17%  ->  actual  4.3%
#     1500 +/- 1000 model 25%  ->  actual 25.9%   <-- chosen
# Note how steep that is: 160ms of latency took it from 4% to 45%. The wider
# jitter is what flattens it - a lower mean makes reconnects cheaper and spreads
# the distribution so the rate is less sensitive to the latency setting.
# Re-measure if you change either number; do not trust the formula alone.
FAIL_TOXIC_NAME="payment-mysql-failslow"
FAIL_LATENCY_MS="${FAIL_LATENCY_MS:-1500}"
FAIL_JITTER_MS="${FAIL_JITTER_MS:-1000}"
BASELINE_LATENCY_MS="${BASELINE_LATENCY_MS:-4}"
DEFAULT_LATENCY_MS=800
GOOD_VERSION="${GOOD_VERSION:-2.0.2}"
BAD_VERSION="${BAD_VERSION:-2.0.3}"
# 10 lookups x 8-15 items, plus 6 fixed and the INSERT = 87-157 queries.
# At the 4ms baseline link latency that is ~420-750ms of sequential round
# trips, which is the 500-800ms target range for the bad deploy.
BAD_ITEM_LOOKUPS="${BAD_ITEM_LOOKUPS:-10}"
# Second bad release. A DIFFERENT N+1 from 2.0.3: instead of pricing each item
# against `services`, it resolves each item's owning customer through
# `quotes JOIN customers`. New table, new statement shape, so Coworker should
# treat it as a new problem rather than a repeat. Same query volume, so payment
# lands in the same ~500-800ms range.
BAD2_VERSION="${BAD2_VERSION:-2.1.0}"
BAD2_CUSTOMER_LOOKUPS="${BAD2_CUSTOMER_LOOKUPS:-10}"
RAMP_SECONDS=300
RAMP_STEPS=10

# Flags that exist in demo.flagd.json. Used to validate `flag` and to reset.
ALL_FLAGS=(
  productCatalogFailure recommendationCacheFailure adManualGc adHighCpu
  adFailure kafkaQueueProblems cartFailure paymentFailure paymentDatabaseError
  paymentUnreachable loadGeneratorFloodHomepage imageSlowLoad
)

ts()   { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
say()  { printf '[%s] %s\n' "$(ts)" "$*"; }
die()  { printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2; exit 1; }

need_container() {
  local name="$1"
  docker inspect "$name" >/dev/null 2>&1 \
    || die "container '$name' not found - is the stack up? Try: make start"
  [ "$(docker inspect -f '{{.State.Status}}' "$name")" = "running" ] \
    || die "container '$name' is not running (state: $(docker inspect -f '{{.State.Status}}' "$name"))"
}

tp() { docker exec toxiproxy /toxiproxy-cli "$@"; }

# ---------------------------------------------------------------- flags -----

flag_set() {
  local name="$1" variant="$2"
  [ -f "$FLAGD_FILE" ] || die "flag file not found: $FLAGD_FILE"

  local found=0
  for f in "${ALL_FLAGS[@]}"; do [ "$f" = "$name" ] && found=1; done
  [ "$found" = 1 ] || die "unknown flag '$name'. Known flags: ${ALL_FLAGS[*]}"

  python3 - "$FLAGD_FILE" "$name" "$variant" <<'PY'
import json, sys
path, name, variant = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    doc = json.load(fh)
flag = doc['flags'].get(name)
if flag is None:
    sys.exit(f"flag '{name}' is not in the flag file")
if variant not in flag['variants']:
    sys.exit(f"variant '{variant}' not valid for '{name}'. "
             f"Valid: {', '.join(flag['variants'])}")
flag['defaultVariant'] = variant
with open(path, 'w') as fh:
    json.dump(doc, fh, indent=2)
    fh.write('\n')
PY
}

flags_all_off() {
  local changed=0
  for f in "${ALL_FLAGS[@]}"; do
    local cur; cur="$(flag_get "$f")"
    if [ "$cur" != "off" ]; then
      flag_set "$f" off
      say "  flag $f: $cur -> off"
      changed=$((changed+1))
    fi
  done
  [ "$changed" = 0 ] && say "  all flags were already off"
  return 0
}

flag_get() {
  python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))['flags'][sys.argv[2]]['defaultVariant'])
" "$FLAGD_FILE" "$1"
}

# --------------------------------------------------------------- toxics -----

toxic_clear() {
  need_container toxiproxy
  if tp list 2>/dev/null | grep -q "$PROXY_NAME"; then
    # toxiproxy-cli exits non-zero when the toxic is absent; that is fine here.
    local removed=0
    if tp toxic remove -n "$TOXIC_NAME" "$PROXY_NAME" >/dev/null 2>&1; then
      say "  removed slowdown toxic '$TOXIC_NAME'"; removed=1
    fi
    if tp toxic remove -n "$FAIL_TOXIC_NAME" "$PROXY_NAME" >/dev/null 2>&1; then
      say "  removed failure toxic '$FAIL_TOXIC_NAME'"; removed=1
    fi
    [ "$removed" = 0 ] && say "  no injected toxic to remove on '$PROXY_NAME'"
    return 0
  else
    die "proxy '$PROXY_NAME' not found on the toxiproxy container"
  fi
}

# Ensure the permanent baseline latency is present and at the right value.
# Idempotent: adds it if missing, replaces it if the value differs.
ensure_baseline_latency() {
  need_container toxiproxy
  local jitter=$(( BASELINE_LATENCY_MS / 4 ))
  tp toxic remove -n "$BASELINE_TOXIC_NAME" "$PROXY_NAME" >/dev/null 2>&1 || true
  tp toxic add -n "$BASELINE_TOXIC_NAME" -t latency \
      -a "latency=${BASELINE_LATENCY_MS}" -a "jitter=${jitter}" "$PROXY_NAME" >/dev/null \
    || die "failed to apply the baseline latency toxic"
  say "  baseline latency: ${BASELINE_LATENCY_MS}ms +/- ${jitter}ms on payment -> MySQL"
}

toxic_set_latency() {
  local ms="$1" jitter="$2"
  need_container toxiproxy
  tp toxic remove -n "$TOXIC_NAME" "$PROXY_NAME" >/dev/null 2>&1 || true
  tp toxic add -n "$TOXIC_NAME" -t latency \
      -a "latency=${ms}" -a "jitter=${jitter}" "$PROXY_NAME" >/dev/null \
    || die "failed to add latency toxic"
}

# ------------------------------------------------------------- commands -----

cmd_status() {
  say "STATUS"
  echo
  echo "  Feature flags (src/flagd/demo.flagd.json):"
  local any_on=0
  for f in "${ALL_FLAGS[@]}"; do
    local v; v="$(flag_get "$f")"
    if [ "$v" = "off" ]; then
      printf '    %-28s %s\n' "$f" "$v"
    else
      printf '    %-28s %s   <== ON\n' "$f" "$v"
      any_on=1
    fi
  done
  [ "$any_on" = 0 ] && echo "    -> baseline: every flag is off"
  echo
  echo "  Toxiproxy (payment -> MySQL):"
  if docker inspect toxiproxy >/dev/null 2>&1 \
     && [ "$(docker inspect -f '{{.State.Status}}' toxiproxy)" = "running" ]; then
    # `toxiproxy-cli list` prints: name, listen, upstream, enabled, toxic-count.
    # The image has no shell, so the CLI is the only thing available in there.
    local row; row="$(tp list 2>/dev/null | grep "$PROXY_NAME" || true)"
    if [ -z "$row" ]; then
      echo "    proxy '$PROXY_NAME' is missing"
    else
      local listen upstream count
      listen="$(echo "$row"   | awk '{print $2}')"
      upstream="$(echo "$row" | awk '{print $3}')"
      count="$(echo "$row"    | awk '{print $NF}')"
      printf '    proxy %s: %s -> %s\n' "$PROXY_NAME" "$listen" "$upstream"
      # One toxic is the permanent baseline link latency, which is the NORMAL
      # state. Two or more means an injected slowdown is on top of it.
      # toxiproxy-cli has no `toxic list`, and the image has no shell to reach
      # the HTTP API, so the count is the only signal available here.
      case "$count" in
        0) printf '    no toxics  <== BASELINE LATENCY MISSING, run ./demo.sh reset\n' ;;
        1) printf '    1 toxic: baseline %sms link latency -> normal\n' "$BASELINE_LATENCY_MS" ;;
        *) printf '    %s toxics: baseline + injected fault  <== FAULT INJECTED\n' "$count" ;;
      esac
    fi
  else
    echo "    toxiproxy container is not running"
  fi
  echo
  echo "  Containers:"
  docker compose --env-file .env --env-file .env.arm64 --env-file .env.override \
    -f docker-compose.yml -f docker-compose.trim.yml ps \
    --format '{{.Service}}|{{.State}}|{{.Status}}' 2>/dev/null \
    | sort \
    | while IFS='|' read -r svc state st; do
        local r; r="$(docker inspect -f '{{.RestartCount}}' "$svc" 2>/dev/null || echo '?')"
        if [ "$state" = "running" ] && [ "$r" = "0" ]; then
          printf '    %-18s %s\n' "$svc" "$st"
        else
          printf '    %-18s %s   <== restarts=%s\n' "$svc" "$st" "$r"
        fi
      done
}

cmd_baseline() {
  say "BASELINE - flags off, injected slowdown removed, baseline latency applied"
  flags_all_off
  toxic_clear
  ensure_baseline_latency
  say "BASELINE applied. flagd picks up flag changes within a few seconds."
  say "  Note: baseline is NOT zero latency. The ${BASELINE_LATENCY_MS}ms link"
  say "  latency is deliberate and stays on - it is the normal state, not a fault."
}

cmd_slow_db() {
  local ms="${1:-$DEFAULT_LATENCY_MS}"
  case "$ms" in (*[!0-9]*|'') die "latency must be a whole number of milliseconds, got '$ms'";; esac
  [ "$ms" -gt 0 ] || die "latency must be greater than 0"
  local jitter=$(( ms / 8 ))
  toxic_set_latency "$ms" "$jitter"
  say "SLOW-DB applied: ${ms}ms +/- ${jitter}ms on payment -> MySQL ('$PROXY_NAME')"
  say "  quote connects to MySQL directly and is NOT affected."
  say "  Expect payment DB spans, then payment, checkout and frontend to slow"
  say "  within about two minutes. Undo with: ./demo.sh reset"
}

cmd_slow_db_ramp() {
  local target="${1:-$DEFAULT_LATENCY_MS}"
  case "$target" in (*[!0-9]*|'') die "latency must be a whole number of milliseconds, got '$target'";; esac
  local step_delay=$(( RAMP_SECONDS / RAMP_STEPS ))
  say "SLOW-DB-RAMP starting: 0 -> ${target}ms over ${RAMP_SECONDS}s in ${RAMP_STEPS} steps"
  for i in $(seq 1 "$RAMP_STEPS"); do
    local ms=$(( target * i / RAMP_STEPS ))
    local jitter=$(( ms / 8 ))
    toxic_set_latency "$ms" "$jitter"
    say "  step ${i}/${RAMP_STEPS}: ${ms}ms +/- ${jitter}ms"
    [ "$i" -lt "$RAMP_STEPS" ] && sleep "$step_delay"
  done
  say "SLOW-DB-RAMP complete: holding at ${target}ms. Undo with: ./demo.sh reset"
}

# Makes a measured share of payment's DATABASE CALLS genuinely time out.
#
# Two halves. payment gives every charge query a deadline
# (PAYMENT_QUERY_TIMEOUT_MS, 2000ms), and this adds a jittery latency toxic on
# the payment -> MySQL link. Toxiproxy draws each delay uniformly from
# [latency-jitter, latency+jitter], so the deadline cuts that distribution at a
# chosen point and the failure share is arithmetic:
#
#     P(timeout) = (latency + jitter - timeout) / (2 * jitter)
#
# No flagd. Unlike the paymentDatabaseError flag this fails INSIDE the database
# client, so the mysql2 instrumentation produces a DB client span that ends in
# error - real database-side evidence rather than an error thrown before the
# query. slow-db is unaffected: it tops out at 904ms, well under the deadline.
cmd_fail_db() {
  local latency="${1:-$FAIL_LATENCY_MS}"
  case "$latency" in (*[!0-9]*|'') die "latency must be a whole number of ms, got '$latency'";; esac
  need_container toxiproxy

  local timeout_ms
  timeout_ms="$(docker exec payment sh -c 'echo "${PAYMENT_QUERY_TIMEOUT_MS:-0}"' 2>/dev/null | tr -d '\r')"
  if [ -z "$timeout_ms" ] || [ "$timeout_ms" = "0" ]; then
    die "payment has no PAYMENT_QUERY_TIMEOUT_MS set, so nothing will time out.
       Recreate payment first: docker compose ... up -d --no-deps --force-recreate payment"
  fi

  tp toxic remove -n "$FAIL_TOXIC_NAME" "$PROXY_NAME" >/dev/null 2>&1 || true
  tp toxic add -n "$FAIL_TOXIC_NAME" -t latency \
      -a "latency=${latency}" -a "jitter=${FAIL_JITTER_MS}" "$PROXY_NAME" >/dev/null \
    || die "failed to add the fail-db latency toxic"

  local lo=$(( latency - FAIL_JITTER_MS ))
  local hi=$(( latency + FAIL_JITTER_MS ))
  local pct=0
  [ "$hi" -gt "$timeout_ms" ] && pct=$(( (hi - timeout_ms) * 100 / (2 * FAIL_JITTER_MS) ))

  say "FAIL-DB applied: ${latency}ms +/- ${FAIL_JITTER_MS}ms on payment -> MySQL"
  say "  query delay lands in ${lo}-${hi}ms against payment's ${timeout_ms}ms deadline"
  say "  expected failures: ~${pct}% by the naive model; MEASURED ~26% at the"
  say "  defaults, because each timeout forces a slow reconnect that makes"
  say "  others time out too. Re-measure if you change the latency."
  say "  Queries that do NOT time out still take ${lo}ms+, so payment and"
  say "  checkout latency rise as well - this both slows and fails."
  say "  Undo with: ./demo.sh reset"
}

cmd_flag() {
  local name="${1:-}" variant="${2:-}"
  [ -n "$name" ] && [ -n "$variant" ] || die "usage: ./demo.sh flag <name> <variant>"
  local before; before="$(flag_get "$name" 2>/dev/null || echo '?')"
  flag_set "$name" "$variant"
  say "FLAG $name: $before -> $variant"
  say "  flagd watches the file, so this takes effect within a few seconds."
}

# ------------------------------------------------------- bad deployment -----
#
# Redeploys payment with a different service.version and the N+1 code path on.
# Deliberately NOT a feature flag: the story is that someone shipped a bad
# build, so it has to look like a deployment - a new version appearing in the
# Service Catalogue, and a rollback that makes it go away.

payment_redeploy() {
  # $4 is optional and defaults to 0, so deploy-bad and rollback behave exactly
  # as before. Both N+1 variables are ALWAYS passed, so redeploying for one
  # scenario always clears the other - the two can never overlap.
  local version="$1" lookups="$2" label="$3" customer_lookups="${4:-0}"
  local envs=( --env-file "${REPO_DIR}/.env" )
  [ -f "${REPO_DIR}/.env.arm64" ]    && envs+=( --env-file "${REPO_DIR}/.env.arm64" )
  [ -f "${REPO_DIR}/.env.override" ] && envs+=( --env-file "${REPO_DIR}/.env.override" )

  PAYMENT_VERSION="$version" PAYMENT_ITEM_LOOKUPS="$lookups" \
  PAYMENT_CUSTOMER_LOOKUPS="$customer_lookups" \
    docker compose "${envs[@]}" \
      -f "${REPO_DIR}/docker-compose.yml" \
      -f "${REPO_DIR}/docker-compose.trim.yml" \
      up -d --no-deps --force-recreate payment >/dev/null 2>&1 \
    || die "failed to redeploy payment"

  say "$label"
  say "  payment is now service.version=${version}, PAYMENT_ITEM_LOOKUPS=${lookups}, PAYMENT_CUSTOMER_LOOKUPS=${customer_lookups}"
  say "  service.name stays 'payment', so the Service Catalogue sees one service"
  say "  with two versions - which is what makes the deployment visible."
}

# Applies ONLY the permanent baseline latency, nothing else. Split out from
# `baseline` so `make start` can re-establish it on a fresh stack without also
# rewriting the flagd file. `make stop` removes volumes and recreates
# toxiproxy, which wipes all toxics - the proxy is seeded from
# src/toxiproxy/toxiproxy.json but that format cannot express toxics, so
# without this the 4ms link latency silently disappears after every restart.
cmd_baseline_toxic() {
  say "BASELINE TOXIC"
  ensure_baseline_latency
}

# --------------------------------------------------------- change events ----
#
# Coworker does not link a Situation to a release on its own: service.version
# changing on the spans is not enough, it needs a deployment event. Two sinks,
# because they do two different jobs:
#
#   OTLP log   The evidence. Goes through the collector that is already
#              running, so it needs no credential of its own and works even
#              with no event source configured. service.name and
#              service.version are RESOURCE attributes so it correlates with
#              payment in the Service Catalogue.
#   webhook    The trigger. A Coworker "Generic Webhook" event source starts
#              an investigation on each event it receives. The URL embeds its
#              own token, so it is a SECRET: it lives only in .env.override
#              and is never printed. Unset means this sink is skipped, which
#              keeps the script working in an org that has no source yet.
#
# Both are best-effort with a 5s timeout and neither can fail the script. A
# deployment event failing to send must never break a live demo.
#
# The payload says only WHAT was deployed - service, version, previous
# version, environment, timestamp. It never says what is wrong with the
# build. Coworker has to do that work; an event that names the defect is just
# reading the answer out.

# Reads one key from .env.override without sourcing it. An already-exported
# variable of the same name wins, so the webhook URL can also be passed in the
# environment for a one-off.
env_override_get() {
  local key="$1" file="${REPO_DIR}/.env.override" val=''
  [ -f "$file" ] || { printf ''; return 0; }
  val="$(sed -n "s/^[[:space:]]*${key}=//p" "$file" | tail -1 || true)"
  val="$(printf '%s' "$val" | tr -d '\r' | sed 's/[[:space:]]*$//')"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

record_change_event() {
  local action="$1" version="$2" previous="$3" summary="$4"
  local env_name="${DEPLOYMENT_ENVIRONMENT:-webinar-demo}"
  local when nanos body rc hostport webhook
  when="$(ts)"
  nanos="$(date -u +%s)000000000"

  # --- sink 1: OTLP log record, via the collector already in the stack -----
  # The collector publishes 4318 on an EPHEMERAL host port that changes every
  # time the container is recreated, so it has to be resolved at run time
  # rather than hardcoded.
  hostport="$(docker port otel-collector 4318 2>/dev/null | head -1 || true)"
  hostport="${hostport##*:}"
  if [ -n "$hostport" ]; then
    body="$(mktemp)"
    cat > "$body" <<JSON
{"resourceLogs":[{"resource":{"attributes":[
  {"key":"service.name","value":{"stringValue":"payment"}},
  {"key":"service.namespace","value":{"stringValue":"opentelemetry-demo"}},
  {"key":"service.version","value":{"stringValue":"${version}"}},
  {"key":"deployment.environment","value":{"stringValue":"${env_name}"}}]},
 "scopeLogs":[{"scope":{"name":"demo.sh"},"logRecords":[{
  "timeUnixNano":"${nanos}","observedTimeUnixNano":"${nanos}",
  "severityNumber":9,"severityText":"INFO",
  "body":{"stringValue":"${summary}"},
  "attributes":[
    {"key":"event.name","value":{"stringValue":"deployment"}},
    {"key":"deployment.action","value":{"stringValue":"${action}"}},
    {"key":"deployment.version","value":{"stringValue":"${version}"}},
    {"key":"deployment.previous_version","value":{"stringValue":"${previous}"}},
    {"key":"deployment.environment","value":{"stringValue":"${env_name}"}},
    {"key":"deployment.timestamp","value":{"stringValue":"${when}"}},
    {"key":"service.name","value":{"stringValue":"payment"}}]}]}]}]}
JSON
    rc="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
            -X POST "http://127.0.0.1:${hostport}/v1/logs" \
            -H 'Content-Type: application/json' \
            --data @"$body" 2>/dev/null || true)"
    rm -f "$body"
    if [ "$rc" = "200" ]; then
      say "  deployment event -> OTLP log: sent"
    else
      say "  deployment event -> OTLP log: FAILED (HTTP ${rc:-no response})"
    fi
  else
    say "  deployment event -> OTLP log: skipped (otel-collector 4318 not published)"
  fi

  # --- sink 2: Coworker Generic Webhook event source -----------------------
  # Never print $webhook: the URL is the credential.
  webhook="${OPSPILOT_DEPLOY_WEBHOOK:-$(env_override_get OPSPILOT_DEPLOY_WEBHOOK)}"
  if [ -n "$webhook" ]; then
    body="$(mktemp)"
    cat > "$body" <<JSON
{"event":"deployment",
 "action":"${action}",
 "service":"payment",
 "version":"${version}",
 "previous_version":"${previous}",
 "environment":"${env_name}",
 "timestamp":"${when}",
 "summary":"${summary}"}
JSON
    rc="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
            -X POST "$webhook" \
            -H 'Content-Type: application/json' \
            --data @"$body" 2>/dev/null || true)"
    rm -f "$body"
    case "$rc" in
      2*) say "  deployment event -> Coworker webhook: sent (HTTP ${rc})" ;;
      *)  say "  deployment event -> Coworker webhook: FAILED (HTTP ${rc:-no response})" ;;
    esac
  else
    say "  deployment event -> Coworker webhook: skipped (OPSPILOT_DEPLOY_WEBHOOK unset)"
  fi
}

cmd_deploy_bad() {
  payment_redeploy "$BAD_VERSION" "$BAD_ITEM_LOOKUPS" \
    "DEPLOY-BAD: shipped payment ${BAD_VERSION}"
  record_change_event deploy "$BAD_VERSION" "$GOOD_VERSION" \
    "Deployed payment ${BAD_VERSION}"
  say "  Each charge now runs roughly 87-157 cheap queries instead of one INSERT."
  say "  Expect DB spans per charge to jump, then payment latency, then checkout."
  say "  MySQL CPU rises but stays safe: every query is a primary-key hit on a"
  say "  50-row table. Undo with: ./demo.sh rollback"
}

cmd_deploy_bad_v2() {
  payment_redeploy "$BAD2_VERSION" "0" \
    "DEPLOY-BAD-V2: shipped payment ${BAD2_VERSION}" "$BAD2_CUSTOMER_LOOKUPS"
  record_change_event deploy "$BAD2_VERSION" "$GOOD_VERSION" \
    "Deployed payment ${BAD2_VERSION}"
  say "  Each charge now resolves the owning customer for every basket item:"
  say "  roughly 81-151 joins across quotes and customers instead of one INSERT."
  say "  A DIFFERENT table and statement from ${BAD_VERSION}, so it should read as"
  say "  a new problem. Undo with: ./demo.sh rollback"
}

cmd_rollback() {
  # Report the version actually being replaced, not a hardcoded one, so the
  # rollback event is correct whichever bad release is live.
  local prev
  prev="$(docker inspect payment --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
          | sed -n 's/.*service\.version=\([^,]*\).*/\1/p' | head -1)"
  [ -n "$prev" ] || prev="$BAD_VERSION"

  payment_redeploy "$GOOD_VERSION" "0" \
    "ROLLBACK: payment ${prev} -> ${GOOD_VERSION}"
  record_change_event rollback "$GOOD_VERSION" "$prev" \
    "Rolled back payment to ${GOOD_VERSION}"
  say "  Both N+1 paths are off. Latency should return to baseline within a minute."
}

usage() {
  awk 'NR>=5 && /^#/ {sub(/^# ?/, ""); print; next} NR>=5 {exit}' "${BASH_SOURCE[0]}"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    status)       cmd_status ;;
    baseline)     cmd_baseline ;;
    reset)        cmd_baseline ;;
    baseline-toxic) cmd_baseline_toxic ;;
    slow-db)      cmd_slow_db "${1:-}" ;;
    slow-db-ramp) cmd_slow_db_ramp "${1:-}" ;;
    flag)         cmd_flag "${1:-}" "${2:-}" ;;
    fail-db)      cmd_fail_db "${1:-}" ;;
    deploy-bad)   cmd_deploy_bad ;;
    deploy-bad-v2) cmd_deploy_bad_v2 ;;
    rollback)     cmd_rollback ;;
    ''|-h|--help|help) usage ;;
    *)            die "unknown command '$cmd'. Run ./demo.sh --help" ;;
  esac
}

main "$@"
