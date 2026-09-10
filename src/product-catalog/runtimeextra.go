// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"errors"
	"math"
	"runtime/metrics"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	otelmetric "go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/sdk/instrumentation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"go.opentelemetry.io/otel/semconv/v1.41.0/goconv"
)

// The OTel Go runtime semantic conventions mark three metrics as opt-in:
// go.cpu.time, go.memory.gc.cycles and go.memory.gc.pause.duration. The
// conventions define them and go.opentelemetry.io/otel/semconv/v1.41.0/goconv
// ships typed constructors for them, but
// go.opentelemetry.io/contrib/instrumentation/runtime implements only the nine
// "recommended" metrics, so nothing emits these three by default. See
// https://github.com/open-telemetry/semantic-conventions/blob/main/docs/runtime/go-metrics.md
//
// This file fills that gap using the same goconv constructors contrib itself
// uses, so the names, units, descriptions and attributes stay convention-exact.
const runtimeExtraScope = "github.com/intergral/opentelemetry-cf-demo/runtimeextra"

// Go runtime/metrics keys. The four CPU classes below are disjoint and sum to
// /cpu/classes/total:cpu-seconds, which is what lets a query total go_cpu_time
// across go.cpu.state to get GOMAXPROCS x wall time. The optional
// go.cpu.detailed_state attribute is deliberately not emitted: those classes
// are subdivisions of the ones here, so reporting both would double count.
const (
	goCPUUser     = "/cpu/classes/user:cpu-seconds"
	goCPUGC       = "/cpu/classes/gc/total:cpu-seconds"
	goCPUScavenge = "/cpu/classes/scavenge/total:cpu-seconds"
	goCPUIdle     = "/cpu/classes/idle:cpu-seconds"
	goGCCyclesAll = "/gc/cycles/total:gc-cycles"
	goGCPauses    = "/gc/pauses:seconds"
)

// startRuntimeExtraMetrics registers the opt-in go.cpu.time and
// go.memory.gc.cycles instruments against the global meter provider. Both are
// plain cumulative scalars in runtime/metrics, so they use the ordinary
// asynchronous metric API; only the histogram needs a metric.Producer.
func startRuntimeExtraMetrics() error {
	meter := otel.GetMeterProvider().Meter(runtimeExtraScope)

	cpuTime, err := goconv.NewCPUTimeObservable(meter)
	if err != nil {
		return err
	}
	gcCycles, err := goconv.NewMemoryGCCyclesObservable(meter)
	if err != nil {
		return err
	}

	cpuClasses := []struct {
		key  string
		attr attribute.KeyValue
	}{
		{goCPUUser, cpuTime.AttrCPUState(goconv.CPUStateUser)},
		{goCPUGC, cpuTime.AttrCPUState(goconv.CPUStateGC)},
		{goCPUScavenge, cpuTime.AttrCPUState(goconv.CPUStateScavenge)},
		{goCPUIdle, cpuTime.AttrCPUState(goconv.CPUStateIdle)},
	}

	samples := make([]metrics.Sample, 0, len(cpuClasses)+1)
	for _, c := range cpuClasses {
		samples = append(samples, metrics.Sample{Name: c.key})
	}
	samples = append(samples, metrics.Sample{Name: goGCCyclesAll})

	// samples is reused across invocations, and a provider with more than one
	// reader may collect concurrently. Contrib guards its own callback the
	// same way.
	var mu sync.Mutex
	_, err = meter.RegisterCallback(
		func(_ context.Context, o otelmetric.Observer) error {
			mu.Lock()
			defer mu.Unlock()
			metrics.Read(samples)
			for i, c := range cpuClasses {
				if samples[i].Value.Kind() == metrics.KindFloat64 {
					o.ObserveFloat64(cpuTime.Inst(), samples[i].Value.Float64(),
						otelmetric.WithAttributes(c.attr))
				}
			}
			if s := samples[len(samples)-1]; s.Value.Kind() == metrics.KindUint64 {
				o.ObserveInt64(gcCycles.Inst(), int64(s.Value.Uint64()))
			}
			return nil
		},
		cpuTime.Inst(),
		gcCycles.Inst(),
	)
	return err
}

