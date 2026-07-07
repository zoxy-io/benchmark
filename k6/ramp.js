// The measurement: 30s constant warmup, then ONE linear open-loop ramp
// 0 -> MAX_RATE over RAMP_DURATION.
//
// HARD INVARIANT: every proxy gets the identical ramp (same MAX_RATE, same
// duration). That makes elapsed-time == offered-rate the same affine map for
// every run, which is what lets the report overlay sequential runs on a
// shared offered-rate x-axis.
//
// Saturation is NOT detected here — thresholds evaluate cumulatively, so a
// collapsing error rate gets diluted by the clean early minutes, and aborting
// at the knee would throw away the post-knee failure shape (graceful p99
// growth vs error cliff) that the report wants to show. The single threshold
// below is only a dead-proxy valve. report.py finds the knee post-hoc from
// Prometheus.
//
// Open-loop + maxVUs guardrail (kept from v1): arrival rate is independent of
// responses (coordinated-omission-free); when the proxy stalls, k6 drops
// iterations (k6_dropped_iterations in Prometheus) instead of opening
// unbounded connections and DoSing the fleet.
import http from 'k6/http';
import { check } from 'k6';

const TARGET = __ENV.TARGET; // e.g. http://haproxy:8080
const REQ_PATH = __ENV.REQ_PATH || '/1k';
const MAX_RATE = parseInt(__ENV.MAX_RATE || '20000', 10);
const RAMP_DURATION = __ENV.RAMP_DURATION || '8m';
const WARM_RATE = parseInt(__ENV.WARM_RATE || '100', 10);
const MAX_VUS = parseInt(__ENV.MAX_VUS || '2000', 10);

export const options = {
  discardResponseBodies: true,
  scenarios: {
    warmup: {
      executor: 'constant-arrival-rate',
      rate: WARM_RATE,
      timeUnit: '1s',
      duration: '30s',
      preAllocatedVUs: 50,
      maxVUs: 200,
      tags: { phase: 'warmup' },
    },
    ramp: {
      executor: 'ramping-arrival-rate',
      startTime: '30s',
      startRate: 0,
      timeUnit: '1s',
      stages: [{ duration: RAMP_DURATION, target: MAX_RATE }],
      // preallocate the pool up front: growing it mid-run causes transient
      // dropped iterations that would read as false saturation
      preAllocatedVUs: MAX_VUS,
      maxVUs: MAX_VUS,
      tags: { phase: 'ramp' },
    },
  },
  thresholds: {
    // dead-proxy valve ONLY (see header) — saturation is found post-hoc. The
    // bar is deliberately near-total failure: a proxy shedding/degrading under
    // load (e.g. rejecting excess connections) is NOT dead, and aborting it
    // would (a) discard its post-knee shape and (b) make the abort point
    // ramp-slope-dependent (the valve fires on wall-clock, so a steeper ramp is
    // further up the offered axis at 120s). Only a corpse trips this.
    'http_req_failed{phase:ramp}': [
      { threshold: 'rate<0.98', abortOnFail: true, delayAbortEval: '120s' },
    ],
  },
};

export default function () {
  const res = http.get(`${TARGET}${REQ_PATH}`);
  check(res, { 'status is 200': (r) => r.status === 200 });
}

// Offline backup of the aggregate numbers; the real data lives in Prometheus.
export function handleSummary(data) {
  const runid = __ENV.RUNID || 'adhoc';
  const proxy = __ENV.PROXY || 'unknown';
  return {
    [`/results/${runid}/${proxy}.summary.json`]: JSON.stringify(data, null, 2),
    stdout: `\nramp done: proxy=${proxy} runid=${runid} max_rate=${MAX_RATE} duration=${RAMP_DURATION}\n`,
  };
}
