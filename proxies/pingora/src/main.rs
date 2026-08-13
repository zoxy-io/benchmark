//! Minimal L7 (HTTP/1.1 reverse-proxy) proxy built on Cloudflare Pingora, for
//! the proxy benchmark. Pingora is a framework, not a ready-made proxy, so this
//! is the smallest program that stands a Pingora HTTP proxy: it parses each
//! request, forwards it to the origin over a POOLED, KEPT-ALIVE upstream
//! connection, and streams the response back — the same L7 job as haproxy
//! `mode http` / envoy http_connection_manager / traefik HTTP router / zoxy's
//! phase-1 `protocol: http` listener.
//!
//! We use Pingora's `pingora_proxy::http_proxy_service` (its accept loop,
//! runtime, HTTP/1.1 state machine, graceful shutdown, and — crucially — its
//! upstream connection pool, so the backend leg is kept alive and reused across
//! requests, matching the other L7 proxies). All this proxy has to supply is
//! the upstream peer via `ProxyHttp::upstream_peer`.
//!
//! The upstream is a four-node POOL, picked strict round-robin — the same
//! policy haproxy (`balance roundrobin`), envoy (`ROUND_ROBIN`) and zoxy
//! (`"pick": "rr"`) are pinned to, so the comparison stays proxy-vs-proxy.
//! Pingora ships `pingora-load-balancing` with exactly this, but pulling in a
//! selection framework — with its health-check background service and discovery
//! machinery — to rotate a fixed four-element array would add moving parts the
//! other proxies do not have here (no proxy health-checks the pool in this run;
//! nginx even had its default passive checks turned off for parity).
//! An atomic counter is the whole algorithm.
//!
//! Every request is ACCESS-LOGGED via the `logging` hook, to the same
//! /tmp/access.log file the other proxies write (haproxy `option httplog` with
//! its fd redirected by compose, nginx `access_log`, envoy `FileAccessLog`).
//! Pingora ships no access log of its own, so `access_log` below picks the
//! format rather than reproducing one.
//!
//!   ACCESS_LOG  where that file goes (default /tmp/access.log)
//!
//! On a TLS profile it listens TWICE: plaintext on LISTEN and TLS on
//! TLS_LISTEN, both served by the same `http_proxy_service`, so the request
//! path is identical and the only difference is the transport. TLS_LISTEN is
//! empty on a plaintext turn and no TLS endpoint is added at all then — see
//! compose.yaml's x-proxy-common for why a plaintext profile must not carry
//! one. TLS is terminated here and the upstream leg stays plaintext
//! (`HttpPeer::new(.., false, ..)` below), which is what every proxy in this
//! comparison does: zoxy terminates inbound only, so an encrypted upstream
//! would be a job it cannot do.
//!
//! Knobs via env (set by compose, matching the other proxies):
//!   LISTEN      downstream bind (default 0.0.0.0:8080)
//!   TLS_LISTEN  downstream TLS bind; unset or empty = no TLS listener
//!   TLS_CERT / TLS_KEY  PEM paths for that listener (default /etc/bench/tls/
//!               bench.crt and bench.key — the run's own ECDSA P-256
//!               self-signed pair, generated on the proxy host and mounted
//!               read-only; all five proxies load the same key material,
//!               because the signature is per handshake and an RSA key would
//!               charge one proxy CPU the others never pay)
//!   UPSTREAMS  comma-separated host:port pool (default backend0..backend3:9000),
//!              each resolved ONCE at startup with retry (parity with zoxy's
//!              no-runtime-DNS model).

use std::cell::RefCell;
use std::fmt::Write as FmtWrite;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use pingora_core::server::configuration::{Opt, ServerConf};
use pingora_core::server::Server;
use pingora_core::upstreams::peer::HttpPeer;
use pingora_core::Result;
use pingora_proxy::{ProxyHttp, Session};

/// Per-request state, existing only to time the request for the access log.
///
/// `new_ctx` runs once per REQUEST — pingora calls it after reading the request
/// header and before any filter, and calls it again for each subsequent request
/// on a kept-alive connection (pingora-proxy's `process_new_http`). So this
/// clock starts at "header parsed" and stops in `logging`, which is the
/// proxy's own handling time and excludes waiting for a client that has not
/// sent anything yet.
struct Ctx {
    start: Instant,
}

