# Alert rules for the webinar demo

Three rules, in `webinar-demo-rules.yaml`. They exist so Coworker has something
to investigate: `./demo.sh slow-db` should trip all three, closest-to-cause
first, and they share grouping labels so they have the best chance of clustering
into one investigation.

## Quickest way to get them into EmmettDev: the UI

**There is no usable import path.** Two things were checked:

- OpsPilot's **Imported Rules** page describes rules *carried over from
  FusionReactor Alerts*, not a mechanism for importing a file. No file format,
  no endpoint, no CLI is documented.
- The ingest API key in `.env.override` was tried against five plausible rules
  endpoints on both ingest hosts. Every one returned 404 (on
  `data.production.streamhippo.io`) or a generic 500 (on
  `api.fusionreactor.io`) — the same response those hosts give any unrouted
  `/api/*` path. **`OPSPILOT_AUTH` is an ingest credential, not a management
  one**, so it cannot create rules even if an endpoint exists.

So: type them into the UI. Roughly five minutes for all three.

### Values to type

For each rule, OpsPilot's new-alerting form chains **Query → Reduce → Threshold**
(each step has a reference ID such as `$query` that later steps use). Set the
query mode to **PromQL** and paste the expression, then set the threshold.

Common to all three:

| Field | Value |
|---|---|
| Pending duration (`for`) | `2m` |
| Evaluation interval | `1m` |
| Namespace / group | `webinar-demo-checkout-journey` |
| Label | `journey` = `checkout` |
| Label | `environment` = `webinar-demo` |
| Label | `severity` = `warning` |

**Rule 1 — `Checkout is slow for customers`**, threshold `IS ABOVE 1500`:

```promql
histogram_quantile(0.95, sum by (le) (rate(traces_span_metrics_duration_bucket{service_name="checkout"}[5m])))
```

**Rule 2 — `Payment service is slow`**, threshold `IS ABOVE 500`:

```promql
histogram_quantile(0.95, sum by (le) (rate(traces_span_metrics_duration_bucket{service_name="payment"}[5m])))
```

**Rule 3 — `Payment database queries are slow`**, threshold `IS ABOVE 500`:

```promql
histogram_quantile(0.95, sum by (le) (rate(traces_span_metrics_duration_bucket{service_name="payment", span_name="INSERT"}[5m])))
```

Descriptions are in the YAML under `annotations` — paste them in, they are
written to be read aloud on screen.

### Metric name — confirmed

The metric is **`traces_span_metrics_duration_bucket`**, confirmed in EmmettDev.

Note the unit is **not** in the name: the `spanmetrics` connector records in
milliseconds by default but names the metric from its namespace
(`traces.span.metrics`) plus `duration`, so the `le` values are milliseconds
even though nothing in the name says so. Verified against the `le` values in
EmmettDev. The thresholds below are therefore in milliseconds and need no
conversion.

If `span_name` turns out not to be an available label, rule 3 needs `db.system`
adding to the `spanmetrics` connector's `dimensions` in
`src/otel-collector/otelcol-config.yml` — a collector change, so it is not done
here.

### Bucket boundaries — both thresholds are safely bracketed

The connector is configured with no `histogram.explicit.buckets`, so it uses the
v0.125.0 defaults:

```
2ms, 4ms, 6ms, 8ms, 10ms, 50ms, 100ms, 200ms, 400ms, 800ms, 1s, 1400ms, 2s, 5s, 10s, 15s
```

Both thresholds fall strictly between two boundaries, which is what
`histogram_quantile` needs to interpolate rather than saturate:

| Threshold | Bucket below | Bucket above |
|---|---|---|
| **500 ms** (payment, payment DB) | 400 ms | 800 ms |
| **1500 ms** (checkout) | 1400 ms | 2000 ms |

What that means in practice, per rule:

- **checkout** — baseline p95 is 567 ms, which lands in the `(400, 800]` bucket,
  so the reported quantile can never exceed 800 ms at baseline: a comfortable
  margin below the 1500 ms threshold. Under `slow-db` checkout runs ~2.2 s+, so
  the quantile lands in `(2000, 5000]` and reports well above 1500.
