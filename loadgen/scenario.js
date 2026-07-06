// Open-loop k6 scenario: constant arrival rate (NOT closed-loop conns/latency).
// One process = one generator host driving RATE req/s at the proxy for DURATION.
// The orchestrator runs this on all M loadgen hosts at RATE/M each and sums.
//
// Latency here is coordinated-omission-free *as long as maxVUs is never
// exhausted* — if it is, k6 reports `dropped_iterations` and run_cell (see
// scripts/run.sh) voids the cell, as it does when the error rate exceeds
// load.max_error_rate. Aggregate percentiles across the M hosts come from Prometheus
// (each k6 remote-writes native histograms); the local summary is a backup.
import http from 'k6/http';
import { check } from 'k6';

const TARGET = __ENV.TARGET; // e.g. http://10.10.0.5:8080 or https://10.10.0.5:8443
const REQ_PATH = __ENV.REQ_PATH || '/64';
const RATE = parseInt(__ENV.RATE || '1000', 10);
const DURATION = __ENV.DURATION || '30s';
const MAX_VUS = parseInt(__ENV.MAX_VUS || '4000', 10);

export const options = {
  discardResponseBodies: true, // keep the client cheap
  insecureSkipTLSVerify: true, // self-signed fixture cert
  noConnectionReuse: false, // keep-alive on the client->proxy hop
  scenarios: {
    load: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      // enough VUs that the open loop never blocks waiting for a free VU
      preAllocatedVUs: Math.min(MAX_VUS, Math.max(64, Math.ceil(RATE / 20))),
      maxVUs: MAX_VUS,
    },
  },
};

export default function () {
  const res = http.get(`${TARGET}${REQ_PATH}`);
  check(res, { 'status is 200': (r) => r.status === 200 });
}