/// Scratch space the access log reuses for every line.
struct LogState {
    /// Unix second `stamp` was rendered for.
    second: i64,
    /// The formatted timestamp of that second.
    ///
    /// nginx and haproxy both keep a cached time string and refresh it on a
    /// tick rather than formatting a calendar date per request. Doing the same
    /// here is not tuning pingora past its peers, it is refusing to handicap it
    /// against them: at 40k requests/sec a naive `format()` per line would
    /// charge pingora 40k date conversions a second that nginx and haproxy do
    /// not pay.
    stamp: String,
    /// The line under construction.
    ///
    /// Assembled in memory and written with ONE `write_all`, which is the whole
    /// reason it exists. `write!` straight at a `File` goes through
    /// `Write::write_fmt`, and that issues a syscall per formatted fragment —
    /// a dozen writes per request where nginx does one. (Writing to `println!`
    /// hid this: Rust's stdout is a `LineWriter`, so it coalesces to the
    /// newline on its own. A file handle does not.)
    line: String,
}

thread_local! {
    /// A `thread_local!` and not a mutex because this proxy is hardcoded to one
    /// worker thread (`conf.threads = 1` below), so there is exactly one of
    /// these and it is never contended.
    static LOG_STATE: RefCell<LogState> = RefCell::new(LogState {
        second: 0,
        stamp: String::new(),
        line: String::new(),
    });
}

/// One access-log line to the access-log file.
///
/// Pingora ships NO access log — it is a framework, and `logging()` is the hook
/// its own examples use to emit one. So unlike the other four proxies here
/// there is no stock format to reproduce, and this is a choice rather than a
/// default: the NCSA "combined" shape nginx also writes, plus the request
/// duration, which is the field a proxy operator actually deploys an access log
/// for (haproxy's `option httplog` and envoy's default line both carry timings).
///
/// The referer and user-agent slots are literal `-`: the generator sends
/// neither, so reproducing combined's shape faithfully costs two header lookups
/// that can only ever return nothing.
///
/// The byte count sits in combined's `$body_bytes_sent` position but is NOT
/// what nginx puts there. Pingora's `body_bytes_sent()` documents itself as
/// "response body bytes (application, not wire)" and then adds the serialized
/// response header to it as well (pingora-core's v1/server.rs, in
/// `write_response_header`) — measured here as 1259 for a 1024-byte body. So
/// this field is total response bytes, which happens to agree with haproxy's
/// `%B` and zoxy's `bytes_out` and to disagree with nginx's. Recorded rather
/// than corrected: subtracting the header would mean tracking it separately to
/// make one proxy's log agree with another's, and the formats here are
/// deliberately each proxy's own.
///
/// One unbuffered `write_all` per line, at a FILE and not at stdout. Writing to
/// stdout means writing to a pipe dockerd drains, and a proxy that fills that
/// pipe blocks on the log write — measuring docker's log driver rather than the
/// proxy. A file write lands in page cache and returns. That gives pingora the
/// same discipline as nginx's unbuffered `access_log`, against envoy's timed
/// flush and zoxy's drop-on-backpressure queue.
fn access_log(out: &Mutex<File>, session: &Session, status: u16, elapsed: Duration) {
    let req = session.req_header();
    let client = match session.client_addr() {
        Some(a) => a.to_string(),
        None => "-".to_string(),
    };

    let now = chrono::Utc::now();
    let secs = now.timestamp();
    LOG_STATE.with(|state| {
        // Destructured so `line` and `stamp` are disjoint borrows: the format
        // below reads one while writing the other.
        let LogState { second, stamp, line } = &mut *state.borrow_mut();
        if *second != secs || stamp.is_empty() {
            *second = secs;
            stamp.clear();
            let _ = write!(stamp, "{}", now.format("%d/%b/%Y:%H:%M:%S %z"));
        }

        line.clear();
        let _ = writeln!(
            line,
            // Six decimals, not nginx's three. `$request_time`'s millisecond
            // resolution rounds every request in this benchmark to `0.000`
            // (zoxy measures the same work at ~230us), and a latency field that
            // is constant is worse than no field: it costs the same bytes and
            // carries nothing.
            "{} - - [{}] \"{} {} {:?}\" {} {} \"-\" \"-\" {:.6}",
            client,
            stamp,
            req.method,
            req.uri,
            req.version,
            status,
            session.body_bytes_sent(),
            elapsed.as_secs_f64(),
        );

        // Errors are dropped on purpose: a proxy must not die because its log
        // sink did. A short write is not retried for the same reason — the run
        // is measuring the cost of logging, and a partial line is a cosmetic
        // problem where a stalled event loop would be a measurement one.
        let _ = out.lock().unwrap().write_all(line.as_bytes());
    });
}

