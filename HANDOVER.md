# Handover: `webinar-demo-updates`

Work done for the OpsPilot Coworker webinar (18/19 November 2026), prepared on a
local Mac deployment and squashed into one commit on top of `main`.

**Full detail for every change is in [`docs/CHANGES-FOR-FR-DEMO.md`](docs/CHANGES-FOR-FR-DEMO.md).**
That file is the authoritative record — each entry says what changed, why, what
was measured, and whether it is needed for the FR demo or local-only. This page
is only a summary of the things that need a decision before merging.

---

## 1. BREAKING: the collector now needs two new environment variables

`src/otel-collector/otelcol-config.yml` no longer hardcodes the OpsPilot
destination. It now reads:

```yaml
  otlphttp:
    endpoint: ${env:OPSPILOT_ENDPOINT}      # line 117
    headers:
      authorization: ${env:OPSPILOT_AUTH}   # line 119
```

**The collector refuses to start if either is unset.** On `main` these values
were literals in the committed config, so an FR demo deployment that merges this
branch without acting will fail to bring the collector up.

Two ways to fix, your call:

- **Set them in `.env.override`** (the file the `Makefile` already loads on
  every compose command). This is what the local deployment does, and it keeps
  org-specific values out of the repo.
- **Add defaults in `docker-compose.yml`**, e.g.
  `OPSPILOT_ENDPOINT=${OPSPILOT_ENDPOINT:-https://…}`, if you would rather the
  stack start out of the box with the previous behaviour.

Note `OPSPILOT_ENDPOINT` is the bare scheme and host with no path — the exporter
appends `/v1/traces`, `/v1/metrics` and `/v1/logs` itself. All three signals now
go through this single OTLP/HTTP exporter; logs moved off the Loki push path.

Also relevant: on `main` the `Makefile` loads `.env.override` unconditionally.
This branch makes that load **optional** (guarded by `wildcard`), so a missing
file now skips silently rather than failing the command. That is more permissive,
not less, but it does remove a loud failure you may have been relying on.

## 2. The FusionReactor agents now take `FR_LICENSE` and `FR_CLOUD_GROUP`

On `main` the FR agents are started with only
`-javaagent:…=name=…,address=8088 -agentpath:…` and no licence anywhere in the
repo. This branch adds, driven from the environment:

- `FR_LICENSE` → `-Dfrlicense=…`
- `FR_CLOUD_GROUP` → `-Dfr.cloud.group=…`
- `FR_LICENSE_ENDPOINT` / `FR_CLOUD_ENDPOINT` → defaulted automatically, only
  set them to point FR Cloud elsewhere
- `FR_AGENT_OPTS` → escape hatch for extra agent arguments

These apply to `ad`, `fraud-detection` and `quote`. All are optional: leave them
unset and the agents behave exactly as they do on `main`.

**`FR_CLOUD_GROUP` is org-specific** — it decides which FR Cloud group the data
lands in, so it must differ per deployment if you want the data separable.

**Service names are deliberately unchanged.** The FR agents report as
`otlp-ad-fr`, `otlp-fraud-detection-fr` and `quote-service-lucee` (the agent
ignores `OTEL_SERVICE_NAME` and uses its own `name=` argument). These were kept
as-is so the Service Catalogue does not split.

## 3. Decision needed: a committed MySQL password

The read-only monitoring user for the collector's `mysql` receiver has its
password hardcoded in **two committed places**:

- `src/quote-cf/sql/003_otel_monitor_user.sql:14` — `CREATE USER … IDENTIFIED BY '…'`
- `docker-compose.yml:974` — the default for `MYSQL_MONITOR_PASSWORD`

This value does not exist anywhere on `main`, so merging introduces a new
hardcoded credential. Mitigating factors: the user is read-only
(`PROCESS`, `REPLICATION CLIENT`, `SELECT`), the database is a local demo one,
the value is overridable from `.env.override`, and the repo already ships
demo passwords of the same kind in `docker-compose.yml`.

**Your call** whether to leave it, move it to an env-var-only value with no
committed default, or rotate it. Flagging it rather than deciding for you.

## 4. Decision needed: `Makefile` `TRIM` defaults to `1`

`Makefile:47` sets `TRIM ?= 1`, which makes the local-only trim overlay
(see §5) the **default** for `make start`. On a shared or remote deployment that
is probably wrong, because it:

- omits `jaeger`, `opensearch`, `prometheus` and `grafana`, and
- **binds ports 8080 and 10000 to `127.0.0.1` only**, which makes the demo UI
  unreachable from anywhere but the host itself.

**Recommend changing to `TRIM ?= 0`** before this is used on the FR demo, so the
default is the full upstream stack and local runs opt in with
`make start TRIM=1`. Left as-is here so the change is yours to make knowingly.

One other `Makefile` change: `make start` now calls `./demo.sh baseline-toxic`
(`Makefile:221`) to re-apply the permanent 4 ms payment → MySQL latency, because
toxics live only in the Toxiproxy container's memory and are wiped by every
recreate. It warns rather than fails if Toxiproxy is not reachable, so it is
safe on a deployment that does not run Toxiproxy at all.

