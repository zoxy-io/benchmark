// vegeta-ramp: an open-loop LINEAR-RAMP HTTP load generator built on Vegeta's
// library LinearPacer (the CLI only does constant -rate). It offers a rate that
// climbs 0 -> MAX_RATE over RAMP_SECONDS and, crucially, keeps offering at the
// scheduled rate even when the target falls behind (true open loop, coordinated-
// omission-safe), so a proxy's saturation shows as a sharp latency/throughput
// knee instead of the generator quietly throttling.
//
// Output is a per-1s-window CSV whose offered-rate column is ANALYTIC
// (offered = start_rate + slope*t) — the source of record for report_vegeta.py.
// It ALSO exports a Prometheus /metrics endpoint (gauges for the current window,
// labeled proxy+testid) so the live Grafana dashboard has throughput/latency
// while a ramp runs. The endpoint is up only for the lifetime of the process.
//
// Config via env:
//   TARGET        full URL, e.g. http://10.10.0.34:8080/1k   (required)
//   MAX_RATE      req/s at the end of the ramp                (default 200000)
//   RAMP_SECONDS  ramp length                                 (default 120)
//   START_RATE    req/s at t=0                                (default 200)
//   CONNECTIONS   keep-alive pool (MaxIdleConnsPerHost)       (default 20000)
//   MAX_WORKERS   in-flight cap (open-loop guard)             (default 20000)
//   TIMEOUT_S     per-request response timeout, seconds       (default 5)
//   OUT           CSV output path                             (default /results/ramp.csv)
//   NAME          proxy label (logs + `proxy` metric label)   (default ramp)
//   RUNID         `testid` metric label                       (default adhoc)
//   METRICS_ADDR  Prometheus /metrics listen addr             (default :8090)
package main