// gcPauseProducer emits go.memory.gc.pause.duration. The Go runtime exposes GC
// stop-the-world pauses as a pre-computed histogram, which cannot be recorded
// through the metric API, so it is supplied to the reader as a
// metric.Producer — the same mechanism contrib uses for go.schedule.duration.
type gcPauseProducer struct {
	mu     sync.Mutex
	sample []metrics.Sample
	start  time.Time
}

var _ sdkmetric.Producer = (*gcPauseProducer)(nil)

func newGCPauseProducer() *gcPauseProducer {
	return &gcPauseProducer{
		sample: []metrics.Sample{{Name: goGCPauses}},
		start:  time.Now(),
	}
}

func (p *gcPauseProducer) Produce(context.Context) ([]metricdata.ScopeMetrics, error) {
	p.mu.Lock()
	metrics.Read(p.sample)
	v := p.sample[0].Value
	p.mu.Unlock()

	if v.Kind() != metrics.KindFloat64Histogram {
		return nil, errors.New("unable to obtain go.memory.gc.pause.duration metric from the runtime")
	}
	dps := convertRuntimeHistogram(v.Float64Histogram(), p.start, time.Now())
	if len(dps) == 0 {
		return nil, errors.New("go.memory.gc.pause.duration histogram was empty")
	}

	// A Producer has to assemble metricdata by hand, so take the metric's
	// identity from goconv rather than restating it, to keep it convention-exact.
	// Name, Unit and Description have value receivers and need no instrument.
	var desc goconv.MemoryGCPauseDuration
	return []metricdata.ScopeMetrics{{
		Scope: instrumentation.Scope{Name: runtimeExtraScope},
		Metrics: []metricdata.Metrics{{
			Name:        desc.Name(),
			Description: desc.Description(),
			Unit:        desc.Unit(),
			Data: metricdata.Histogram[float64]{
				Temporality: metricdata.CumulativeTemporality,
				DataPoints:  dps,
			},
		}},
	}}, nil
}

// convertRuntimeHistogram maps a runtime/metrics histogram onto an OTel
// histogram data point. It mirrors the conversion contrib performs for
// go.schedule.duration: runtime bucket boundaries are lower-inclusive while
// OTel boundaries are upper bounds, and the runtime exposes no sum.
func convertRuntimeHistogram(h *metrics.Float64Histogram, start, now time.Time) []metricdata.HistogramDataPoint[float64] {
	if h == nil || len(h.Buckets) < 2 {
		return nil
	}
	// Drop the first boundary: it is the lower bound of the first bucket, and
	// OTel boundaries are upper bounds only.
	bounds := h.Buckets[1:]
	counts := h.Counts
	if bounds[len(bounds)-1] == math.Inf(1) {
		// The +Inf overflow bucket is implicit in OTel. Every current runtime
		// histogram ends in +Inf, but the layout is explicitly not guaranteed
		// (see runtime/metrics docs), so the other case is handled too.
		bounds = bounds[:len(bounds)-1]
	} else {
		// No overflow bucket in the source, so the implicit one sees nothing.
		// Copy rather than append in place: metrics.Read reuses these slices.
		counts = append(append([]uint64{}, counts...), 0)
	}

	var count uint64
	var sum float64
	for i, c := range counts {
		count += c
		// The runtime gives no sum, so approximate by attributing each
		// observation to its bucket's lower bound. This underestimates.
		if i > 0 && c != 0 {
			sum += bounds[i-1] * float64(c)
		}
	}

	return []metricdata.HistogramDataPoint[float64]{{
		StartTime:    start,
		Time:         now,
		Count:        count,
		Sum:          sum,
		Bounds:       bounds,
		BucketCounts: counts,
		Attributes:   *attribute.EmptySet(),
	}}
}
