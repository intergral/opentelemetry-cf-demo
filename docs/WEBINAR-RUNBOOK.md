# Webinar runbook

Operating guide for the OpsPilot Coworker webinar demo. For what was changed and
why, see [CHANGES-FOR-FR-DEMO.md](CHANGES-FOR-FR-DEMO.md). For the alert rules,
see [../alerts/README.md](../alerts/README.md).

---

## Before closing the lid — stop the load generator

```bash
docker compose --env-file .env --env-file .env.arm64 --env-file .env.override \
  -f docker-compose.yml -f docker-compose.trim.yml stop load-generator
```

Leave everything else running. Restart it on wake with `start` in place of
`stop`, before the post-sleep checks below.

**Why this matters.** Docker keeps containers "running" across a host sleep, but
any request in flight when the machine suspends has its span start recorded
before the sleep and its end recorded after the wake — so the span records
wall-clock time across the suspension. On 2026-11-11 that produced a **critical
Situation at 07:04** reporting 4,606 s of shipping latency and 504s from the
load generator. Nothing was wrong: `shipping` had simply been idle for 103
minutes (05:19–07:02) and the first spans after waking carried the sleep in
their duration.

Stopping the load generator means no requests are in flight, so there is nothing
to straddle the suspension. It is the cheapest fix and it removes the artifact
at source.

If you do not need the stack overnight at all, `make stop` tears it down
completely — but note that destroys the MySQL data, including the `quotes`
table and its prune event.

### If a Situation appears after a wake

**Resolve it before rehearsing.** A sleep artifact looks exactly like a real
incident, and leaving it open risks mistaking it for a successful detection
during the rehearsal. Check the timing first: if the reported latency is of the
same order as the sleep gap, and the services involved are healthy now, it is an
artifact.

`for: 2m` offers no protection here. A single span carrying a 70-minute duration
lands in the top histogram bucket and can push a p95 over any threshold the
moment it arrives.

---

## After the laptop wakes from sleep — do this first, every time

Docker Desktop keeps containers "running" across a host sleep, but their clocks,
timers, TCP connections and Kafka consumer groups do not survive cleanly. The
stack usually recovers on its own within a minute or two; the point of these
three steps is to know that it has, before you are on a call.

### 1. `./demo.sh status`

Confirms three things at once:

- **every flag reads `off`** — the line `-> baseline: every flag is off` should
  be printed. If any flag shows `<== ON`, something is injecting a fault.
- **no toxics** — `no toxics -> normal database latency`. If it says
  `<== DATABASE IS SLOWED`, a previous `slow-db` is still active.
- **containers** — anything that is not `Up` is listed with its restart count.

### 2. Check every container is healthy

`demo.sh status` lists them, but check specifically:

| Container | Expect |
|---|---|
| `quote` | `Up … (healthy)`. It is the only service with a healthcheck, added because an OOM-wedged JVM otherwise looks perfectly healthy. |
| `mysql`, `kafka`, `toxiproxy` | `Up … (healthy)` |
| everything else | `Up`, restart count `0` |

A restart count above zero is not automatically a problem — a clean Kafka
reconnect shows as one restart with exit code 0 — but it is worth knowing about
before you start. To check one:

```bash
docker inspect <name> --format 'restarts={{.RestartCount}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}'
```

`oom=true` means the container was killed for memory and needs looking at.

### 3. `./demo.sh reset`

Idempotent and safe to run at any time. Clears every flag, removes any injected
slowdown, and **applies the 4 ms baseline link latency**. Run it even when
`status` looked clean — it costs a second and guarantees the starting state.

> **Baseline is 4 ms on purpose, not zero.** `payment` reaches MySQL through
> Toxiproxy with a permanent 4 ms ± 1 ms latency toxic
> (`payment-mysql-baseline`), representing the network distance to a real
> database. `demo.sh baseline` and `reset` **apply** it rather than removing it.
>
> So `./demo.sh status` showing **1 toxic is the normal state**. Two or more
> means an injected fault is layered on top. Zero means the baseline is missing
> and you should run `reset`.
>
> Do not "fix" the 4 ms by removing the toxic: without it an N+1 deployment
> costs almost nothing per query and the bad-deploy scenario does not reproduce.

### Then confirm traffic is actually flowing

The three steps above prove the stack is *up*. They do not prove orders are
being placed. Before the webinar, confirm the full path:

```bash
docker logs checkout --since 10m 2>&1 | grep -c 'order confirmation email sent'
docker logs payment  --since 10m 2>&1 | grep -c 'Transaction complete'
```

Both should be non-zero and roughly equal. Expect about one order every 1–2
minutes with the default 5 load-generator users.

