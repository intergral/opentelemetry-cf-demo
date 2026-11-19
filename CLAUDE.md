# OpsPilot Webinar Demo — local clone of the CF/OTel demo

## Purpose

This repo is Intergral's fork of the OpenTelemetry demo (Astronomy Shop) with a ColdFusion service added (`quote` on Lucee) and a MySQL-backed `payment` service. The repo also contains `report-cf` (Adobe CF 2025); **it is being removed for the webinar** (see Step 0). It normally ships to the shared "FusionReactor demo" OpsPilot org.

For the Coworker webinar (18/19 November 2026) it runs **locally on Emmett's machine** and ships all telemetry to his **EmmettDev** OpsPilot org instead. The webinar shows Coworker investigating a controlled downstream slowdown and producing an evidence-backed Situation.

**This local setup is the proving ground.** Once everything works here, the same changes will be applied to the FR demo deployment, and Dave will run the webinar on the FR demo account. Everything built here must therefore be portable (see "Portability").

Goal of this work: **a healthy, quiet baseline + one controlled, resettable database slowdown + clean telemetry in EmmettDev.** Prefer small, reversible changes to the existing repo over new code.

## Hard rules

- **Never print, log, echo or commit credentials.** This repo currently has live credentials hardcoded (see "Credentials" below). Refer to them by file and line, never by value.
- Telemetry must go **only** to EmmettDev. Nothing may still point at the FusionReactor demo org when we're done.
- **ColdFusion stays in the background.** The `quote` service keeps running, but the injected fault must not be on a CF service, and nothing we add should make CF the focus.
- Don't refactor or "improve" demo services beyond what's listed here. Ask before touching anything else.
- Explain any change to service names, resource attributes or telemetry structure before making it — OpsPilot's Service Catalogue history depends on them staying stable once data starts flowing.
- **The three FusionReactor services report under their FR instance names** — `otlp-ad-fr`, `otlp-fraud-detection-fr` and `quote-service-lucee` — not `ad`, `fraud-detection` and `quote`. The FR agent ignores `OTEL_SERVICE_NAME` and uses its own `name=` argument. Decided: keep the FR names, because they match the FR demo org. Do not rename them in FR Cloud or in the collector.

## Step 0 — Remove `report-cf`

- Remove the `report-cf` service from `docker-compose.yml`, along with the `fusionreactor-data` volume if nothing else uses it, and `REPORT_CF_*` entries in `.env`.
- The `src/report-cf/` folder has already been deleted, so `docker compose up` will fail until the service block is removed. Do this first.
- Check nothing else depends on it (other services, scripts, `Makefile`, tests).

## Step 1 — Map and report (no changes)

Before changing anything, confirm and report back:

1. Every place an export destination or credential is configured: `src/otel-collector/otelcol-config.yml` exporters, `otelcol-config-extras.yml`, FusionReactor config (`src/quote-cf/fusionreactor-conf/`, FR args in the `ad`, `fraud-detection` and `quote-cf` Dockerfiles), `.env`, anything else.
2. How each FusionReactor-instrumented service (`ad`, `fraud-detection`, `quote`) gets its data into OpsPilot — via the OTel collector, or directly to FR Cloud. Emmett will decide what to do with each.

   **Decided:** change nothing. The FR demo org shows live `fraud-detection` JVM memory data, so the FR 2026.1 snapshot agent is understood to export OTLP using the `OTEL_*` environment variables. Leave those variables in place on `ad` and `fraud-detection`, do not restore the OTel Java agent, and verify in Step 2 by looking for `ad`, `fraud-detection` and `quote` in the collector debug output. Note that `quote` has no `OTEL_*` variables at all, so if that is the mechanism, `quote` is the one to watch.
3. The host machine's CPU architecture and available Docker memory.
4. Total memory limits across all services vs available Docker memory.

## Step 2 — Retarget telemetry to EmmettDev

