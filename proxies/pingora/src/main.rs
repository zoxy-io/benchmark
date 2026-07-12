//! Minimal L4 (TCP passthrough) proxy built on Cloudflare Pingora, for the
//! proxy benchmark. Pingora is a framework, not a ready-made proxy, so this is
//! the smallest program that stands a Pingora server whose app copies bytes
//! bidirectionally between each accepted downstream connection and a freshly
//! dialed upstream TCP connection — the same one-tunnel-per-connection L4
//! semantics as haproxy `mode tcp` / envoy tcp_proxy / traefik TCP router.
//!
//! We use Pingora's `ServerApp` (its accept loop, runtime, graceful shutdown,
//! listener handling) but dial the upstream with a plain per-connection
//! `TcpStream` rather than Pingora's pooling connector: L4 tunnels can't be
//! multiplexed over a reused upstream socket, so a fresh dial per downstream
//! connection is the correct — and fair — behaviour.
//!
//! Knobs via env (set by compose, matching the other proxies):
//!   THREADS   worker threads for the listening service (= PROXY_CPUS)
//!   LISTEN    downstream bind (default 0.0.0.0:8080)
//!   UPSTREAM  upstream host:port (default backend:9000), resolved ONCE at
//!             startup with retry (parity with zoxy's no-runtime-DNS model).

use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use pingora_core::apps::ServerApp;
use pingora_core::protocols::Stream;
use pingora_core::server::configuration::{Opt, ServerConf};
use pingora_core::server::{Server, ShutdownWatch};
use pingora_core::services::listening::Service;
use tokio::net::TcpStream;

struct L4Proxy {
    upstream: SocketAddr,
}

#[async_trait]
impl ServerApp for L4Proxy {
    async fn process_new(
        self: &Arc<Self>,
        mut downstream: Stream,
        _shutdown: &ShutdownWatch,
    ) -> Option<Stream> {
        match TcpStream::connect(self.upstream).await {
            Ok(mut upstream) => {
                let _ = upstream.set_nodelay(true);
                // one tunnel: pump both directions until either half closes
                let _ = tokio::io::copy_bidirectional(&mut downstream, &mut upstream).await;
            }
            Err(e) => eprintln!("pingora-l4: upstream {} connect failed: {e}", self.upstream),
        }
        None // L4 passthrough holds no keep-alive downstream state to reuse
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
        eprintln!("pingora-l4: waiting to resolve {host_port} ({i}/40)");
        std::thread::sleep(Duration::from_millis(500));
    }
    panic!("pingora-l4: cannot resolve upstream {host_port} — is the backend up?");
}

fn main() {
    let listen = std::env::var("LISTEN").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    let upstream = std::env::var("UPSTREAM").unwrap_or_else(|_| "backend:9000".to_string());
    let threads: usize = std::env::var("THREADS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1);

    let addr = resolve_with_retry(&upstream);
    eprintln!("pingora-l4: listen={listen} upstream={upstream} -> {addr} threads={threads}");

    // threads = PROXY_CPUS: explicit thread parity with the other proxies.
    let mut conf = ServerConf::default();
    conf.threads = threads;
    let mut server = Server::new_with_opt_and_conf(Opt::default(), conf);
    server.bootstrap();

    // Service::new takes the app by value (it Arc-wraps it internally; the
    // ServerApp callback receives &Arc<Self>).
    let mut svc = Service::new("pingora-l4".to_string(), L4Proxy { upstream: addr });
    svc.add_tcp(&listen);
    server.add_service(svc);

    server.run_forever();
}
