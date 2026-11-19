# Changes to carry over to the FR demo deployment

Running log of every change made on the `webinar-demo` branch, so it can be
replayed on the FusionReactor demo deployment. Newest step last.

Legend for **K8s**: whether `kubernetes/opentelemetry-demo.yaml` needs an
equivalent change, and what it would be.

---

## Step 0 — Remove the `report-cf` service

Commit: `51bf441`

| File | Change | Why |
|---|---|---|
| `docker-compose.yml` | Deleted the `report-cf` service block (Adobe CF 2025, `platform: linux/amd64`, host ports 8889 → 8500 and 8189 → 8088, 1.5 GiB limit). | `src/report-cf/` has already been deleted from the repo, so the build context no longer exists and `docker compose up` failed. |
| `docker-compose.yml` | Deleted the `fusionreactor-data` named volume. | `report-cf` was its only consumer. |
| `.env` | Deleted `REPORT_CF_PORT` and `REPORT_CF_DOCKERFILE` (and the section comment). | Only `report-cf` read them. |

Verification: `docker compose --env-file .env config` validates; 26 services
remain, `report-cf` is gone. No other file referenced `report-cf`,
`REPORT_CF_*` or `fusionreactor-data` (checked `docker-compose.minimal.yml`,
`docker-compose-tests.yml`, `kubernetes/`, `Makefile`, `test/`, `.github/` and
the Envoy config).

**K8s:** no change needed — `kubernetes/opentelemetry-demo.yaml` never contained
a `report-cf` workload.

**Side effects to be aware of on the FR demo deployment:**

- `report-cf` was the only `platform: linux/amd64` service in the compose file.
  After this change nothing in the stack is QEMU-emulated, which matters on
  Apple Silicon but not on an x86 host.
- A stale `report-cf` container (exited) and a
  `opentelemetry-cf-demo-report-cf:latest` image (1.29 GB) may still exist on
  any host that ran the old stack. They are not removed by this change.

---

## Step 2 (part 1) — Retarget telemetry to EmmettDev

Collector exporters are now env-driven. The stack has **not** been started yet —
`.env.override` is still to be filled in.

| File | Change | Why |
|---|---|---|
| `src/otel-collector/otelcol-config.yml` | The `otlphttp`, `otlphttp/prometheus` and `loki` exporters now read `${env:OPSPILOT_ENDPOINT}` and `${env:OPSPILOT_AUTH}` instead of a hardcoded endpoint and three hardcoded `authorization` headers. Metrics append `/otlp` and logs append `/loki/api/v1/push` to the base endpoint. | Switching OpsPilot orgs must only mean changing values in `.env.override`. The committed header value was 5 characters and identical on all three exporters, so one variable covers all three. |
| `docker-compose.yml` | Added `OPSPILOT_ENDPOINT` and `OPSPILOT_AUTH` to the `otel-collector` service's `environment`. | The collector needs them in its process environment; it refuses to start if either is unset, which is the behaviour we want. |
| `.env.override.example` | **New.** Placeholder template for the gitignored `.env.override`. | So anyone setting the stack up knows which values are needed without the real ones being committed. |
| `Makefile` | `.env.override` is now appended via `$(wildcard ...)` so it is optional; `.env` is the only unconditional env file. | Previously line 14 hardcoded `--env-file .env.override`, and because that file does not exist in a fresh checkout, **`make start` and `make build` failed outright**. This is a straight bug fix and applies everywhere. |

**Deliberately NOT changed:** the `OTEL_*` environment variables on `ad` and
`fraud-detection`, and the absence of an OTel Java agent on both (removed
upstream in `7974f1a`). The FR 2026.1 agent is understood to export OTLP using
those variables — the FR demo org shows live `fraud-detection` JVM memory data.
To be confirmed from the collector debug output on first start. Note `quote` has
no `OTEL_*` variables at all, so it is the one to watch.

**K8s:** `kubernetes/opentelemetry-demo.yaml` carries its own collector config
and will need the same exporter parameterisation, sourced from a Secret rather
than an env file. No Makefile or `.env.override` equivalent applies.

### Values that live in `.env.override`, not `.env`

`.env` is deliberately untouched. These overrides are applied locally:

| Variable | Local value | Portability |
|---|---|---|
| `OPSPILOT_ENDPOINT`, `OPSPILOT_AUTH` | EmmettDev | **Per-org. The only values that change between orgs.** |
| `OTEL_RESOURCE_ATTRIBUTES` | `.env` value plus `deployment.environment=webinar-demo` | **The FR demo deployment needs this too** — it is what the Step 6 alert rules group on. `service.namespace` and `service.version` are byte-identical to `.env` so the Service Catalogue does not split. |
| `HOST_FILESYSTEM` | `./.hostfs-stub` | **macOS only.** Linux keeps the upstream `/`. See the next section. |
| `BUGSNAG_API_KEY`, `BUGSNAG_EMAIL_API_KEY`, `BUGSNAG_PAYMENT_API_KEY` | empty | Webinar-local. Stops `email`, `payment` and `quote` shipping errors to Bugsnag during the demo. Both call sites skip Bugsnag init on an empty key. |

---

## macOS privacy prompts — `HOST_FILESYSTEM` stub (LOCAL ONLY)

| File | Change |
|---|---|
| `.hostfs-stub/.gitkeep` | **New.** An intentionally empty directory, with the explanation in the `.gitkeep` itself. |
| `.env.override.example` | Sets `HOST_FILESYSTEM=./.hostfs-stub`. |

Upstream mounts the host root at `/hostfs` (`docker-compose.yml`, `HOST_FILESYSTEM=/`
in `.env`) for the `hostmetrics` receiver, which has `root_path: /hostfs` and runs
the `filesystem`, `disk`, `processes` and `process` scrapers as root. On macOS
that walk reaches TCC-protected locations (`~/Documents`, `~/Desktop`,
`~/Downloads`) and Docker Desktop raises privacy prompts. Pointing the mount at
an empty directory stops that; the cpu/memory/load/network/paging scrapers are
unaffected because they read `/proc`, not `/hostfs`.

**K8s / FR demo:** no change. On Linux there is no TCC, `HOST_FILESYSTEM=/` in
`.env` is still the default, and host metrics stay complete. This is a value in
the local env file only.

---

## Step 7 — Trim jaeger, opensearch, prometheus, grafana (LOCAL ONLY)

| File | Change |
|---|---|
| `docker-compose.trim.yml` | **New** overlay. Adds `profiles: ["local-backends"]` to `jaeger`, `opensearch`, `prometheus` and `grafana`; clears `otel-collector`'s `depends_on` with `!reset`; re-declares `frontend-proxy`'s `depends_on` with `!override`, keeping `frontend`, `load-generator` and `flagd-ui` and dropping `jaeger` and `grafana`. |
| `Makefile` | `make start` applies the overlay by default (`TRIM=1`); `make start TRIM=0` runs the full upstream stack. |

Those four services receive **no demo telemetry at all** — the collector's only
exporters are the three OpsPilot ones plus `debug` and `spanmetrics`. They cost
2746 MiB of memory limits (jaeger 1200, opensearch 1126, prometheus 300,
grafana 120) and the `opensearch: service_healthy` gate delays every `up`.
Trimming takes the stack from 26 services / 10,960 MiB to 22 services / 8214 MiB.

The `depends_on` resets are required: Compose automatically enables the profiles
of anything a started service depends on, so profiles alone would pull all four
back in.