- Replace the hardcoded `authorization` headers and endpoints on the `otlphttp`, `otlphttp/prometheus` and `loki` exporters with environment variables, e.g. `${env:OPSPILOT_ENDPOINT}` and `${env:OPSPILOT_AUTH}`, passed into the `otel-collector` container.
- Put the EmmettDev values in `.env.override` — already gitignored and already the file the `Makefile` loads last, so its values win over `.env`. Provide `.env.override.example` with placeholder values only. Emmett fills in the real values himself. Never edit `.env`: everything local goes in `.env.override`, including the blanked `BUGSNAG_*` keys.
- Handle FR agents per Emmett's decision from Step 1. Anything that would report to the FR demo org's FR Cloud group must be disabled or repointed.
- Add `deployment.environment=webinar-demo` to `OTEL_RESOURCE_ATTRIBUTES`.
- Once Emmett confirms `.env.override` is filled in, build and start the stack with `make build && make start` (or `make start-build`). Use the `Makefile`, not a bare `docker compose` command: on this arm64 Mac it is the only thing that adds `--env-file .env.arm64` and `--build-arg=_JAVA_OPTIONS=-XX:UseSVE=0`, both of which the Java services need (JDK-8345296). It also appends `--env-file .env.override` when that file exists and applies the local-only trim overlay. Check every container is running and healthy, and fix any that aren't before moving on.
- Verify in the collector debug output that traces, metrics and logs are being exported, and that nothing errors with auth failures. Ask Emmett to confirm data is arriving in EmmettDev.

## Step 3 — Quiet baseline (critical)

The webinar story is "a previously healthy application starts slowing down". Right now `src/flagd/demo.flagd.json` has most failure flags **on by default**, which is why the shared demo org is full of Situations:

| Flag | Current default | Baseline value |
|---|---|---|
| productCatalogFailure | on | off |
| adManualGc | on | off |
| adHighCpu | on | off |
| adFailure | on | off |
| kafkaQueueProblems | on | off |
| cartFailure | on | off |
| paymentFailure | 25% | off |
| paymentDatabaseError | 15% | off |
| imageSlowLoad | 5sec | off |
| recommendationCacheFailure | off | off |
| paymentUnreachable | off | off |
| loadGeneratorFloodHomepage | off | off |

- Set every flag's `defaultVariant` to `off` for the baseline. Keep the flags themselves — don't delete variants.
- Confirm after a few hours that error rates are near zero and latency is steady across all services.

## Step 4 — Controlled database slowdown

**Path:** `frontend → checkout → payment → MySQL` (`payment` writes to `payment_transactions` via `mysql2`; Node auto-instrumentation produces the DB client spans).

MySQL is **shared** with the Lucee `quote` service, so slowing MySQL itself would also slow `quote` and pull them into the story. The slowdown must affect **only the payment → MySQL connection.**

Implement with **Toxiproxy**:
- Add a `toxiproxy` service; point `payment`'s `MYSQL_HOST`/`MYSQL_PORT` at the proxy, which forwards to `mysql:3306`. `quote` keeps connecting to MySQL directly.
- Do not expose the Toxiproxy control API outside the Docker network except to `demo.sh`.

Note the existing `paymentDatabaseError` flag injects **errors** and returns before touching the database, so it produces no real DB evidence. Don't use it for the centrepiece.

Also add the collector's `mysql` receiver (a read-only monitoring user, credentials from `.env.override`) so OpsPilot gets database-side metrics alongside the client spans.

## Step 5 — `demo.sh` control script

Every command prints what it did and the UTC timestamp.

| Command | Effect |
|---|---|
| `./demo.sh status` | Current flags, current toxics, container health |
| `./demo.sh baseline` | All flags off, all toxics removed |
| `./demo.sh slow-db [ms]` | Add latency (default 800 ms ± jitter) on the payment → MySQL proxy |
| `./demo.sh slow-db-ramp` | Ramp the latency from 0 to 800 ms over 5 minutes |
| `./demo.sh flag <name> <variant>` | Turn one existing flagd fault on or off (e.g. `./demo.sh flag kafkaQueueProblems on`), for reintroducing the demo's built-in issues |
| `./demo.sh reset` | Same as `baseline`; safe to run any time, idempotent |