- **payment** — baseline p95 is 10 ms, sitting exactly on a bucket boundary, so
  the reported quantile is ~10 ms. Under injection payment runs 1.6–3.2 s, which
  reports ≥1400 ms. Enormous separation either side of the 500 ms threshold.
- **payment DB** — baseline max is 13.5 ms, in the `(10, 50]` bucket. Under
  injection the DB call is ≥800 ms, landing in `(800, 1000]` or higher. Again
  well clear of 500 ms.

One consequence of the coarse buckets in this range is worth knowing: between
400 ms and 800 ms the quantile is linear interpolation inside a single 400 ms
wide bucket, so a reported value of, say, 500 ms means "the p95 landed about a
quarter of the way into the 400–800 ms bucket" rather than a precise 500 ms.
That imprecision does not affect these rules, because under injection every
measurement sits one or more whole buckets above the threshold — but it is why
the thresholds are set with large headroom rather than tuned to the baseline.

## Where the thresholds come from

Measured over **2026-11-10 11:25Z – 14:43Z (3h18m)**, 115 completed orders — the
first clean window after the `quote` OOM, the DEEP DNS errors and the runaway
`removeoldquotes` query were fixed.

| | measured baseline | threshold | headroom |
|---|---|---|---|
| checkout PlaceOrder | p50 430, p95 567, max 614 ms | **1500 ms** | 2.4× max |
| payment Charge | p50 6, p95 10, max 15 ms | **500 ms** | 33× max |
| payment DB INSERT | avg 3.8, max 13.5 ms | **500 ms** | 37× max |

Sources: checkout and payment from their own request/completion log pairs
(payment correlated by `trace_id`); the DB figure from MySQL's
`performance_schema` `statement/com/Execute` counter, which is where payment's
prepared-statement INSERTs land — 127 executions matching 127 rows written.

Each threshold must also **fire** under `./demo.sh slow-db` (800 ms), which was
measured to take the proxied connection from 51 ms to 4261 ms. Expected under
injection: DB ≥ 800 ms, payment charge 1.6–3.2 s, checkout 2.2 s+. Every
threshold sits between the baseline maximum and the injected floor.

## ⚠ Sleep and wake produce false firings

If the machine has slept, **treat the first alerts after waking as suspect until
checked**. A request in flight when the host suspends records wall-clock time
across the sleep, so a single span can carry a duration of an hour or more. That
lands in the top histogram bucket and pushes p95 over any threshold here the
moment it arrives — `for: 2m` does not help, because the value persists for the
whole rate window.

This happened on 2026-11-11: a critical Situation opened at 07:04 reporting
4,606 s of shipping latency, two minutes after the machine woke. Nothing was
broken.

Prevention is in the runbook: stop the load generator before closing the lid, so
nothing is in flight to straddle the suspension. See
[`../docs/WEBINAR-RUNBOOK.md`](../docs/WEBINAR-RUNBOOK.md).

## Known limits — read before trusting these in the webinar

1. **This is a 3h18m window, not the 24 hours Step 3 asks for.** The machine
   cannot run overnight. Nothing here has seen an overnight idle period, a
   load-generator restart, or a Lucee GC pause, all of which can add latency
   that these thresholds have never been tested against.
2. **The percentiles are derived from logs, not from OpsPilot's own metrics.**
   A `histogram_quantile` over a 5-minute rate will not produce exactly the same
   number as pairing log lines. Expect the OpsPilot p95 to differ somewhat; the
   headroom (2.4× at the tightest) is sized to absorb that.
3. **`checkout` p95 of 567 ms is the whole PlaceOrder**, including the calls to
   cart, catalog, currency, shipping and payment. If the webinar story ever
   needs checkout's own time excluding dependencies, that is a different metric.
4. **Nothing has been rehearsed yet.** Confirm each rule fires on `slow-db` and
   clears on `reset` before the webinar, and confirm whether the three actually
   cluster into one investigation — CLAUDE.md flags that as a rehearsal
   question, and the shared labels only give it the best chance.

## Portability

The rules reference no org-specific value — only service names, which are
identical in EmmettDev and the FR demo org. They can be typed into either
unchanged.
