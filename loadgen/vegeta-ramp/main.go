// vegeta-ramp: an open-loop LINEAR-RAMP HTTP load generator built on Vegeta's
// library LinearPacer (the CLI only does constant -rate). It offers a rate that
// climbs 0 -> MAX_RATE over RAMP_SECONDS and, crucially, keeps offering at the
// scheduled rate even when the target falls behind (true open loop, coordinated-
// omission-safe), so a proxy's saturation shows as a latency/throughput knee
// instead of the generator quietly throttling.
//
// Output is a per-1s-window CSV whose offered-rate column is ANALYTIC
// (offered = START + SLOPE*t), so the tipping point on the offered-load axis is
// exact. report.py joins this with cAdvisor/node_exporter CPU from Prometheus.
//
// Config via env:
//   TARGET        full URL, e.g. http://10.10.0.34:8080/1k   (required)
//   MAX_RATE      req/s at the end of the ramp                (default 200000)
//   RAMP_SECONDS  ramp length                                 (default 120)
//   START_RATE    req/s at t=0                                (default 200)
//   CONNECTIONS   keep-alive pool size (MaxIdleConnsPerHost)  (default 20000)
//   MAX_WORKERS   in-flight cap (open-loop guard, ~= max concurrency) (default 20000)
//   TIMEOUT_S     per-request response timeout, seconds       (default 5)
//   OUT           CSV output path                             (default /results/ramp.csv)
//   NAME          label for logs (proxy name)                 (default ramp)
package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strconv"
	"time"

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

func pct(sorted []time.Duration, p float64) float64 {
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

	fmt.Fprintf(os.Stderr, "vegeta-ramp[%s]: %s  0..%d rps over %ds (slope=%.0f/s), conns<=%d, maxWorkers=%d\n",
		name, target, maxRate, rampSecs, slope, conns, maxWorkers)

	windows := map[int]*window{}
	dur := time.Duration(rampSecs) * time.Second
	start := time.Now()
	lastLog := 0

	for res := range atk.Attack(targeter, pacer, dur, name) {
		sec := int(res.Timestamp.Sub(start).Seconds())
		if sec < 0 {
			sec = 0
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
		if sec >= lastLog+5 && sec > 0 {
			lastLog = sec
			offered := float64(startRate) + slope*float64(sec)
			prev := windows[sec-1]
			if prev != nil {
				sort.Slice(prev.lat, func(i, j int) bool { return prev.lat[i] < prev.lat[j] })
				fmt.Fprintf(os.Stderr, "  t=%3ds offered=%7.0f achieved=%7d ok/s  p99=%6.1fms err=%4.1f%%\n",
					sec, offered, prev.ok, pct(prev.lat, 0.99),
					100*float64(prev.total-prev.ok)/float64(max(prev.total, 1)))
			}
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

	peakAchieved, peakOffered := 0, 0.0
	kneeOffered := 0.0 // first offered where achieved drops below 95% of offered
	for _, s := range secs {
		w := windows[s]
		sort.Slice(w.lat, func(i, j int) bool { return w.lat[i] < w.lat[j] })
		offered := float64(startRate) + slope*float64(s)
		errRatio := float64(w.total-w.ok) / float64(max(w.total, 1))
		fmt.Fprintf(bw, "%d,%.0f,%d,%d,%d,%.4f,%.3f,%.3f,%d\n",
			s, offered, w.total, w.ok, w.ok, errRatio, pct(w.lat, 0.50), pct(w.lat, 0.99), w.bytesIn)
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