struct HttpProxy {
    upstreams: Vec<SocketAddr>,
    next: AtomicUsize,
    /// The access-log sink, opened once at startup and appended to per request.
    ///
    /// A `Mutex` because `ProxyHttp` is shared across workers by contract; with
    /// `conf.threads = 1` there is only ever one, so it is never contended.
    log: Mutex<File>,
}

#[async_trait]
impl ProxyHttp for HttpProxy {
    type CTX = Ctx;
    fn new_ctx(&self) -> Self::CTX {
        Ctx {
            start: Instant::now(),
        }
    }

    /// The one required hook: name the upstream for this request. Strict
    /// round-robin over the pool, plain HTTP (no TLS), no SNI. Pingora dials it
    /// through its connection pool and reuses idle keep-alive connections
    /// automatically — the pool is keyed by peer, so each backend keeps its own
    /// warm connections rather than the four sharing one set.
    ///
    /// `Relaxed` is the right ordering: the counter carries no data and orders
    /// nothing else, and a rare duplicate or skipped index under contention is
    /// a rounding error in the spread, not a correctness problem. It is moot
    /// anyway at threads=1 — this is a single-threaded runtime, so there is no
    /// second thread to race with.
    async fn upstream_peer(
        &self,
        _session: &mut Session,
        _ctx: &mut Self::CTX,
    ) -> Result<Box<HttpPeer>> {
        let i = self.next.fetch_add(1, Ordering::Relaxed) % self.upstreams.len();
        Ok(Box::new(HttpPeer::new(self.upstreams[i], false, String::new())))
    }

    /// Called once the response has been fully sent downstream, or the request
    /// died — pingora's designated access-log phase. See `access_log` for why
    /// the format is a choice here and a reproduction everywhere else.
    ///
    /// A request that failed before a response was written has no status; `0`
    /// records that rather than inventing one, the same value pingora's own
    /// example logs in that case.
    async fn logging(&self, session: &mut Session, _e: Option<&pingora_core::Error>, ctx: &mut Self::CTX) {
        let status = session.response_written().map_or(0, |r| r.status.as_u16());
        access_log(&self.log, session, status, ctx.start.elapsed());
    }
}

/// Resolve host:port once, retrying so a not-yet-ready backend DNS name at
/// startup is a transient wait, not a crash (compose gates backends healthy
/// first; cloud maps `backend0`..`backend3` via /etc/hosts).
fn resolve_with_retry(host_port: &str) -> SocketAddr {
    for i in 1..=40 {
        if let Ok(mut addrs) = host_port.to_socket_addrs() {
            if let Some(a) = addrs.next() {
                return a;
            }
        }
        eprintln!("pingora-http: waiting to resolve {host_port} ({i}/40)");
        std::thread::sleep(Duration::from_millis(500));
    }
    panic!("pingora-http: cannot resolve upstream {host_port} — is the backend up?");
}

