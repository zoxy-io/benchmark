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
//! Knobs via env (set by compose, matching the other proxies):
//!   LISTEN     downstream bind (default 0.0.0.0:8080)
//!   UPSTREAMS  comma-separated host:port pool (default backend0..backend3:9000),
//!              each resolved ONCE at startup with retry (parity with zoxy's
//!              no-runtime-DNS model).

use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use pingora_core::server::configuration::{Opt, ServerConf};
use pingora_core::server::Server;
use pingora_core::upstreams::peer::HttpPeer;
use pingora_core::Result;
use pingora_proxy::{ProxyHttp, Session};

struct HttpProxy {
    upstreams: Vec<SocketAddr>,
    next: AtomicUsize,
}

#[async_trait]
impl ProxyHttp for HttpProxy {
    type CTX = ();
    fn new_ctx(&self) -> Self::CTX {}

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
    let upstreams = std::env::var("UPSTREAMS")
        .unwrap_or_else(|_| "backend0:9000,backend1:9000,backend2:9000,backend3:9000".to_string());

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
    eprintln!(
        "pingora-http: listen={listen} upstreams={upstreams} -> {} peers, pick=roundrobin, threads=1",
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
        },
    );
    svc.add_tcp(&listen);
    server.add_service(svc);

    server.run_forever();
}
