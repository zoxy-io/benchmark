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
//! Knobs via env (set by compose, matching the other proxies):
//!   LISTEN    downstream bind (default 0.0.0.0:8080)
//!   UPSTREAM  upstream host:port (default backend:9000), resolved ONCE at
//!             startup with retry (parity with zoxy's no-runtime-DNS model).

use std::net::{SocketAddr, ToSocketAddrs};
use std::time::Duration;

use async_trait::async_trait;
use pingora_core::server::configuration::{Opt, ServerConf};
use pingora_core::server::Server;
use pingora_core::upstreams::peer::HttpPeer;
use pingora_core::Result;
use pingora_proxy::{ProxyHttp, Session};

struct HttpProxy {
    upstream: SocketAddr,
}

#[async_trait]
impl ProxyHttp for HttpProxy {
    type CTX = ();
    fn new_ctx(&self) -> Self::CTX {}

    /// The one required hook: name the upstream for this request. A fixed
    /// single origin, plain HTTP (no TLS), no SNI. Pingora dials it through its
    /// connection pool and reuses idle keep-alive connections automatically.
    async fn upstream_peer(
        &self,
        _session: &mut Session,
        _ctx: &mut Self::CTX,
    ) -> Result<Box<HttpPeer>> {
        Ok(Box::new(HttpPeer::new(self.upstream, false, String::new())))
    }
}

/// Resolve host:port once, retrying so a not-yet-ready backend DNS name at
/// startup is a transient wait, not a crash (compose gates backend healthy
/// first; cloud maps `backend` via /etc/hosts).
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
    let upstream = std::env::var("UPSTREAM").unwrap_or_else(|_| "backend:9000".to_string());

    let addr = resolve_with_retry(&upstream);
    eprintln!("pingora-http: listen={listen} upstream={upstream} -> {addr} threads=1");

    // hardcoded to 1 worker thread — 1 CPU, thread parity with the other proxies.
    let mut conf = ServerConf::default();
    conf.threads = 1;
    let mut server = Server::new_with_opt_and_conf(Opt::default(), conf);
    server.bootstrap();

    // http_proxy_service wraps our ProxyHttp in Pingora's HTTP/1.1 proxy
    // service (accept loop + upstream pool); we just add the TCP listener.
    let mut svc = pingora_proxy::http_proxy_service(
        &server.configuration,
        HttpProxy { upstream: addr },
    );
    svc.add_tcp(&listen);
    server.add_service(svc);

    server.run_forever();
}