## 5. Local-only files — inert unless you opt in

These exist for the Mac deployment and **do nothing unless something points at
them**. `.env` keeps the upstream defaults, so a plain merge changes no
behaviour here.

| File | Purpose | How it activates |
|---|---|---|
| `docker-compose.trim.yml` | Parks jaeger/opensearch/prometheus/grafana behind an off-by-default profile; binds 8080/10000 to loopback | Only when passed with `-f` — see §4, the `Makefile` currently does this by default |
| `.hostfs-stub/` | Empty directory used as a `HOST_FILESYSTEM` target, to stop Docker Desktop raising macOS privacy prompts for `~/Documents` etc. | Only if `HOST_FILESYSTEM` is set to it in `.env.override` |
| `src/otel-collector/otelcol-config-extras.local.yml` | Drops the `hostmetrics` receiver, which cannot work on Docker Desktop without mounting the Mac's root filesystem | Only if `OTEL_COLLECTOR_CONFIG_EXTRAS` points at it in `.env.override` |

The load generator was also raised from 5 to 20 users locally, but that lives
only in `.env.override` and is not committed. It is worth considering for the FR
demo — at 5 users there were too few payment spans for a meaningful p95.

## 6. Demo scenarios

`./demo.sh` is the control script. Every command prints what it did with a UTC
timestamp, and `./demo.sh --help` lists them all.

| Command | Effect |
|---|---|
| `status` | Current flags, toxics and container health |
| `baseline` / `reset` | All flags off, injected toxics removed, 4 ms baseline latency applied |
| `baseline-toxic` | Re-apply only the 4 ms link latency |
| `slow-db [ms]` | Latency on the payment → MySQL connection |
| `slow-db-ramp` | Ramp that latency up over 5 minutes |
| `fail-db [ms]` | Genuine DB timeouts (~26%) with database-side error spans |
| `deploy-bad` | "Ship" payment 2.0.3 with an N+1 on `services` |
| `deploy-bad-v2` | "Ship" payment 2.1.0 with a different N+1 on `quotes JOIN customers` |
| `rollback` | Back to payment 2.0.2, both N+1 paths off |
| `flag <name> <variant>` | Toggle one of the built-in flagd faults |

Supporting pieces:

- **Toxiproxy** (`src/toxiproxy/toxiproxy.json`, `toxiproxy` service) sits
  between `payment` and MySQL only, under the network alias `payment-db`, so a
  database slowdown never touches the ColdFusion `quote` service. Its control
  API is deliberately **not** published; `demo.sh` reaches it with `docker exec`.
  The seed file can only express proxies, not toxics — hence the `make start`
  hook in §4.
- **`deploy-bad` / `deploy-bad-v2`** are real redeploys with a changed
  `service.version`, not feature flags, so they look like deployments in the
  Service Catalogue. Both are inert by default
  (`PAYMENT_ITEM_LOOKUPS` / `PAYMENT_CUSTOMER_LOOKUPS` default to `0`) and
  mutually exclusive.
- **`stock-reconciler`** is a scheduled batch job behind the `scenarios`
  compose profile, so it **does not start** unless you pass
  `--profile scenarios`. It only ever reads, every statement is a bounded
  aggregate with its own `max_execution_time`, and each run aborts at
  `RECONCILE_MAX_SECONDS`.
- **Deployment events**: `deploy-bad`, `deploy-bad-v2` and `rollback` record a
  change event so Coworker can link a Situation to a release. Two sinks, both
  best-effort and neither able to fail the script — an OTLP log through the
  collector (no extra credential), and a Coworker Generic Webhook if
  `OPSPILOT_DEPLOY_WEBHOOK` is set. Unset means that sink is skipped.

Alert rules live in [`alerts/`](alerts/) with a README on the exact values to
enter. They are **not** importable — OpsPilot has no rules import API, so they
have to be typed into the UI.

## 7. Things that are not in the repo

Some setup is UI-only and has to be repeated in each OpsPilot org. See
**"Manual OpsPilot UI steps"** in `docs/CHANGES-FOR-FR-DEMO.md`:

1. Create the three alert rules.
2. **Subscribe Coworker to them** — this adds the `opspilot_coworker=true`
   label that the notification policy routes on. Without it the rules fire
   correctly and Coworker never sees them, with nothing in the alert looking
   wrong. This is the easiest step to miss.
3. Create a Generic Webhook event source for deployment events.

## 8. Kubernetes

`kubernetes/opentelemetry-demo.yaml` is untouched by this branch. Anything
compose-specific here needs an equivalent if the FR demo runs on Kubernetes —
in particular Toxiproxy, `demo.sh`, and the `make start` hook that re-applies
the baseline toxic (a Job or initContainer running `toxiproxy-cli`). The
per-change notes in `docs/CHANGES-FOR-FR-DEMO.md` call these out individually.