Changing flags at runtime should go through flagd (it watches `demo.flagd.json`) rather than restarting containers.

## Step 6 — Alert rules

Coworker investigates when a subscribed alert rule fires, so EmmettDev needs a small set of rules. Write them as code in `alerts/` with a README on how to load them into OpsPilot (Emmett confirms the format).

| Rule | Starting condition (tune in rehearsal) | Purpose |
|---|---|---|
| Checkout latency | `checkout` p95 well above baseline for 2 min | Visible symptom |
| Payment latency | `payment` p95 well above baseline for 2 min | Intermediate symptom |
| Payment DB query time | `payment` MySQL client span p95 > 500 ms for 2 min | Closest to cause |

- Derive thresholds from the observed baseline, not guesses. No rule may fire during normal traffic.
- The three rules share grouping labels (e.g. `journey="checkout"`, `environment="webinar-demo"`) to give them the best chance of clustering into one investigation. Whether they do is a rehearsal question.
- Rule names and descriptions must be plain English and screen-ready.

## Step 7 — Trim local-only components — DONE (local only)

The collector exports only to OpsPilot, so `jaeger`, `opensearch`, `grafana` and `prometheus` received no demo telemetry at all — they only backed local UIs, cost ~2.7 GiB of memory limits and made every `up` wait on the opensearch health gate.

Done as a **local-only** change via `docker-compose.trim.yml`, an overlay that parks those four behind an off-by-default compose profile and drops the `depends_on` edges on `otel-collector` and `frontend-proxy` that would drag them back in. `docker-compose.yml` is untouched, so the FR demo deployment and `kubernetes/opentelemetry-demo.yaml` run exactly as before — they simply never pass `-f docker-compose.trim.yml`.

- `make start` → trimmed (22 services)
- `make start TRIM=0` → full upstream stack (26 services)
- While trimmed, `/jaeger/ui` and `/grafana/` return 503. Both Envoy clusters are `STRICT_DNS`, so Envoy still starts and the demo UI, load generator and flag UI are unaffected.

## Portability (changes must carry over to the FR demo deployment)

- Switching orgs must only mean changing values in `.env.override`. No org-specific values anywhere else.
- Keep every service name and resource attribute identical to the existing FR demo deployment, apart from the added `deployment.environment`, so the FR demo org's Service Catalogue isn't split or duplicated.
- Keep changes small and list them in `docs/CHANGES-FOR-FR-DEMO.md` as you go: each changed file, what changed and why, so they can be applied to the FR demo deployment (which may not run the same compose setup — `kubernetes/opentelemetry-demo.yaml` exists in this repo; note anything that would need a Kubernetes equivalent, such as Toxiproxy and `demo.sh`).
- Alert rules in `alerts/` must load into any org unchanged.

## Credentials currently hardcoded (do not reproduce values)

- `src/otel-collector/otelcol-config.yml`: authorization headers on all three exporters (FR demo org).
- `.env`: Bugsnag API keys.
- `docker-compose.yml`: MySQL and Lucee admin passwords (local-only demo values, low risk).

Move the collector credentials to the gitignored env file. Flag anything else found.

Done in Step 2: all three exporters now read `${env:OPSPILOT_ENDPOINT}` and `${env:OPSPILOT_AUTH}`. Note the committed header value was only 5 characters and identical on all three exporters, so one variable covers them. The old value remains in git history (commit `c6e558f`, pushed to `intergral/opentelemetry-cf-demo`) — Emmett is raising rotation with the org owner.

## Definition of done

1. `make build && make start` brings everything up on Emmett's machine.
2. All services visible in EmmettDev with correct names; nothing arriving in the FR demo org.
3. 24 hours of quiet baseline with no alert rule firing.
4. `./demo.sh slow-db` produces a visible slowdown in payment DB spans → payment → checkout → frontend within 2 minutes; `./demo.sh reset` returns to baseline within 60 s. Verified three times in a row.
5. `quote` healthy throughout the slowdown (proves the fault is scoped).
6. `docs/WEBINAR-RUNBOOK.md` covers start, verify, inject, reset and the rehearsal checklist.
