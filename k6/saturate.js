// Closed-loop MAX-THROUGHPUT probe — NOT the benchmark ramp. Used to find a
// proxy's true saturation point when open-loop can't offer enough (the ramp's
// loadgen goes CPU-bound on dropped-iteration bookkeeping before the proxy's
// core saturates). Here each VU loops request->response back-to-back with no
// arrival timer and no drops, so achieved rate self-settles at exactly what
// the proxy can serve, and loadgen CPU stays low (no scheduling/drop waste).
//
// VU COUNT IS THE KNOB and the invariant: total concurrent VUs == concurrent
// connections held. Keep it UNDER zoxy's 1024-tunnel shed cap. When split
// across N loadgen hosts, it's the SUM across hosts that must stay <1024 —
// each host runs VUS/N, tagged with a distinct LG so Prometheus keeps them as
// separate series that sum cleanly by proxy.
import http from 'k6/http';
import { check } from 'k6';

const TARGET = __ENV.TARGET;
const REQ_PATH = __ENV.REQ_PATH || '/1k';
const VUS = parseInt(__ENV.VUS || '900', 10);
const DURATION = __ENV.DURATION || '2m';
const N = __ENV.N || String(VUS); // concurrency level tag for the sweep

export const options = {
  discardResponseBodies: true,
  scenarios: {
    saturate: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
      tags: { phase: 'saturate' },
    },
  },
  // no abort valve: this probe expects to run a saturated proxy hot, not
  // declare it dead. Errors are read post-hoc from Prometheus.
};

export default function () {
  const res = http.get(`${TARGET}${REQ_PATH}`);
  check(res, { 'status is 200': (r) => r.status === 200 });
}

export function handleSummary(data) {
  const runid = __ENV.RUNID || 'adhoc';
  const proxy = __ENV.PROXY || 'unknown';
  return {
    [`/results/${runid}/${proxy}.n${N}.json`]: JSON.stringify(data, null, 2),
    stdout: `\nsweep point done: proxy=${proxy} n=${N} vus=${VUS} reqs=${data.metrics.http_reqs.values.count}\n`,
  };
}