If they are zero while containers look healthy, the usual cause is a wedged
dependency upstream of payment rather than payment itself — this exact failure
has happened once already, when `quote` OOMed and silently stalled `shipping`,
then `checkout`, then `payment`. Check `quote` first:

```bash
docker exec quote sh -c 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8888/health.cfm'
```

Anything other than `200` means `quote` is wedged; restart it, then `shipping`,
in that order.

---

## Starting the stack from cold

```bash
make build && make start
```

Use the `Makefile`, not a bare `docker compose` command: on an arm64 Mac it is
the only thing that supplies `--env-file .env.arm64` and
`--build-arg=_JAVA_OPTIONS=-XX:UseSVE=0`, which the Java services need. It also
picks up `.env.override` and applies the local-only trim overlay.

`make start TRIM=0` brings back `jaeger`, `opensearch`, `prometheus` and
`grafana`, which are off by default locally.

Expect 23 containers. While trimmed, `/jaeger/ui` and `/grafana/` return 503 —
that is expected, not a fault.

---

## Running the demo

| Step | Command | What to say |
|---|---|---|
| Show the healthy baseline | `./demo.sh status` | Everything is quiet, no faults injected. |
| Inject the slowdown | `./demo.sh slow-db` | 800 ms ± 100 ms on the payment → MySQL connection only. |
| Or ramp it | `./demo.sh slow-db-ramp` | 0 → 800 ms over 5 minutes, for a gradual degradation. |
| Make checkouts actually FAIL | `./demo.sh fail-db` | ~23% of orders fail outright. Coworker needs real failures, not slow successes. |
| Ship a bad build | `./demo.sh deploy-bad` | payment 2.0.3 with an N+1: payment p95 833 ms, checkout p95 1373 ms. |
| Roll it back | `./demo.sh rollback` | payment 2.0.2, back to ~13 ms. |
| Reset | `./demo.sh reset` | Back to baseline, idempotent. Clears flags and injected toxics; keeps the 4 ms baseline latency. |

`slow-db` affects **only** payment's database connection. `quote` connects to
MySQL directly and is unaffected — that is deliberate, and it is what keeps
ColdFusion out of the story.

Expect the slowdown to show within about two minutes, closest-to-cause first:
payment's DB spans, then payment, then checkout, then the frontend.

---

## Rehearsal checklist

Work through this end to end at least once before the webinar.

- [ ] `make build && make start` from cold, 23 containers up
- [ ] Post-sleep checks above pass
- [ ] Orders flowing: checkout and payment counts non-zero and roughly equal
- [ ] All three alert rules loaded in EmmettDev (see `alerts/README.md`) and the
      metric name confirmed in the metric browser
- [ ] **No rule fires during normal traffic** — watch for at least 30 minutes
- [ ] `./demo.sh slow-db` → all three rules fire within ~2 minutes
- [ ] The three alerts cluster into **one** investigation, not three. CLAUDE.md
      flags this as unresolved; the shared `journey` / `environment` labels only
      give it the best chance
- [ ] Coworker produces a Situation that points at the database
- [ ] `./demo.sh deploy-bad` prints **both** deployment-event sinks as `sent`,
      and the event appears in OpsPilot. Then confirm Coworker's Situation
      actually *links the symptom to the 2.0.3 release* — that link is the
      whole point of the event, and it was missing on 2026-11-12. Needs
      `OPSPILOT_DEPLOY_WEBHOOK` set in `.env.override` and the event source
      created (see `docs/CHANGES-FOR-FR-DEMO.md`, Manual OpsPilot UI steps)
- [ ] `./demo.sh reset` → baseline within 60 s, rules clear
- [ ] `quote` healthy throughout, proving the fault was scoped
- [ ] Repeat inject/reset three times — Definition of Done asks for three
      consecutive clean runs
- [ ] Check `quote` memory is not climbing: `docker stats --no-stream quote`.
      Container limit 4 GiB, heap ceiling 3072 MiB. Expect a sawtooth with a
      mean near 1.8 GiB and peaks around 3 GiB that GC fully reclaims — that
      is normal. What matters is that the *troughs* stay flat; rising troughs
      would mean a genuine leak

---

## Known sharp edges

- **`shipping` has no timeout on its call to `quote`.** If `quote` stalls,
  `shipping` parks indefinitely and takes checkout and payment down with it,
  with no alert firing because nothing crashes. Deliberately not fixed yet.
- **`ad` sits at ~88% of its 512 MiB limit.** It has never been OOM-killed, but
  it has the least headroom of any JVM service.
- **The baseline behind the alert thresholds is 3h18m, not 24 hours.** See
  "Known limits" in `alerts/README.md`.