fn main() {
    let listen = std::env::var("LISTEN").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    // Unset OR EMPTY means "no TLS listener": compose renders this from
    // PROXY_TLS_PORT, which `bench` sets only for a TLS profile, and an empty
    // string has to mean the same as absent or a plaintext turn would bind one
    // anyway. A plaintext turn must be the same process it was before TLS
    // existed here — see compose.yaml's x-proxy-common.
    let tls_listen = std::env::var("TLS_LISTEN")
        .ok()
        .filter(|s| !s.trim().is_empty());
    let tls_cert =
        std::env::var("TLS_CERT").unwrap_or_else(|_| "/etc/bench/tls/bench.crt".to_string());
    let tls_key =
        std::env::var("TLS_KEY").unwrap_or_else(|_| "/etc/bench/tls/bench.key".to_string());
    let upstreams = std::env::var("UPSTREAMS")
        .unwrap_or_else(|_| "backend0:9000,backend1:9000,backend2:9000,backend3:9000".to_string());
    // Same path every proxy in this benchmark logs to; see access_log for why
    // it is a file and why it is /tmp.
    let access_log_path =
        std::env::var("ACCESS_LOG").unwrap_or_else(|_| "/tmp/access.log".to_string());

    // All-or-nothing: resolve_with_retry panics rather than skipping a member,
    // because a pingora quietly round-robining across three backends while
    // every other proxy uses four is a throughput difference that reads as a
    // proxy difference.
    let addrs: Vec<SocketAddr> = upstreams
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(resolve_with_retry)
        .collect();
    assert!(!addrs.is_empty(), "pingora-http: UPSTREAMS is empty");

    // Opened HERE, before the server starts, and unwrapped: a proxy that cannot
    // open its access log has not been configured the way the run recorded, and
    // silently serving without one would put a number on the chart that no
    // other proxy earned. Failing at startup makes it the harness's
    // start-failure path instead, which reports the reason.
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&access_log_path)
        .unwrap_or_else(|e| panic!("pingora-http: cannot open {access_log_path}: {e}"));

    eprintln!(
        "pingora-http: listen={listen} tls_listen={} upstreams={upstreams} -> {} peers, pick=roundrobin, threads=1, access_log={access_log_path}",
        tls_listen.as_deref().unwrap_or("none"),
        addrs.len()
    );

    // hardcoded to 1 worker thread — 1 CPU, thread parity with the other proxies.
    let mut conf = ServerConf::default();
    conf.threads = 1;
    // Default work_stealing=true runs Tokio's multi-thread (work-stealing)
    // scheduler even with threads=1, paying its cross-worker steal-queue/park
    // machinery for zero benefit (nothing to steal from with one worker).
    // false swaps in pingora-runtime's NoSteal flavor — a single current-thread
    // runtime, which pingora's own docs call "as efficient as the
    // single-threaded runtime" — pure upside at threads=1.
    conf.work_stealing = false;
    // Default upstream_keepalive_pool_size is 128 (and it's a per-thread LRU,
    // so with threads=1 that's the effective cap) — well under CONNECTIONS=500,
    // so under load the idle-connection pool churns and reopens fresh upstream
    // TCP connections instead of reusing them. Matches nginx's `keepalive`
    // (parity: envoy raises its circuit-breaker max_connections the same way).
    //
    // Times the pool size, because this is the TOTAL pool and it is now shared
    // across four peers. Round-robin is per REQUEST, so a downstream connection
    // rotates through every backend and wants a warm connection to each — 512
    // total would leave ~128 per peer and reintroduce exactly the churn the
    // previous paragraph exists to prevent.
    conf.upstream_keepalive_pool_size = 512 * 4;
    let mut server = Server::new_with_opt_and_conf(Opt::default(), conf);
    server.bootstrap();

    // http_proxy_service wraps our ProxyHttp in Pingora's HTTP/1.1 proxy
    // service (accept loop + upstream pool); we just add the TCP listener.
    let mut svc = pingora_proxy::http_proxy_service(
        &server.configuration,
        HttpProxy {
            upstreams: addrs,
            next: AtomicUsize::new(0),
            log: Mutex::new(log),
        },
    );
    svc.add_tcp(&listen);
    // The TLS endpoint on the SAME service, so both transports run through one
    // ProxyHttp, one upstream pool and one access log.
    //
    // Unwrapped for the same reason the access log is opened before the server
    // starts: a pingora that came up without the listener the run is about to
    // ramp against would answer nothing at all on that port, and the harness
    // would record it as a proxy that served zero rather than as one that was
    // never configured. Failing here makes it a start failure, which reports
    // the reason (`docker logs` via reportStartFailure).
    if let Some(addr) = &tls_listen {
        svc.add_tls(addr, &tls_cert, &tls_key).unwrap_or_else(|e| {
            panic!("pingora-http: cannot serve TLS on {addr} with {tls_cert}/{tls_key}: {e}")
        });
    }
    server.add_service(svc);

    server.run_forever();
}