**K8s / FR demo: do not apply.** `docker-compose.yml` is untouched and the
overlay only takes effect when `-f docker-compose.trim.yml` is passed, which only
the local `Makefile` does. The FR demo deployment and
`kubernetes/opentelemetry-demo.yaml` keep running all four. If you later want the
same saving on the FR demo, it needs a separate decision and a Kubernetes
equivalent (delete the four Deployments and the collector's init dependencies).

Cost while trimmed: `http://localhost:8080/jaeger/ui` and `/grafana/` return 503.
Both Envoy clusters are `STRICT_DNS`, so Envoy starts regardless and the demo UI,
load generator and feature-flag UI are unaffected.

---

## CLAUDE.md

Updated to match the decisions above: `.env.local` → `.env.override` throughout,
the Step 2 start command is now `make build && make start`, Step 7 is recorded as
done and local-only, and the Step 1 FR-agent decision is written down so it is
not relitigated.

---

## Step 3 — Quiet baseline: all feature flags off

| File | Change | Why |
|---|---|---|
| `src/flagd/demo.flagd.json` | Every flag's `defaultVariant` set to `off`. 9 of the 12 changed: `productCatalogFailure`, `adManualGc`, `adHighCpu`, `adFailure`, `kafkaQueueProblems`, `cartFailure` (`on` → `off`), `paymentFailure` (`25%` → `off`), `paymentDatabaseError` (`15%` → `off`), `imageSlowLoad` (`5sec` → `off`). | The webinar needs a previously-healthy application. These defaults are why the shared demo org is full of Situations. |

All variants are kept, so `./demo.sh flag <name> <variant>` can still turn any of
them back on at runtime without a restart — flagd watches the file.
`recommendationCacheFailure`, `paymentUnreachable` and `loadGeneratorFloodHomepage`
were already `off`.

**K8s: already correct.** `kubernetes/opentelemetry-demo.yaml` embeds its own copy
of the flag config and all 11 flags there are already `off` — it still matches
upstream. The faults-on defaults were a change made only to the compose
`demo.flagd.json` in this fork, so this step brings the two back into agreement
rather than diverging them.

**Applies to the FR demo deployment: yes**, if it runs the compose setup. This is
the change that quietens the shared org, so confirm with whoever relies on the FR
demo org having visible Situations before applying it there.

---

## Step 2 (part 2) — Collapse to a single OTLP/HTTP exporter

| File | Change | Why |
|---|---|---|
| `src/otel-collector/otelcol-config.yml` | Deleted the `otlphttp/prometheus` and `loki` exporters. All three pipelines now use one `otlphttp` exporter at `${env:OPSPILOT_ENDPOINT}` with `authorization: ${env:OPSPILOT_AUTH}`. | Matches OpsPilot's own collector documentation, and is the only path layout that works against both ingest hosts. |

Route layout before and after, confirmed by direct HTTP probes with a real key:

| Signal | Before | After |
|---|---|---|
| Traces | `/v1/traces` | `/v1/traces` (unchanged) |
| Metrics | endpoint + `/otlp` → `/otlp/v1/metrics` | `/v1/metrics` |
| Logs | `loki` exporter → `/loki/api/v1/push` | `/v1/logs` |

`/v1/traces`, `/v1/metrics` and `/v1/logs` all return success on **both**
`api.fusionreactor.io` and `data.production.streamhippo.io`, so this config is
portable across both. The old `/otlp` metrics prefix exists only on streamhippo
(`api.fusionreactor.io` returns 404), which is why the new layout is the portable
one. Both hosts return 401 without an `authorization` header and accept the raw
API key with no scheme prefix.

Note for anyone reading the old config: the committed `authorization` value was
the literal word `Basic` with no credential after it, which returns 401 from
streamhippo and 403 from api.fusionreactor.io. No secret was ever committed in
this file. Whatever the FR demo deployment authenticates with is injected
somewhere outside this repo.

### ⚠ Check after porting to the FR demo org: log search and labels

Logs now arrive as **OTLP** rather than Loki push. The signal itself is
unchanged — same records, same resource attributes, same service names — but
OpsPilot may index resource attributes into labels differently on the two
ingest paths. **After applying this to the FR demo deployment, verify in that
org that:**

- log search returns results for each service,
- the labels or facets you filter logs by still exist and still have the same
  names,
- any saved log queries, dashboards or alert rules that filter on a label still
  match.

If labels differ, the fix is a `transform` or `resource` processor on the logs
pipeline rather than reinstating the `loki` exporter — that exporter is
deprecated upstream and absent from collector releases after the pinned
0.125.0.

**K8s:** the same single-exporter change applies to the collector config
embedded in `kubernetes/opentelemetry-demo.yaml`, with the key coming from a
Secret rather than an env file.

---

## Build fixes found while first building the stack

Both of these are pre-existing problems in the repo, unrelated to any change
made for the webinar. Neither alters a service name, a resource attribute or any
runtime behaviour — they only affect whether `make build` completes.

### 1. NuGet audit breaks `accounting` and `cart` — APPLIES TO THE FR DEMO

| File | Change |
|---|---|
| `src/accounting/Directory.Build.props` | Added `<WarningsNotAsErrors>NU1901;NU1902;NU1903;NU1904</WarningsNotAsErrors>` to the Release `PropertyGroup`. |
| `src/cart/Directory.Build.props` | The same. |

Both projects set `NuGetAudit=true`, `NuGetAuditMode=all`, `NuGetAuditLevel=low`
and `TreatWarningsAsErrors=true` for Release. That combination means **any newly
published advisory against any transitive dependency fails the build**, with no
source change required. Advisories have since been published against packages
pulled in by the pinned `OpenTelemetry.AutoInstrumentation 1.11.0`, so
`dotnet restore` now fails:

```
error NU1903: Warning As Error: Package 'OpenTelemetry.Resources.Host' 1.11.0-beta.2
  has a known high severity vulnerability
error NU1902: ... OpenTelemetry.Api, OpenTelemetry.Exporter.OpenTelemetryProtocol,
  OpenTelemetry.Exporter.Zipkin, OpenTelemetry.Extensions.Propagators,
  OpenTelemetry.Resources.Azure
```

The audit still runs and still prints every advisory; it is just no longer
promoted to an error.

**The FR demo deployment needs this too, if it builds these two images from
source.** If it pulls prebuilt images it is unaffected. The proper long-term fix
is to bump `OpenTelemetry.AutoInstrumentation` and the transitive packages, which
is a real change to two services and a separate decision — this change
deliberately does not make it. Note the list of flagged advisories will grow over
time, so expect to revisit it.

**K8s:** not applicable — the manifests consume prebuilt images.

### 2. Build parallelism — LOCAL ONLY

| File | Change |
|---|---|
| `Makefile` | New `BUILD_PARALLEL` variable, default 3, which sets `COMPOSE_BAKE=false COMPOSE_PARALLEL_LIMIT=$(BUILD_PARALLEL)` on the `build` and `build-and-push` targets. `make build BUILD_PARALLEL=0` restores the previous behaviour. |

Building all 18 images at once makes each target open its own `cache_from`
registry connection. Docker Desktop rejects them with
`failed to configure registry cache importer: ... only one connection allowed`,
which cascades into `DeadlineExceeded` on one target and
`Canceled: context canceled while waiting for connections to become ready` on
nine others. `buildkitd.toml` caps OCI worker parallelism at 4 but does not limit
the cache importers.

**Do not carry this to the FR demo deployment** unless it hits the same limit —
a parallel limit of 3 slows the build down on a machine with headroom. It lives
in the `Makefile` rather than `.env.override` because `COMPOSE_BAKE` and
`COMPOSE_PARALLEL_LIMIT` are read from the `docker compose` process environment,
and `--env-file` only feeds interpolation and container environments.

---

## Startup fixes found on first run

### 3. `docker_stats` receiver rejected by Docker Engine 29 — APPLIES TO THE FR DEMO

| File | Change |
|---|---|
| `src/otel-collector/otelcol-config.yml` | Added `api_version: "1.40"` to the `docker_stats` receiver. |

The receiver defaults to Docker API version 1.25. Docker Engine 29 reports
`MinAPIVersion 1.40` and rejects it:

```
Failed to start component {"error": "Error response from daemon: client version 1.25
  is too old. Minimum supported API version is 1.40", "type": "Receiver", "id": "docker_stats"}
Error: cannot start pipelines: failed to start "docker_stats" receiver
```

This aborts **collector startup entirely** — not just the one receiver — so
nothing was exported at all and the container crash-looped (9 restarts before
the fix). `1.40` is the daemon's stated minimum and has been supported since
Docker 19.03, so it is safe on older hosts too.

**The FR demo deployment needs this whenever its Docker Engine reaches 29.** It
is a latent failure: the config works until the host's Docker is upgraded, then
the collector stops starting. Worth applying pre-emptively.

### 4. `payment` crash-loop from a blank Bugsnag key — APPLIES TO THE FR DEMO

| File | Change |
|---|---|
| `src/payment/index.js` | Only call `Bugsnag.start()` when `BUGSNAG_PAYMENT_API_KEY` is non-empty, and guard the `Bugsnag.notify()` call the same way. |

`Bugsnag.start({ apiKey: process.env.BUGSNAG_PAYMENT_API_KEY || '' })` throws
`Error: No Bugsnag API Key set` on an empty key, so blanking the key to stop
errors leaving the machine crash-looped the service (10 restarts). The guard
matches what `src/quote-cf/www/Application.cfc` already does for the Lucee
service, which is why `quote` tolerated a blank key and `payment` did not.

`src/email/email_server.rb` assigns `config.api_key` inside
`Bugsnag.configure` and does not throw, so `email` needs no change.

**Useful to the FR demo deployment regardless of the webinar** — it makes the
service tolerate an unset key instead of refusing to boot, which is the normal
expectation for optional error reporting.

### 5. hostmetrics receiver disabled — LOCAL ONLY

| File | Change |
|---|---|
| `src/otel-collector/otelcol-config-extras.local.yml` | **New.** Restates the metrics pipeline's receiver list without `hostmetrics`. |
| `.env.override` / `.env.override.example` | `OTEL_COLLECTOR_CONFIG_EXTRAS` points at that file. |

`hostmetrics` has `root_path: /hostfs`, and **every** scraper reads through
`root_path`, not just the filesystem one. Pointing `HOST_FILESYSTEM` at the
empty stub to silence the macOS privacy prompts therefore broke all of them:

```
Error scraping metrics {"id": "hostmetrics", "error": "open /hostfs/proc/diskstats: no such file or directory"}
Error scraping metrics {"id": "hostmetrics", "error": "invalid total memory: 0"}
```

(An earlier note in this document claimed the cpu/memory/load/network/paging
scrapers were unaffected because they read `/proc`. That was wrong — they read
`/hostfs/proc`.)

Host metrics are not recoverable on Docker Desktop without mounting the Mac's
root filesystem, and they would describe the Linux VM rather than the Mac
anyway. Per-container metrics still come from `docker_stats`.

**Do not apply to the FR demo deployment.** It runs on Linux where
`HOST_FILESYSTEM=/` works and host metrics are real and wanted. The mechanism is
deliberately an env-var swap: anything that does not set
`OTEL_COLLECTOR_CONFIG_EXTRAS` keeps the upstream `otelcol-config-extras.yml`
and the full metrics pipeline.

Note that collector config merging **replaces** lists rather than appending, which
is what lets the extras file drop a receiver. If a receiver is ever added to the
metrics pipeline upstream, this file must be updated to match or the new receiver
will be silently dropped locally.

---

## FusionReactor licence and cloud settings via `.env.override`

**Portability: the mechanism is portable, the values are per-org.** The
`docker-compose.yml` changes carry over to the FR demo deployment unchanged;
`FR_LICENSE` and especially `FR_CLOUD_GROUP` are per-org and live only in
`.env.override`.

| File | Change |
|---|---|
| `docker-compose.yml` | `ad` and `fraud-detection` now set `JAVA_TOOL_OPTIONS`, and `quote` sets `LUCEE_JAVA_OPTS`, overriding the values baked into their Dockerfiles. Each appends FR's licence and cloud settings **as JVM system properties**, plus `${FR_AGENT_OPTS:-}` on the agent option string as an escape hatch. |
| `.env.override.example` | Documents `FR_LICENSE`, `FR_CLOUD_GROUP`, `FR_AGENT_OPTS` and the two optional endpoint overrides. |

The properties, exactly as `report-cf` used them:

```
-Dfrlicense=${FR_LICENSE}
-Dfr.license.endpoint=${FR_LICENSE_ENDPOINT:-https://api.fusionreactor.io/licensing-api/}
-Dfr.cloud.group=${FR_CLOUD_GROUP}
-Dfr.cloud.endpoint=${FR_CLOUD_ENDPOINT:-https://api.fusionreactor.io}
```

The licence pair is gated on `FR_LICENSE` and the cloud pair on
`FR_CLOUD_GROUP`, so each appears only when its variable is set. The two
endpoints default to the values above and can be overridden from
`.env.override` if FR Cloud ever needs pointing at another region.

Why this is assembled in compose rather than the Dockerfiles: `JAVA_TOOL_OPTIONS`
is read by the JVM directly and never shell-expanded, so `-Dfrlicense=${FR_LICENSE}`
inside a Dockerfile `ENV` would reach the JVM as that literal string.
Interpolating in compose keeps the key in `.env.override` only.

Verified with `docker compose config` in four configurations:

| Variables set | Result |
|---|---|
| none | byte-identical to the Dockerfile values |
| `FR_LICENSE` only | licence + licence endpoint added, no cloud properties |
| `FR_LICENSE` + `FR_CLOUD_GROUP` | all four properties added |
| plus `FR_CLOUD_ENDPOINT`, `FR_AGENT_OPTS` | endpoint overridden, agent option appended |

`FR_AGENT_OPTS` is written `${FR_AGENT_OPTS:-}` so compose does not emit an
"variable is not set" warning on every invocation when it is unused.

### What `report-cf` did, for the record

`report-cf` configured FR through exactly these `-D` system properties. Its
`src/report-cf/` folder is deleted from this copy of the repo and was never in
git history, so it could not be read back — the property names above come from
Emmett.

Separately, the surviving `opentelemetry-cf-demo_fusionreactor-data` volume
shows `report-cf`'s FR agent had also registered a cloud **user**
(`<user>.cloud_user` in `conf/reactor.conf`) and had connected to
`wss://api.fusionreactor.io:443/cc-go/upgrade`. That is the agent's live Cloud
Connect channel, and it confirms FR telemetry reached OpsPilot **directly rather
than through the OTel collector** — which explains both the FR demo org showing
live `fraud-detection` JVM memory and this collector seeing nothing from `ad`,
`fraud-detection` or `quote`.

### Still outstanding

`ad`, `fraud-detection` and `quote` have **no persistent FR config volume**,
unlike `report-cf`, so anything FR writes to its own config is lost on rebuild.
Whether that matters depends on whether the `-D` properties alone are enough to
get the agents reporting into a group. If they are not, each of the three needs a
volume over its FR config directory, which is `/opt/fusionreactor/conf` for
`quote` but is not established for `ad` and `fraud-detection` — their jar sits in
`/usr/src/app` next to the application, so a volume there would hide the app.

---

## FR licence verified working — and why FR's OTLP export still does not reach the collector

With `FR_LICENSE` and `FR_CLOUD_GROUP=webinar-demo` set in `.env.override` and
`ad`, `fraud-detection` and `quote` recreated, **all three connect to FR Cloud**.
Evidence per service:

- live TLS connections to `api.fusionreactor.io` (`46.137.127.35:443`) — 3 on
  `ad`, 4 on `fraud-detection`, 11 on `quote`,
- `cloud-state.log` showing `CC F NASCENT OK` with an FRUID against
  `wss://api.fusionreactor.io:443/cc-go/upgrade`, the same shape as `report-cf`'s
  working entry,
- `heartbeat.log` ticking every 5 s and current to the second.

Incidentally, `api.fusionreactor.io` and `traefik.production.streamhippo.io`
resolve to the **same IP**, which confirms the two hostnames front one service.

### The OTLP export path is misconfigured — FINDING, NOT YET FIXED

FR 2026.1's observability SDK **does** build an OTLP exporter from the standard
`OTEL_*` environment variables, confirming that was the right reading of this
agent. But on `ad` and `fraud-detection` it logs, repeatedly:

```
WARNING OTLP exporter endpoint port is likely incorrect for protocol version "grpc".
  The endpoint http://otel-collector:4318 has port 4318.
```

`docker-compose.yml` sets `OTEL_EXPORTER_OTLP_ENDPOINT` to
`http://otel-collector:${OTEL_COLLECTOR_PORT_HTTP}` — port **4318**, the HTTP
port — while FR's SDK defaults to the **gRPC** protocol, whose port is 4317.
So the exporter is pointed at the wrong port for the protocol it is using and
cannot deliver. This is the concrete reason `ad` and `fraud-detection` never
appeared in the collector's debug output.

`quote` has **no `OTEL_*` variables at all**, so its SDK registers propagators
and then builds no exporter — it logs none of these warnings because there is
nothing to warn about.

Two possible fixes, **neither applied**, because either changes what telemetry
OpsPilot receives and so needs a decision:

1. Add `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` to `ad` and
   `fraud-detection` (keeps the existing 4318 endpoint), or
2. Point `OTEL_EXPORTER_OTLP_ENDPOINT` at `${OTEL_COLLECTOR_PORT_GRPC}` (4317).

For `quote`, the equivalent would be adding the `OTEL_*` variables it currently
lacks.

**Before doing either, settle whether it is wanted.** These three already report
to OpsPilot over the FR Cloud channel. Making them export OTLP into the collector
as well would send the same services down a second path and risk duplicate
services or double-counted metrics in the Service Catalogue.

### Snapshot-build bug affecting `quote` only

`quote` throws, once, during licence activation:

```
SEVERE java.lang.NullPointerException: Cannot invoke
  "...SdkComponent$SdkItemHolder.close()" because "previousSdkItems" is null
    at ...SdkComponent.restart(SdkComponent.java:470)
    at ...SdkComponent.newSessionReceived(SdkComponent.java:462)
    at ...ODLController.updateLicense(ODLController.java:483)
```

The licence session is received and applied, then restarting the observability
SDK with the new session hits the NPE. Only `quote` logs `newSessionReceived`,
so only `quote` hits it. It does not stop the cloud connection — `quote` holds
the most connections of the three and heartbeats normally — but it may leave its
observability SDK in a partly-initialised state. Worth reporting to whoever owns
the `fusionreactor.11635.a6257b7b.otel-metrics` build before the webinar, since
the FR demo deployment runs the same snapshot.

---

## OTLP export from the FR agents — FIXED. NEEDED BY THE FR DEMO DEPLOYMENT.

FR Cloud carries only the agent control channel; **all** FR telemetry (metrics,
logs, spans) goes through the agent's OTel exporters. Those exporters were
failing on every request with `ConnectionShutdownException`, confirmed on the FR
UI's Cloud status page, because the endpoint port and the protocol disagreed.

| File | Change | Why |
|---|---|---|
| `docker-compose.yml` | Added `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` to `ad` and `fraud-detection`. | Their `OTEL_EXPORTER_OTLP_ENDPOINT` is the collector's **HTTP** port 4318, but the FR agent's exporters default to the **grpc** protocol, whose port is 4317. Every export failed. |
| `docker-compose.yml` | Added `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE`, `OTEL_SERVICE_NAME=quote` and `OTEL_RESOURCE_ATTRIBUTES` to `quote`. | `quote` had **no** `OTEL_*` variables, so its exporters fell back to the SDK default of `localhost:4317` inside its own container, where nothing listens. It held no connection to the collector at all. |

`OTEL_RESOURCE_ATTRIBUTES` was added to `quote` so it carries
`deployment.environment=webinar-demo` like every other service — the Step 6 alert
rules group on it. `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` was added
so its metrics use the same temporality as the rest of the stack.

**Result, verified in the collector's debug output after recreating all three:**

| Appears as | Traces | Metrics | Logs |
|---|:--:|:--:|:--:|
| `otlp-ad-fr` | – | yes | – |
| `otlp-fraud-detection-fr` | – | yes | – |
| `quote-service-lucee` | yes | yes | yes |

Before the fix all three were absent from all three signals. The repeating
`OTLP exporter endpoint port is likely incorrect` warning is gone, no
`ConnectionShutdownException` remains in any of the three, and
`quote` now holds a live connection to the collector's OTLP port.

**This is the single highest-value change for the FR demo deployment** — without
it, the FR-instrumented services emit no telemetry into OpsPilot at all.

### ⚠ Open question: the FR agents report under their FR instance names

`OTEL_SERVICE_NAME` is **ignored** by the FR agent. It is set correctly in all
three containers (`ad`, `fraud-detection`, `quote`), but the resource attribute
that actually arrives is the FR agent's `name=` argument:

| Compose service | `OTEL_SERVICE_NAME` | `service.name` as received |
|---|---|---|
| `ad` | `ad` | `otlp-ad-fr` |
| `fraud-detection` | `fraud-detection` | `otlp-fraud-detection-fr` |
| `quote` | `quote` | `quote-service-lucee` |

So the intent of setting `OTEL_SERVICE_NAME=quote` — making the Lucee service
appear as `quote` alongside everything else — is **not** achieved. No duplication
is occurring: the OTel Java agent was removed from `ad` and `fraud-detection`
upstream, so each service appears exactly once, under its FR name.

**DECIDED: option 1 — keep the FR names.** `otlp-ad-fr`,
`otlp-fraud-detection-fr` and `quote-service-lucee` are what the FR demo org
already shows for these agents, and matching that org is what matters. Nothing is
renamed, in FR Cloud or in the collector. The three options were:

1. **Accept the FR names.** They are already what the FR demo org's FR Cloud
   shows for these agents, so Service Catalogue continuity may favour leaving
   them. The cost is that three services are named inconsistently with the other
   nineteen.
2. **Change the FR `name=` arguments** to `ad`, `fraud-detection` and `quote`.
   Consistent, but renames the servers in FR Cloud and splits existing Service
   Catalogue history in the FR demo org.
3. **Rename in the collector** with a `transform` or `resource` processor on the
   way through. Keeps FR Cloud untouched, but means the two systems disagree
   about what a service is called.

`OTEL_SERVICE_NAME` is left in place on all three regardless: it is harmless, it
documents the intent, and it will take effect if a future FR build honours it.

---

## Step 4 — Controlled database slowdown via Toxiproxy

**Portability: needs a Kubernetes equivalent.** The compose changes do not carry
over directly; see the note at the end.

| File | Change |
|---|---|
| `docker-compose.yml` | New `toxiproxy` service (32 MiB limit) with the network alias **`payment-db`**, proxying `0.0.0.0:3306` to `mysql:3306`. Healthcheck via `toxiproxy-cli list`. |
| `docker-compose.yml` | `payment`'s `MYSQL_HOST` changed from `mysql` to `payment-db`; added `depends_on: toxiproxy (service_healthy)`. |
| `src/toxiproxy/toxiproxy.json` | **New.** Seeds the `payment-mysql` proxy at startup, so the proxy exists before `demo.sh` ever runs. |

`quote` still has `mysql-host=mysql` and connects to MySQL directly, so the
slowdown cannot touch it. That is what keeps ColdFusion out of the story.

### Why the alias is `payment-db` and not `toxiproxy`

The hostname `payment` connects to appears as `server.address` on every
`mysql2` client span. Calling it `toxiproxy` would put the test apparatus on
screen during the webinar. `payment-db` reads as the thing it is.

**This does change a span attribute**: `server.address` on payment's DB client
spans goes from `mysql` to `payment-db`. No service name or resource attribute
changes, and `db.system`, `db.name` and the statement are untouched.

### Control API is not exposed

The control API on 8474 is **not** published to the host. `demo.sh` reaches it
with `docker exec toxiproxy /toxiproxy-cli`. Note the toxiproxy image has **no
shell**, so `/toxiproxy-cli` is the only usable entry point — any tooling must go
through it rather than `sh -c` or `curl`.

### MySQL receiver for database-side metrics

| File | Change |
|---|---|
| `src/otel-collector/otelcol-config.yml` | New `mysql` receiver pointing at `mysql:3306` (**not** through Toxiproxy, so the injected latency does not distort the database's own numbers), added to the metrics pipeline. |
| `src/otel-collector/otelcol-config-extras.local.yml` | `mysql` added to the local receiver list as well — that list **replaces** rather than merges, so omitting it would have silently dropped the receiver locally. |
| `docker-compose.yml` | `MYSQL_MONITOR_USER` / `MYSQL_MONITOR_PASSWORD` passed to the collector, defaulting to the values in the SQL script and overridable from `.env.override`. |
| `src/quote-cf/sql/003_otel_monitor_user.sql` | **New.** Creates `otel_monitor` with `PROCESS`, `REPLICATION CLIENT`, `SELECT` on `performance_schema.*` and `SELECT` on `quotes.*`. Read-only throughout. |

Two traps worth knowing when porting this:

1. **Do not set `database:` on the receiver.** It makes the receiver select that
   schema on connect, which fails with `Error 1044 Access denied to database`
   unless the monitoring user has rights on it. Omitting it gives server-wide
   metrics, which is what is wanted.
2. **The MySQL container has an anonymous volume at `/var/lib/mysql`** (from the
   image's own `VOLUME`), so the data directory survives `--force-recreate` and
   `/docker-entrypoint-initdb.d` scripts **do not re-run** on an existing
   deployment. The script above had to be applied by hand to the live database.
   On a fresh deployment it runs normally. The declared-but-unused `mysql-data`
   volume in `docker-compose.yml` suggests this was meant to be an explicit
   mount; it is left as found.

### Kubernetes equivalent still needed

`kubernetes/opentelemetry-demo.yaml` has no Toxiproxy. A port would need a
Toxiproxy Deployment, a Service named so the DNS name reads naturally for the
DB spans, `payment`'s `MYSQL_HOST` repointed at it, and a way to reach the
control API from wherever the demo is driven. `demo.sh` as written is
Docker-specific — every Toxiproxy call goes through `docker exec`.

---

## Step 5 — `demo.sh`

**Portability: local tooling.** Docker-specific; see the Kubernetes note above.

New executable `demo.sh` at the repo root. Every command prints what it did and
a UTC timestamp.

| Command | Effect |
|---|---|
| `./demo.sh status` | Flags, toxics and container health, with anything off-baseline marked |
| `./demo.sh baseline` | All flags off, all toxics removed |
| `./demo.sh slow-db [ms]` | Latency on payment → MySQL, default 800 ms ± 100 ms jitter |
| `./demo.sh slow-db-ramp [ms]` | Ramps 0 → target over 5 minutes in 10 steps |
| `./demo.sh flag <name> <variant>` | Sets one flagd flag's `defaultVariant` |
| `./demo.sh reset` | Same as `baseline`; idempotent |

Flag changes are written to `src/flagd/demo.flagd.json`, which flagd watches —
confirmed in flagd's logs, which log a `WRITE` event per change and reload
without any container restart.

Implementation notes for anyone editing it:

- `toxiproxy-cli` uses `urfave/cli`, which **stops parsing flags at the first
  positional argument**. `toxic add <proxy> -t latency` silently ignores the
  options and fails with `Required argument 'type' was empty`; the proxy name
  must come **last**.
- There is **no `toxic list` subcommand** (only `add`, `update`, `remove`), and
  `inspect` prints nothing useful here, so `status` parses the toxic count from
  the last column of `toxiproxy-cli list`.
- The subcommand is `toxic remove` (`delete` is an alias).

---

## Incident 2026-11-09: `quote` OOM wedged the whole checkout path — NEEDED BY THE FR DEMO

`quote` threw `java.lang.OutOfMemoryError: Java heap space` at 17:21:54 and
stopped serving. **The JVM did not die**, so the container stayed `running` with
`restarts=0` and nothing looked wrong for 16 hours. The failure propagated:

```
quote OOM -> quote stops answering :8888
  -> shipping blocks on GetQuote (20 ESTABLISHED sockets to quote:8888, no timeout)
    -> checkout's PlaceOrder stalls before the charge step
      -> payment receives nothing -> no payment spans
        -> payment disappears from the OpsPilot Service Catalogue
```

The visible symptom was "payment is missing from the Service Catalogue", three
hops from the actual fault. In 24 hours checkout logged 111 `PlaceOrder` starts
against 62 completions, and payment logged exactly 62 charges.

### Root cause: heap ceiling was a quarter of the container limit

`quote` set no `-Xmx`, so the JVM auto-sized at the default
`MaxRAMPercentage=25`: **768 MiB of heap inside a 3 GiB container**. It OOMed at
a quarter of the memory it had been given.

| File | Change |
|---|---|
| `docker-compose.yml` | Added `-XX:MaxRAMPercentage=75` to `quote`'s `LUCEE_JAVA_OPTS`. Heap ceiling goes from **768 MiB to 2304 MiB**, verified inside the container's own cgroup. |
| `docker-compose.yml` | Added `-XX:+ExitOnOutOfMemoryError`, so a future OOM kills the JVM instead of leaving it wedged. `restart: unless-stopped` was already set and now has something to act on. |
| `docker-compose.yml` | Added a healthcheck on `http://localhost:8888/health.cfm` (15 s interval, 5 retries, 90 s start period). |

The healthcheck does **not** restart anything in plain compose — only the
`ExitOnOutOfMemoryError` + `restart` pair does that. Its job is to make the real
state visible in `docker ps` and `./demo.sh status`, which is what was missing
when this went unnoticed.

**All three changes are wanted on the FR demo deployment.** The same Dockerfile
and the same 3 GiB limit are used there, so it carries the identical latent
fault.

### `report.cfm` is not implicated

`src/quote-cf/README.md` documents `/report.cfm` as deliberately generating an
OutOfMemory error, so it was the obvious suspect. It is not reachable from
anything that runs:

- the load generator's ColdFusion user (`src/load-generator/locustfile.py`) hits
  `emailquote.cfm` (weight 3), `updatequote.cfm` (2) and `removeoldquotes.cfm`
  (1) — **never `report.cfm`**,
- `test-quote-service.sh` does call it, but nothing invokes that script: it is
  not referenced by the `Makefile`, compose, CI or any other script.

Nothing was changed or disabled, because nothing is calling it.

### Still open

- **Why the heap filled is not established.** Two candidates. `removeoldquotes.cfm`
  is described in the load generator as "the expensive slow query endpoint" and is
  called continuously. Separately, quote's FR OTel exporters were enabled earlier
  the same afternoon — before that they pointed at `localhost:4317` and failed
  instantly, so nothing buffered; afterwards quote shipped traces, metrics **and**
  logs, including a `LogShipper`. The OOM first surfaced on FusionReactor threads,
  which is suggestive but not proof. Watch whether the heap climbs toward the new
  2304 MiB ceiling; if it does, the ceiling is a postponement, not a fix.
- **`shipping` has no timeout on its call to `quote`** and will park indefinitely
  — 20 hung sockets accumulated here. Deliberately left alone for now, but it
  means any quote stall silently takes out checkout and payment too. Worth fixing
  before the webinar, since it turns a contained fault into a total one.
- **The 24-hour quiet baseline has not run.** Roughly 16 of the 18 hours had a
  broken checkout path, so it must restart from scratch.

---

## `recommendation`: the DEEP agent polls a service that does not exist — NEEDED BY THE FR DEMO

Coworker flagged a **64% span error rate** on `recommendation`, from DNS
failures to a host called `deep`.

`src/recommendation/recommendation_server.py` called `deep.start()`
unconditionally, and `deep-agent` is in `requirements.txt` (added in commit
`efdc6b4`, "feat(deep): add deep to recommendation service"). The DEEP agent's
tracepoint poller connects to `DEEP_SERVICE_URL`, which defaults to
**`deep:43315`**:

```
DNS resolution failed for deep:43315: C-ares status is not ARES_SUCCESS
  qtype=A name=deep is_balancer=0: Domain name not found
```

**There is no `deep` service anywhere** — not in `docker-compose.yml`, not in
`docker-compose.minimal.yml`, not in `kubernetes/opentelemetry-demo.yaml`, not
in `.env`. The integration was added to the service but the backend it needs
never came with it.

The poller runs every 10 seconds, and OpenTelemetry's gRPC client
auto-instrumentation turns each failed poll into an **errored client span
attributed to `recommendation`**. Those failures vastly outnumbered real
recommendation traffic, which is where 64% came from. Measured before the fix:
**724 matching log lines in 30 minutes**.

### Why this could not be fixed by configuration alone

The agent exposes `DEEP_APP_ROOT`, `DEEP_IN_APP_EXCLUDE`, `DEEP_IN_APP_INCLUDE`,
`DEEP_LOGGING_CONF`, `DEEP_PLUGINS`, `DEEP_POLL_TIMER`,
`DEEP_RESOURCE_ATTRIBUTES`, `DEEP_SDK_VERSION`, `DEEP_SERVICE_AUTH_PROVIDER`,
`DEEP_SERVICE_NAME`, `DEEP_SERVICE_SECURE` and `DEEP_SERVICE_URL`. **None of
them disables the agent**, and `deep.start()` unconditionally creates the poll
timer.

`DEEP_POLL_TIMER` looked like a way to throttle it to near-zero, but it is
**broken in this version**: `os.getenv('DEEP_POLL_TIMER', 10)` returns a *string*
when the variable is set, and `RepeatedTimer._time` evaluates
`self.interval - ((time.time() - self.start_ts) % self.interval)`, which raises
`TypeError: unsupported operand type(s) for %: 'float' and 'str'` and kills the
timer thread. Verified directly in the container. Relying on that would be
relying on a bug.

Repointing `DEEP_SERVICE_URL` at a resolvable host does not help either — the
DNS error simply becomes a connection error, and the span is still errored.

### What was done

| File | Change |
|---|---|
| `src/recommendation/recommendation_server.py` | `deep.start()` is now guarded by `if os.environ.get("DEEP_ENABLED", "false")... == "true"`. Three lines plus a comment; the `import deep` and the `deep-agent` dependency are untouched. |
| `docker-compose.yml` | `DEEP_ENABLED=${DEEP_ENABLED:-false}` added to `recommendation`'s environment, so it is off by default and can be switched on from `.env.override` wherever a `deep` service exists. |

This is a code guard rather than pure configuration, because no configuration
flag exists. The behaviour is still driven entirely by config, and the default
is off.

**Service name and telemetry are unchanged**, verified after recreating:
`OTEL_SERVICE_NAME=recommendation`,
`OTEL_RESOURCE_ATTRIBUTES=service.namespace=opentelemetry-demo,service.version=2.0.2,deployment.environment=webinar-demo`,
OTLP connection to the collector still established, service serving requests
with trace context. **Deep-related errors since the fix: 0** (from 724 per 30
minutes).

### The FR demo deployment needs this too

It runs the same `recommendation` source and the same `requirements.txt`, and it
has no `deep` service either. It is therefore carrying the same continuous
errored-span stream and the same inflated error rate on `recommendation` right
now. If that deployment *does* have a DEEP backend somewhere, set
`DEEP_ENABLED=true` and `DEEP_SERVICE_URL` there instead.

Worth noting for the webinar: this is a second instance of the same pattern as
the `quote` OOM — a real, pre-existing fault in the demo stack that was
invisible until something looked at it properly.

---

## MySQL at ~400% CPU: `removeoldquotes.cfm` disabled in the load generator

### ⚠ NEEDS MIKEY'S SIGN-OFF BEFORE IT GOES TO THE FR DEMO DEPLOYMENT

This one change is **not** cleared for the FR demo. Everything else in this
section (the memory limits) is.

MySQL was pinned at ~400% CPU with four `quotes_user` queries aged 47, 46, 18
and 7 minutes, all `executing`, all from `quote`. All four were
`removeoldquotes.cfm`, which runs a deliberately pathological statement:

- a triple `CROSS JOIN` on `quotes` (`q1 × q2 × q3`),
- eight correlated subqueries that each `CROSS JOIN` again,
- `UUID()`, `RAND()` and `POWER()` evaluated per row to defeat caching,
- a column literally named `memory_hog_field`.

Measured from `performance_schema`: **2 executions, 3153 seconds total, ~26
minutes each, 6,990,919,446 rows examined.** Against a 281-row table.

Two things made it compound:

1. **Orphaned queries.** `LUCEE_REQUEST_TIMEOUT=300` makes Lucee abandon the
   HTTP request after 5 minutes, but that does **not** cancel the MySQL query,
   which keeps running server-side. The load generator called the endpoint
   every few minutes, so runaway queries accumulated without bound.
2. **Cubic growth.** `quotes` grows ~61 rows/day and is never pruned. At 281
   rows that is 21,952,000 combinations; it was 3,581,577 at 153 rows. Every
   doubling of the table makes it **8× worse**.

| File | Change |
|---|---|
| `src/load-generator/locustfile.py` | The `remove_old_quotes` task is commented out, with the full reasoning inline. Nothing else in the CF user class changes — `emailquote.cfm` and `updatequote.cfm` still run. |

Result: MySQL CPU went from **~400% to 0.77%**. Verified no `CF Remove Old
Quotes` endpoint appears in the locust stats after restarting the generator.

### The index is not missing — it is being disabled

`quotes` already has an index on `quote_date`. The query writes
`date(q1.quote_date) >= …`, and wrapping the column in a function makes it
unusable: `EXPLAIN` shows `possible_keys = NULL` for `q2`/`q3` with a full index
scan and hash join. Without the wrapper the same predicate plans as
`type=range, key=quote_date`. The column is **already `DATE`**, so `date()` is
pure waste.

Fixing that alone would not have been enough — the dominant cost is the cubic
cross join, not the index — so the query itself was left untouched. If it is
ever re-enabled it needs both the wrapper removed and a `LIMIT`.

### This is what OOMed `quote`

The result set is cubic and each row carries a large concatenated
`memory_hog_field` string. The MySQL JDBC driver buffers results client-side, so
quote's heap grows as rows arrive. The heap watch shows it pinned at the 2304
MiB ceiling for four consecutive minutes (10:14–10:17) while these queries ran,
and 2125 MiB again at 10:41. At the **old 768 MiB** heap a single execution blew
straight through it — which is the 2026-11-09 17:21 OOM.

So the earlier heap increase treated the symptom. Disabling this task removes
the cause. Note the two fixes are complementary, not alternatives: the larger
heap is still wanted, because it is what turns a future burst into a slow
request rather than a crash.

---

## Memory limits raised — APPLIES TO THE FR DEMO

| Service | Was | Now | Why |
|---|---|---|---|
| `ad` | 300M | **512M** | Sat at 82–86% and climbing after the FR OTel exporters were enabled. |
| `fraud-detection` | 300M | **512M** | Sat **pinned at 99.5%** of its limit for sustained periods. |
| `mysql` | 512M | **768M** | Was at 85%, and every other service depends on it. |

Both Java services also get **`-XX:MaxRAMPercentage=50`**. Without it the JVM
auto-sizes the heap at the 25% default, so raising the container limit would
have handed all the extra memory to native allocation and left the heap as
constrained as before.

Note the failure mode here differs from `quote`'s. Their heap ceiling sits far
*below* the container limit, so the risk was a **Docker OOM-kill of the whole
container**, not a JVM heap OOM — `ExitOnOutOfMemoryError` would not have helped,
the container would simply have died. Neither had been killed yet
(`OOMKilled: false`), so this is preventive.

The FR demo deployment runs the same images with the same limits and the same FR
exporters, so it carries the same exposure.

---

## `kafka` memory limit raised — APPLIES TO THE FR DEMO

| Service | Was | Now |
|---|---|---|
| `kafka` | 620M | **1G** |

It was sitting at ~95% of its limit (588 MiB of 620 MiB) — the same trajectory
`fraud-detection` was on before it reached 99.5%. Raised ahead of the 24-hour
baseline specifically so it does not have to be restarted mid-run.

`KAFKA_HEAP_OPTS=-Xmx400m -Xms400m` is **deliberately unchanged**: the heap is
already pinned at 400 MiB, so the pressure is non-heap (metaspace, native
allocation, the OTel agent). The extra headroom goes exactly where it was
needed. After recreating: 534 MiB of 1 GiB, 52%.

This is the fourth service in the same pattern — `ad`, `fraud-detection`,
`mysql` and now `kafka` were all sized before the FR OTel exporters were
enabled and before this stack ran continuously for days. The FR demo deployment
runs the same images with the same limits, so it carries the same exposure.

### Deliberately NOT changed

`ad` sits at ~88% of its new 512 MiB limit. It expanded to fill the larger heap
after `-XX:MaxRAMPercentage=50` was applied, which is normal JVM behaviour, and
it has never been OOM-killed. Left alone on Emmett's instruction. If it stays
pinned there, the fix is `MaxRAMPercentage=40` rather than another limit
increase — the container has the memory, the JVM is just claiming more of it
than it needs.

---

## Load generator raised to 20 users — LOCAL ONLY, but WORTH CONSIDERING FOR THE FR DEMO

| File | Change |
|---|---|
| `.env.override` | `LOCUST_USERS=20` (overrides `LOCUST_USERS=5` in `.env`, which is untouched) |

### Why

At 5 users the stack produced only **~4.2 payment spans per 5-minute window**, so
a p95 was effectively "the slowest of four" and moved a whole histogram bucket
whenever one span landed differently.

Worse, the injected slowdown **starves its own metric**. During a `slow-db` test
on 2026-11-10, orders fell from 4–5 per 5 minutes to 1, and payment produced
**no spans at all between 15:14:14 and 15:19:28 — a 314-second gap, longer than
the 5-minute rate window**. With every bucket's `rate()` at zero,
`histogram_quantile` returned NaN, the rules went to No Data, and the panels fell
back to baseline for ~90 seconds while the toxic was still applied. The harder
the fault, the fewer samples available to prove it.

Ruled out as causes, for the record: no component restarted; the connector's
`aggregation_temporality` is `CUMULATIVE` by default and nothing in the pipeline
converts to delta; `metrics_expiration` defaults to `0`, meaning never expire;
and no span changed `status.code`, so no series split. It was purely an absence
of data.

### Paired with a rule setting

Each of the three rules also has **No Data → Keep Last State** set in OpsPilot,
so a future data hole is not reported as recovery. That is a UI setting on the
rule, not something in this repo.

The 5-minute rate window was **deliberately kept**. Lengthening it to 10m would
also mask the gap, but slow observations would then linger after `./demo.sh
reset`, and the Definition of Done requires the demo to return to baseline
within 60 seconds.

### For the FR demo deployment

Marked local-only because load levels are a deployment choice, not something this
repo should dictate. But **the underlying problem is not local**: any deployment
running 5 users will have the same too-sparse p95 and the same risk of a rate
window emptying during a demo. If the FR demo runs alert rules off span metrics,
it needs either comparable traffic or No Data handling configured, or both.

Cost on this machine was negligible — the whole stack idled at ~10% of 1000%
(10 cores) at 5 users, with the top consumer MySQL at 1.67%.

### ⚠ Side effect worth knowing: `make restart` bypasses the trim overlay

`make restart service=<name>` and `make redeploy service=<name>` use
`$(DOCKER_COMPOSE_ENV)` but **not** `$(DOCKER_COMPOSE_FILES)`, so
`docker-compose.trim.yml` is not applied. Recreating one service through them
resolves the untrimmed `depends_on` chain and **starts `jaeger` and
`opensearch`**, which the trim overlay exists to keep off.

Observed when recreating the load generator: the stack went from 23 to 25
containers. Both were stopped and removed again.

**FIXED.** `$(DOCKER_COMPOSE_FILES)` was added to the `stop`, `rm`, `create` and
`start` steps of both recipes, so single-service restarts now respect the trim
overlay. `make restart service=X TRIM=0` still bypasses it deliberately, as
`make start TRIM=0` does.

`redeploy`'s `build` step keeps `$(DOCKER_COMPOSE_ENV)` only — the trim overlay
adds no build configuration — but it gained `$(DOCKER_BUILD_ENV)` so a
single-service rebuild uses the same `COMPOSE_BAKE=false COMPOSE_PARALLEL_LIMIT`
settings as `make build`, which it was previously missing.

**This applies to the FR demo deployment too**, if it uses the Makefile — but only
once `docker-compose.trim.yml` exists there, which it does not and should not.
On a deployment without the trim overlay `DOCKER_COMPOSE_FILES` is empty and the
recipes behave exactly as before, so the change is safe to carry over either way.

**The collector was not affected.** `otel-collector` `depends_on` both `jaeger`
and `opensearch`, so it was worth confirming: same container ID throughout,
`created 2026-11-09T15:39:01`, `started 2026-11-10T11:15:22`, `RestartCount 0`,
and zero startup or shutdown markers in its log across the window. Compose only
applies `depends_on` when it starts a service; the collector was already
running, so it was left alone. Verified afterwards that it still has the right
config mounted (`otelcol-config.yml` plus `otelcol-config-extras.local.yml`,
both unmodified against git), the right environment, and is exporting cleanly —
1489 signal batches in 10 minutes with zero exporter errors.

---

## Manual OpsPilot UI steps

Everything below is done **in the OpsPilot UI** and is not captured anywhere in
this repo. It has to be repeated by hand in each org, so it must be repeated on
the FR demo deployment before the webinar — the rules and the repo changes alone
are not enough to make Coworker react.

### 1. Create the three alert rules

From [`alerts/README.md`](../../alerts/README.md), which has the exact PromQL and
values to type. For each of the three rules:

| Field | Value |
|---|---|
| Pending period (`for`) | `2m` |
| Evaluation interval | `1m` |
| Label | `journey` = `checkout` |
| Label | `environment` = `webinar-demo` |
| Label | `severity` = `warning` |
| Contact point | **OpsPilot Coworker** |
| No-data handling | **Keep Last State** |

**Keep Last State is not optional.** With the default handling, a gap in span
data is reported as recovery: during a `slow-db` test on 2026-11-10 payment
produced no spans for 314 seconds — longer than the 5-minute rate window — so
`histogram_quantile` returned NaN and the rules dropped back to Normal for ~90
seconds while the fault was still applied.

### 2. Subscribe Coworker to the rules — the step that is easy to miss

**Coworker → Tasks → Event sources → OpsPilot Alerts → Configure**, then tick
all three rules.

This does two things. It tells Coworker to watch them, and it adds the
**`opspilot_coworker=true`** label, which is what the notification policy routes
on. **Without that label the alerts fall through to the default email contact
point and Coworker never sees them** — the rules will fire correctly, the
Situation will never appear, and nothing in the alert itself will look wrong.

If a rehearsal shows alerts firing but no Coworker activity, check this first.

### 3. Create the deployment event source

**Coworker → new thread → "Set up a task"**, then ask for a Generic Webhook
event source. Suggested values:

| Field | Value |
|---|---|
| Type | Generic Webhook |
| Name | `Deployments` |
| Description | Deployment and rollback events for services in the webinar demo |
| Model Tier | Thorough |

Copy the webhook URL it gives you into `.env.override` as
`OPSPILOT_DEPLOY_WEBHOOK=`. **The URL embeds its own token — treat it as a
credential.** It is org-specific, so EmmettDev and the FR demo org each need
their own.

Without this, `./demo.sh deploy-bad` still changes `service.version` on
payment's spans, but Coworker has no deployment event to attach a Situation
to and will not link the symptom to the release — which is exactly what it
reported on 2026-11-12.

### 4. Resolve old Situations before the first rehearsal

Clear any Situations left over from earlier testing, so that what Coworker
produces during the rehearsal is unambiguously from that run. Otherwise a stale
Situation can easily be mistaken for a successful detection.

### Why none of this is in the repo

There is no rule-import path: OpsPilot's "Imported Rules" are rules carried over
from FusionReactor Alerts, not an import mechanism, and the ingest key in
`.env.override` has no access to any rules API — it returned 404 or a generic 500
on every plausible endpoint. `alerts/webinar-demo-rules.yaml` is therefore the
source of truth for the values, not something that can be loaded.

---

## `quotes` duplicate-key failures — BOTH FIXES NEEDED BY THE FR DEMO

On 2026-11-11 roughly **9.5% of checkouts were failing**. The chain:

```
getquote.cfm picks a random quote_number that already exists
  -> UNIQUE constraint on quotes.quote_number rejects the INSERT
    -> the page returns {"error":"Duplicate entry ..."} instead of a price
      -> shipping cannot parse it: "invalid float literal"
        -> gRPC INTERNAL -> checkout PlaceOrder fails -> frontend 500
```

Measured error ratio, from shipping's view of every quote call:

| Window | Calls | Errors | Ratio |
|---|---:|---:|---:|
| 2026-11-10 14:00–17:59 | 440 | 30 | **6.82%** |
| 2026-11-11 08:00–09:46 | 243 | 33 | **13.58%** |

**None of the three alert rules would have caught this.** They are latency
rules; a duplicate-key error returns fast. Payment p95 was a healthy 9 ms
throughout.

### Cause, including our part in it

`quote_number` was `"Q-" & year(now()) & "-" & randRange(1000, 9999)` — a
**9,000-value space** against a UNIQUE constraint. Collisions scale with table
size, so the bug was always present: errors were already occurring at ~8.6% on
2026-11-10 at 10:00, **before** any change of ours.

What made it worse: `removeoldquotes.cfm` was the **only** thing pruning the
`quotes` table, and it was disabled in the load generator to stop its
pathological query burning ~400% of MySQL's CPU. That removed the brake. The
table went from 281 rows to 1,107 in a day (~875/day), taking the collision rate
from ~2.9% to ~12%, on track for 80% within a week.

### Fix 1 — scheduled prune (`src/quote-cf/sql/004_prune_quotes.sql`)

A MySQL **event**, so it lives with the database and ports cleanly rather than
depending on an external scheduler:

```sql
CREATE EVENT IF NOT EXISTS prune_old_quotes
    ON SCHEDULE EVERY 1 DAY
    STARTS CURRENT_TIMESTAMP + INTERVAL 1 HOUR
    DO DELETE FROM quotes WHERE quote_date < CURDATE() - INTERVAL 30 DAY;
```

`quote_items` has `ON DELETE CASCADE` against `quotes`, so items go with them.
Requires `event_scheduler=ON`, which is the default in this MySQL 8 image —
verified `ON` here. Installed live and confirmed `ENABLED`.

**Be aware what this does and does not do.** The one-off prune removed only
**21 rows**, because 1,086 of 1,107 were less than 7 days old. The prune is a
long-term guard against unbounded growth, **not** the thing that fixed today's
error rate — at 30-day retention and ~875 rows/day it caps the table near 26,000
rows, which against the widened number space is about a 2.9% collision rate.
Shorten the interval if the demo ever runs at materially higher volume.

### Fix 2 — widen the number space (`src/quote-cf/www/getquote.cfm`)

`randRange(1000, 9999)` → `randRange(100000, 999999)`: 9,000 values becomes
900,000, taking collisions to roughly 0.1% at the volumes this demo runs. **This
is the change that actually drops the error rate**, and it works regardless of
table size.

### ⚠ For the FR demo deployment

**Both fixes are needed.** The FR demo runs the same `getquote.cfm` with the same
9,000-value range and the same UNIQUE constraint, so it has the same latent
fault — its error rate depends only on how many rows its `quotes` table has
accumulated.

**`removeoldquotes.cfm` can only be removed from the FR demo's load generator if
the prune event replaces it.** Disabling it without `004_prune_quotes.sql`
installed is precisely what caused this incident: it removes the only cleanup and
puts the table on unbounded growth. Apply the event first, then disable the task.

A better long-term fix than either of these is to derive `quote_number` from the
auto-increment `quote_id` so collisions are impossible. Not done here, because it
is a larger change to demo content.

---

## `frontend-proxy` bound to loopback — LOCAL ONLY

| File | Change |
|---|---|
| `docker-compose.trim.yml` | `frontend-proxy` gets `ports: !override` binding both published ports to `127.0.0.1`. |

Upstream publishes both on `0.0.0.0`, so on a laptop they are reachable from
every interface — anyone on the same network can hit them:

- **8080** — the demo UI, and **`/feature`**, the flagd UI, which turns faults on
  and off **with no authentication at all**. Someone on the same wifi could
  inject a fault mid-webinar.
- **10000** — Envoy's **admin interface**: full config dump, stats, and
  endpoints that can drain or shut the proxy down.

Verified after the change: `127.0.0.1:8080` returns 200, and both ports are
refused on the LAN address.

`!override` is required. Compose **appends** to a ports list rather than
replacing it, so without it the `0.0.0.0` bindings would have remained alongside
the loopback ones and nothing would actually have been restricted. Worth knowing
if anyone writes a similar override.

**Local only**, because it lives in the trim overlay and because the right answer
differs by deployment. But **the exposure is not local** — the FR demo
deployment publishes the same two ports the same way. If it is reachable from
anything other than localhost, the unauthenticated flag UI and the Envoy admin
endpoint are both exposed there too, and that is worth checking independently of
this repo.

---

## `payment` charge span now reports ERROR on failure

| File | Change |
|---|---|
| `src/payment/charge.js` | Import `SpanStatusCode`; call `span.setStatus({ code: SpanStatusCode.ERROR, ... })` on both database failure paths, next to the existing `recordException`. |

`recordException()` attaches an exception event but **does not change span
status**. The charge span was therefore left `Unset` on failure, and only the
gRPC handler span above it carried `Error` — so the innermost span, the one that
actually knows the charge failed, looked fine.

Detection already worked via the gRPC span, so this is a fidelity fix rather
than a functional one. It matters for anything that counts error spans per
service, and for anyone reading a trace and trying to find where the failure
originated.

**Applies to the FR demo deployment** — same source, same gap. Requires a
payment rebuild.

---

## Span metrics vanish for any redeployed service — NEEDED BY THE FR DEMO

On 2026-11-11, `traces_span_metrics_*{service_name="payment"}` stopped appearing
in OpsPilot at ~16:40, five minutes after payment was redeployed at 16:35.
**Traces kept flowing normally** — the INSERT span was visible in Tempo at
748 ms — so only the derived metrics were affected.

### Cause

The `spanmetrics` connector had no `resource_metrics_key_attributes`, so it
identifies a resource by its **entire** attribute set. Payment's resource
carries four attributes that change on every redeploy:

```
service.instance.id   bc035bb3-f2e1-464b-8075-7f04f8dd0a0a
container.id          21e2bd09e3ae7971c53d7aa705d4e3558b333aa9...
host.name             21e2bd09e3ae
process.pid           38
```

So a redeploy creates a **second resource bucket for the same logical service**.
And because `metrics_expiration` defaults to **0 — never expire** — the dead
bucket is kept and exported forever alongside the live one.

Both buckets then emit the same metric with the same **promoted** labels
(`service_name`, `span_name`, …) — the volatile attributes above are not
promoted — so the backend receives two samples with identical labels at the same
timestamp and rejects them as duplicates. The series goes blank.

Nothing is logged. The collector reports **no partial-success, no rejection, no
error** — verified, zero matches for `partial|rejected|limit|throttl|dropped`
since 16:30. Locally the connector was still generating payment series
throughout (`INSERT`, `charge`, `grpc.oteldemo.PaymentService/Charge`), so every
local check looks healthy while the backend has nothing.

### Fix

| File | Change |
|---|---|
| `src/otel-collector/otelcol-config.yml` | `spanmetrics` gains `resource_metrics_key_attributes: [service.name, service.namespace, service.version]` and `metrics_expiration: 5m`. |

`resource_metrics_key_attributes` makes a redeploy reuse the same bucket, so no
duplicate is ever created. `metrics_expiration` is belt and braces for a
genuinely dead resource — the 2.0.3 bucket after `deploy-bad` then `rollback` —
and 5 minutes sits well above the ~17 s gap between orders, so live series are
never dropped mid-flight.

`service.version` is deliberately **kept** as a key attribute: the `deploy-bad`
scenario depends on 2.0.2 and 2.0.3 being distinguishable.

### Why this matters beyond this incident

**Any redeployed service loses its span metrics**, silently, until the collector
restarts. That includes every `make redeploy`, and it would include a real
deployment on the FR demo. It is almost certainly happening there already —
nothing about it is local.

It also explains why a collector restart "fixes" it: the restart clears the
connector's memory of the dead bucket. That is a trap, because it makes the
problem look transient.

**Confirm in OpsPilot after applying**, and note the prediction: *all* of a
service's span metrics stop together, not just one span name, because they share
the resource.

---

## `removeoldquotes.cfm` made safe and re-enabled — NEEDED BY THE FR DEMO

**Mikey asked for this to be kept rather than removed**, on the grounds that it
is meant to be a slow-query demo. Agreed, and reworked so it stays noticeably
slow but bounded. It is re-enabled in the load generator, which supersedes the
earlier entry saying the task was disabled pending his sign-off.

### What was wrong

The trailing `LIMIT 10` bounded the **output**, not the work: the `ORDER BY`
forced MySQL to materialise every row of a triple `CROSS JOIN` on `quotes`
first. Cost was **O(rows³)** — ~26 minutes and 3.5 billion rows examined at 281
rows, getting 8× worse per doubling.

Less obviously, the "fast" path taken on **95% of calls** was `quotes CROSS JOIN
quotes` with `LIMIT 25` — **O(rows²)**, also growing with the table, on almost
every call.

### What changed

| Change | Effect |
|---|---|
| Each cross-join arm is now a **derived table with its own `LIMIT`** | Work is fixed at `slowRows³` (150³ = 3,375,000) and `fastRows²` (40² = 1,600) **regardless of table size** |
| `DATE()` wrappers removed from all predicates | The `quote_date` index is usable again |
| `SELECT /*+ MAX_EXECUTION_TIME(...) */` on both queries | **MySQL kills the query itself** — 10 s slow path, 3 s fast path — so it can never outlive the Lucee request and strand an orphaned query |
| `memory_hog_field`, the `computed_hash` columns and the `UUID()` calls dropped; result capped at 10/25 short rows | Almost nothing for the JDBC driver to buffer into quote's heap |
| The result loop no longer accumulates those columns | It was building an array from columns designed to be large, on a result set that grew with the table |

### Measured

**Run time is now independent of table size**, which was the whole point:

| Table | Rows | Run time (3 runs) | Result rows |
|---|---:|---|---:|
| real | 3,331 | 3.36 / 3.44 / 3.49 s | 10 |
| scaled copy | **53,280 (16×)** | **3.32 / 3.36 / 3.40 s** | 10 |

Still a few seconds, so it remains a legitimate slow-query demo — just one whose
cost is set by `slowRows`, not by how long the demo has been running.

`slowRows` is the tuning knob and the relationship is **cubic**: 60 → 0.27 s,
90 → 0.77 s, 120 → 1.79 s, 150 → 3.36 s. Re-measure if you change it.

### Load generator

Re-enabled at `@task(1)`, unchanged from its original weight. The page itself
only takes the slow path 5% of the time, so the expensive query runs roughly
once every 20 minutes. Raise the weight, or the 5% gate in the page, to see it
more often.

### `prune_old_quotes` kept

The MySQL event from `src/quote-cf/sql/004_prune_quotes.sql` is unchanged and
still `ENABLED`. The two are complementary: the prune bounds how large the table
gets, and the derived-table limits bound the query regardless.

### For the FR demo

Needed there too — it runs the same page with the same unbounded queries, so it
has the same latent fault, and its severity depends only on how many rows its
`quotes` table has accumulated. Note the earlier entry in this document said
`removeoldquotes.cfm` could only be removed from the load generator if the prune
replaced it; that is now moot, since the page itself is safe and stays enabled.

---

## `quote` memory limit raised to 4 GiB — NEEDED BY THE FR DEMO

| Service | Was | Now | Heap ceiling |
|---|---:|---:|---:|
| `quote` | 3G | **4G** | 2304 MiB → **3072 MiB** |

The heap ceiling follows automatically from `-XX:MaxRAMPercentage=75` in
`LUCEE_JAVA_OPTS`, which was added when the original OOM was fixed. Verified on
the live JVM's cgroup after restarting: `MaxHeapSize = 3072 MiB`.

### Why

At 3G the heap sawtoothed up to **2.12 GiB against a 2304 MiB ceiling** — about
**8% headroom at the peaks**. That is too little to rely on during a live demo,
where an OOM would take out the whole checkout path: `quote` stalling blocks
`shipping`, which blocks `checkout`, which starves `payment`, and none of it
raises an alert because nothing crashes.

### This is not caused by `removeoldquotes.cfm`

Worth stating plainly, because the timing invites the assumption. The same
sawtooth was measured on 2026-11-11 with `removeoldquotes` **disabled for a full
day**: min 696 MiB, max 2401 MiB, mean 1290 MiB over 58 samples. Today's peaks
are slightly *lower* than that, and the troughs are not rising (1.386 → 1.158 →
1.159 GiB), so it is not a leak either.

It reads as ordinary Lucee/FusionReactor behaviour in a JVM given a large heap:
it fills what it is given before collecting. The reworked query cannot plausibly
be the driver — it now returns 10 short rows.

So this change buys headroom against a pre-existing characteristic. It does not
fix a leak, because there is no leak to fix.

### For the FR demo

Same image, same `MaxRAMPercentage=75`, same 3G limit, so the same 8% headroom
at the peaks. Whether it matters depends on that deployment's traffic, but the
reasoning carries over: an OOM in `quote` is silent and takes the checkout path
with it, which is an expensive way to find out.


## Deployment events for `deploy-bad` / `rollback` — NEEDED BY THE FR DEMO

**File:** `demo.sh` (new `record_change_event()`, called from `cmd_deploy_bad`
and `cmd_rollback`), `.env.override.example` (new `OPSPILOT_DEPLOY_WEBHOOK`).

### Why

Coworker reported that it saw **no deploy or config-change event for payment**,
so it did not link the N+1 symptom to the 2.0.3 release — even though
`service.version` changed on the spans. A version attribute on telemetry is not
a change event; OpsPilot wants one explicitly.

### What changed

`deploy-bad` and `rollback` now record a deployment event through two sinks,
both best-effort with a 5-second timeout. Neither can fail the script: a
deployment event failing to send must never break a live demo.

| Sink | What it is for | Credential |
|---|---|---|
| OTLP log record | **Evidence.** Posted to the collector already in the stack, which forwards it to OpsPilot on the existing pipeline. `service.name`, `service.version` and `deployment.environment` are *resource* attributes so it correlates with payment in the Service Catalogue. | None — rides the collector's existing auth |
| Coworker Generic Webhook | **The trigger.** An event source starts an investigation on each event. | The webhook URL itself, from `.env.override` |

Both are needed: the webhook starts the investigation, the log is the durable
evidence that survives in the data. If `OPSPILOT_DEPLOY_WEBHOOK` is unset the
webhook sink is skipped silently and the log sink still runs, so the script
works unchanged in an org that has no event source yet.

### The payload says only what was deployed

Service, version, previous version, environment, timestamp, and a one-line
summary such as `Deployed payment 2.0.3`. It deliberately does **not** describe
the fault. A deploy event that names the defect means Coworker is reading the
answer out rather than investigating, which defeats the point of the demo.

### Implementation note

The collector publishes 4318 on an **ephemeral** host port that changes every
time the container is recreated, so `demo.sh` resolves it at run time with
`docker port otel-collector 4318` rather than hardcoding one. No new published
port and no compose change were needed.

### ⚠ For the FR demo deployment

- The event source is a **manual UI step** and must be created in the FR demo
  org too — see "Manual OpsPilot UI steps" step 3 above.
- `demo.sh` reaches the collector over `docker port`. On Kubernetes that has no
  equivalent: the OTLP sink would need to post to the collector Service
  (`http://<collector-service>:4318/v1/logs`) from wherever `demo.sh` runs, or
  be dropped in favour of the webhook sink alone.
- Note the OTLP/HTTP receiver returns **200 even for a malformed body** — it
  does not reject unknown fields. HTTP status confirms reachability only, so
  confirm a deployment event by looking for it in OpsPilot, not by the exit
  code.

## Baseline latency toxic re-applied on start — NEEDED BY THE FR DEMO

**Files:** `demo.sh` (new `baseline-toxic` subcommand), `Makefile` (`start` target).

### Why

`make stop` runs `down --volumes`, and `make start` runs `up --force-recreate`.
Either one recreates the toxiproxy container, and **toxics live only in that
container's memory**. `src/toxiproxy/toxiproxy.json` seeds the `payment-mysql`
proxy, but that file format can only express proxies, not toxics — so the
permanent 4 ms payment → MySQL link latency silently disappeared after a
restart on 2026-11-16 and nothing reported it.

That matters because the 4 ms is not cosmetic: the N+1 deploy scenario depends
on it. 87–157 sequential round trips at 4 ms is the ~500–800 ms that makes
`deploy-bad` land in a believable range. At 0 ms the scenario is far weaker.

### What changed

`ensure_baseline_latency()` already existed and was already idempotent
(remove-then-add). It is now reachable on its own as `./demo.sh baseline-toxic`,
which applies *only* the link latency and does not rewrite the flagd file the
way `baseline` / `reset` do. `make start` calls it after `up`.

Ordering is safe without a sleep: `payment` declares
`depends_on: toxiproxy: condition: service_healthy`, so `up` cannot return
until the toxiproxy control API is answering.

It **warns rather than fails** if the toxic cannot be applied. The stack is
already up by that point, so aborting the target would leave a worse state than
a visible warning.

### Why not a compose init container

The obvious alternative — a one-shot service running `toxiproxy-cli` — was
rejected: the toxiproxy image has **no shell** (verified: `/bin/sh` does not
exist), so such a container can run exactly one command and cannot do the
remove-then-add that makes this idempotent. It would exit non-zero on every run
where the toxic already existed.

### ⚠ For the FR demo deployment

`make start` is compose-only. On Kubernetes the equivalent is a Job or an
initContainer running `toxiproxy-cli --host http://<toxiproxy-svc>:8474 toxic
add -n payment-mysql-baseline -t latency -a latency=4 -a jitter=1
payment-mysql`, and because of the no-shell constraint it must be made
idempotent some other way — for example by always recreating the proxy first.

## Second bad release: `deploy-bad-v2` (payment 2.1.0) — NEEDED BY THE FR DEMO

**Files:** `src/payment/charge.js`, `docker-compose.yml`, `demo.sh`.

### Why

Coworker needs a second bad release that reads as a *new* problem, not a repeat
of 2.0.3. Re-running `deploy-bad` gives the same version, same table and same
statement, so there is nothing to distinguish the two incidents.

### What it does

Same *shape* of mistake — one query per basket item — but a different table and
a different statement:

| | 2.0.3 (`deploy-bad`) | 2.1.0 (`deploy-bad-v2`) |
|---|---|---|
| Table | `services` (50 rows) | `quotes` (729 rows) **JOIN** `customers` |
| Statement | flat `SELECT ... WHERE service_id = ?` | join on two primary keys |
| Env var | `PAYMENT_ITEM_LOOKUPS` | `PAYMENT_CUSTOMER_LOOKUPS` |
| Queries/charge | 87–157 | 90–140 (measured mean 118) |

`quotes` is untouched by 2.0.3, so the two releases have no overlap at all.
Both still produce spans named `SELECT` — mysql2 names spans after the first
word of the SQL — so the distinguishing signal in a trace is `db.statement`.

### Both are inert by default and mutually exclusive

Each is gated on its own env var defaulting to `0`. `payment_redeploy()` always
passes *both* variables, so redeploying for either scenario clears the other —
they can never be on at once. `cmd_deploy_bad` is byte-for-byte unchanged; the
new fourth argument to `payment_redeploy()` defaults to `0`.

`rollback` now reports the version it actually replaced rather than a hardcoded
`2.0.3`, so the rollback event is correct for whichever release is live.

### Measured, 2026-11-16

| | baseline 2.0.2 | 2.1.0 | after rollback |
|---|---|---|---|
| payment charge p50 | 8 ms | **605 ms** | 12 ms |
| payment charge p95 | 24 ms | **826 ms** | 26 ms |
| queries per charge | 1 (the INSERT) | 90–140, mean 118 | 1 |

`performance_schema.prepared_statements_instances` recorded **1,234 executions**
of the new join against **10** INSERTs, at 0.12 ms each — the database is never
at risk; the cost is doing ~120 of them sequentially. MySQL CPU stayed at 0.45%
and `quote` was unaffected (healthy, 0 restarts) even though the join reads the
`quotes` table that ColdFusion also uses.

### Which alerts this trips

- ✅ **Payment service is slow** — p95 826 ms against a 500 ms threshold.
- ✅ **Payment is making far more database calls per charge** — ratio ~123
  against a threshold of 5 (`alerts/scenario-rules.yaml`, if loaded).
- ❌ **Payment database queries are slow** — correctly silent. Each query is
  0.12 ms; this is an N+1, not a slow query.
- ❌ **Checkout is slow for customers** — checkout p95 ~1200 ms against a
  1500 ms threshold. Same as 2.0.3, which measured 1373 ms. If the webinar
  needs the checkout rule to fire on a bad deploy, that threshold needs
  lowering — it is not specific to this release.

### Note on prepared statements

`pool.execute()` uses the binary prepared-statement protocol, so these queries
do **not** appear in `events_statements_summary_by_digest` with their SQL text.
Use `performance_schema.prepared_statements_instances` to verify them.