import (
	"bufio"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	vegeta "github.com/tsenart/vegeta/v12/lib"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
func envi(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

type window struct {
	total, ok int
	bytesIn   uint64
	lat       []time.Duration // OK-request latencies for percentiles
}

func pctMs(sorted []time.Duration, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	i := int(p * float64(len(sorted)))
	if i >= len(sorted) {
		i = len(sorted) - 1
	}
	return float64(sorted[i].Microseconds()) / 1000.0 // ms
}

func main() {
	target := env("TARGET", "")
	if target == "" {
		fmt.Fprintln(os.Stderr, "vegeta-ramp: TARGET is required")
		os.Exit(2)
	}
	maxRate := envi("MAX_RATE", 200000)
	rampSecs := envi("RAMP_SECONDS", 120)
	startRate := envi("START_RATE", 200)
	conns := envi("CONNECTIONS", 20000)
	maxWorkers := envi("MAX_WORKERS", 20000)
	timeoutS := envi("TIMEOUT_S", 5)
	outPath := env("OUT", "/results/ramp.csv")
	name := env("NAME", "ramp")
	runid := env("RUNID", "adhoc")
	metricsAddr := env("METRICS_ADDR", ":8090")

	// --- Prometheus /metrics (current-window gauges, proxy+testid labels) ------
	labels := prometheus.Labels{"proxy": name, "testid": runid}
	gOffered := prometheus.NewGauge(prometheus.GaugeOpts{Name: "vegeta_offered_rps", Help: "offered req/s (analytic ramp rate)", ConstLabels: labels})
	gAchieved := prometheus.NewGauge(prometheus.GaugeOpts{Name: "vegeta_achieved_rps", Help: "successful req/s in the last window", ConstLabels: labels})
	gErr := prometheus.NewGauge(prometheus.GaugeOpts{Name: "vegeta_errors_ratio", Help: "non-2xx / error ratio in the last window", ConstLabels: labels})
	gLat := prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "vegeta_latency_seconds", Help: "per-window latency percentile (seconds)", ConstLabels: labels}, []string{"quantile"})
	reg := prometheus.NewRegistry()
	reg.MustRegister(gOffered, gAchieved, gErr, gLat)
	go func() {
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
		if err := http.ListenAndServe(metricsAddr, mux); err != nil {
			fmt.Fprintf(os.Stderr, "vegeta-ramp: metrics server: %v\n", err)
		}
	}()

	slope := float64(maxRate-startRate) / float64(rampSecs) // hits/s per second
	pacer := vegeta.LinearPacer{
		StartAt: vegeta.Rate{Freq: startRate, Per: time.Second},
		Slope:   slope,
	}
	targeter := vegeta.NewStaticTargeter(vegeta.Target{Method: "GET", URL: target})
	atk := vegeta.NewAttacker(
		vegeta.KeepAlive(true),
		vegeta.Connections(conns),
		vegeta.Workers(500),
		vegeta.MaxWorkers(uint64(maxWorkers)),
		vegeta.Timeout(time.Duration(timeoutS)*time.Second),
	)

	fmt.Fprintf(os.Stderr, "vegeta-ramp[%s]: %s  0..%d rps over %ds (slope=%.0f/s), conns<=%d, maxWorkers=%d, metrics %s\n",
		name, target, maxRate, rampSecs, slope, conns, maxWorkers, metricsAddr)

	windows := map[int]*window{}
	dur := time.Duration(rampSecs) * time.Second
	start := time.Now()
	lastSec := -1

	// publish a completed window's stats to the live gauges (and log every 5s)
	publish := func(sec int) {
		w := windows[sec]
		if w == nil {
			return
		}
		sort.Slice(w.lat, func(i, j int) bool { return w.lat[i] < w.lat[j] })
		offered := float64(startRate) + slope*float64(sec)
		errRatio := float64(w.total-w.ok) / float64(max(w.total, 1))
		gOffered.Set(offered)
		gAchieved.Set(float64(w.ok))
		gErr.Set(errRatio)
		gLat.WithLabelValues("0.5").Set(pctMs(w.lat, 0.50) / 1000.0)
		gLat.WithLabelValues("0.95").Set(pctMs(w.lat, 0.95) / 1000.0)
		gLat.WithLabelValues("0.99").Set(pctMs(w.lat, 0.99) / 1000.0)
		if sec%5 == 0 {
			fmt.Fprintf(os.Stderr, "  t=%3ds offered=%7.0f achieved=%7d ok/s  p99=%6.1fms err=%4.1f%%\n",
				sec, offered, w.ok, pctMs(w.lat, 0.99), 100*errRatio)
		}
	}

	for res := range atk.Attack(targeter, pacer, dur, name) {
		sec := int(res.Timestamp.Sub(start).Seconds())
		if sec < 0 {
			sec = 0
		}
		if sec > lastSec {
			if lastSec >= 0 {
				publish(lastSec) // the window that just closed
			}
			lastSec = sec
		}
		w := windows[sec]
		if w == nil {
			w = &window{}
			windows[sec] = w
		}
		w.total++
		if res.Code == 200 && res.Error == "" {
			w.ok++
			w.bytesIn += res.BytesIn
			w.lat = append(w.lat, res.Latency)
		}
	}

	// write CSV, sorted by window
	f, err := os.Create(outPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "vegeta-ramp: cannot write %s: %v\n", outPath, err)
		os.Exit(1)
	}
	defer f.Close()
	bw := bufio.NewWriter(f)
	fmt.Fprintln(bw, "elapsed_s,offered_rps,total,ok,achieved_rps,err_ratio,p50_ms,p99_ms,bytes_in")
	secs := make([]int, 0, len(windows))
	for s := range windows {
		secs = append(secs, s)
	}
	sort.Ints(secs)

	peakAchieved, peakOffered, kneeOffered := 0, 0.0, 0.0
	for _, s := range secs {
		w := windows[s]
		sort.Slice(w.lat, func(i, j int) bool { return w.lat[i] < w.lat[j] })
		offered := float64(startRate) + slope*float64(s)
		errRatio := float64(w.total-w.ok) / float64(max(w.total, 1))
		fmt.Fprintf(bw, "%d,%.0f,%d,%d,%d,%.4f,%.3f,%.3f,%d\n",
			s, offered, w.total, w.ok, w.ok, errRatio, pctMs(w.lat, 0.50), pctMs(w.lat, 0.99), w.bytesIn)
		if w.ok > peakAchieved {
			peakAchieved, peakOffered = w.ok, offered
		}
		if kneeOffered == 0 && s >= 3 && float64(w.ok) < 0.95*offered {
			kneeOffered = offered
		}
	}
	bw.Flush()

	fmt.Fprintf(os.Stderr, "vegeta-ramp[%s]: peak achieved=%d ok/s (at offered %.0f); knee (achieved<95%% offered) at offered=%.0f\n",
		name, peakAchieved, peakOffered, kneeOffered)
	fmt.Fprintf(os.Stderr, "vegeta-ramp[%s]: wrote %s (%d windows)\n", name, outPath, len(secs))
}
