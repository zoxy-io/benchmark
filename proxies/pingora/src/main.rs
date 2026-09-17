//! Minimal HTTP/1.1 reverse proxy on Pingora for the proxy benchmark.
//!
//! Strict round-robin over a fixed pool (an atomic counter, not
//! pingora-load-balancing, to avoid health-check machinery no other proxy
//! runs here). Upstream leg is plaintext; TLS only terminates inbound.
//!
//! Env (set by compose):
//!   LISTEN      downstream bind (default 0.0.0.0:8080)
//!   TLS_LISTEN  TLS bind; unset or empty = no TLS listener
//!   TLS_CERT / TLS_KEY  PEM paths (default /etc/bench/tls/bench.{crt,key})
//!   UPSTREAMS   comma-separated host:port pool (default backend0..3:9000),
//!               resolved once at startup
//!   ACCESS_LOG  access log file (default /tmp/access.log)

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

/// Per-request state for access-log timing. `new_ctx` runs once per request,
/// after the header is parsed, so idle keep-alive time is excluded.
struct Ctx {
    start: Instant,
}

/// Scratch space the access log reuses for every line.
struct LogState {
    /// Unix second `stamp` was rendered for.
    second: i64,
    /// The formatted timestamp of that second, cached per second like nginx
    /// and haproxy do, so pingora is not charged a date format per request.
    stamp: String,
    /// The line under construction, written with one `write_all`: `write!`
    /// to a `File` makes a syscall per fragment.
    line: String,
}

thread_local! {
    /// Thread-local, not a mutex: there is exactly one worker thread.
    static LOG_STATE: RefCell<LogState> = RefCell::new(LogState {
        second: 0,
        stamp: String::new(),
        line: String::new(),
    });
}

/// One access-log line to the access-log file.
///
/// Pingora has no stock format: NCSA combined plus request duration.
/// Referer/user-agent are literal `-` (the generator sends neither).
/// The byte count includes response headers (pingora's `body_bytes_sent()`),
/// unlike nginx's `$body_bytes_sent`; left uncorrected.
/// Unbuffered, to a file: a stdout pipe would block on dockerd.
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
            // Six decimals: at millisecond resolution every request logs 0.000.
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

        // Errors and short writes are ignored: the proxy must not die or
        // stall because its log sink did.
        let _ = out.lock().unwrap().write_all(line.as_bytes());
    });
}

struct HttpProxy {
    upstreams: Vec<SocketAddr>,
    next: AtomicUsize,
    /// The access-log sink. A `Mutex` because `ProxyHttp` is shared across
    /// workers; with one thread it is never contended.
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

    /// Strict round-robin over the pool, plain HTTP, no SNI. Pingora's pool is
    /// keyed by peer, so each backend keeps its own warm connections.
    /// `Relaxed` is fine: an occasional skipped index is harmless.
    async fn upstream_peer(
        &self,
        _session: &mut Session,
        _ctx: &mut Self::CTX,
    ) -> Result<Box<HttpPeer>> {
        let i = self.next.fetch_add(1, Ordering::Relaxed) % self.upstreams.len();
        Ok(Box::new(HttpPeer::new(self.upstreams[i], false, String::new())))
    }

    /// Pingora's access-log phase, after the response or a failure. Status `0`
    /// means no response was written.
    async fn logging(&self, session: &mut Session, _e: Option<&pingora_core::Error>, ctx: &mut Self::CTX) {
        let status = session.response_written().map_or(0, |r| r.status.as_u16());
        access_log(&self.log, session, status, ctx.start.elapsed());
    }
}

/// Resolve host:port once, retrying so a backend that is not yet resolvable
/// is a transient wait, not a crash.
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
    // Unset or empty means no TLS listener: compose renders an empty string on
    // plaintext turns.
    let tls_listen = std::env::var("TLS_LISTEN")
        .ok()
        .filter(|s| !s.trim().is_empty());
    let tls_cert =
        std::env::var("TLS_CERT").unwrap_or_else(|_| "/etc/bench/tls/bench.crt".to_string());
    let tls_key =
        std::env::var("TLS_KEY").unwrap_or_else(|_| "/etc/bench/tls/bench.key".to_string());
    let upstreams = std::env::var("UPSTREAMS")
        .unwrap_or_else(|_| "backend0:9000,backend1:9000,backend2:9000,backend3:9000".to_string());
    let access_log_path =
        std::env::var("ACCESS_LOG").unwrap_or_else(|_| "/tmp/access.log".to_string());

    // All-or-nothing: a dropped member would round-robin over three backends.
    let addrs: Vec<SocketAddr> = upstreams
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(resolve_with_retry)
        .collect();
    assert!(!addrs.is_empty(), "pingora-http: UPSTREAMS is empty");

    // Fail at startup rather than serve without the access log.
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

    // 1 worker thread, parity with the other proxies.
    let mut conf = ServerConf::default();
    conf.threads = 1;
    // No work stealing: with one thread, NoSteal is a single current-thread
    // runtime without the multi-thread scheduler's overhead.
    conf.work_stealing = false;
    // Default pool is 128 (per-thread LRU), which churns under load. Sized
    // total across four peers, since round-robin rotates each client through
    // all of them.
    conf.upstream_keepalive_pool_size = 512 * 4;
    let mut server = Server::new_with_opt_and_conf(Opt::default(), conf);
    server.bootstrap();

    // Pingora's HTTP/1.1 proxy service (accept loop + upstream pool).
    let mut svc = pingora_proxy::http_proxy_service(
        &server.configuration,
        HttpProxy {
            upstreams: addrs,
            next: AtomicUsize::new(0),
            log: Mutex::new(log),
        },
    );
    svc.add_tcp(&listen);
    // TLS on the same service: one ProxyHttp, upstream pool and access log.
    // Panic on failure so it is a start failure, not a silent zero-throughput
    // listener.
    if let Some(addr) = &tls_listen {
        svc.add_tls(addr, &tls_cert, &tls_key).unwrap_or_else(|e| {
            panic!("pingora-http: cannot serve TLS on {addr} with {tls_cert}/{tls_key}: {e}")
        });
    }
    server.add_service(svc);

    server.run_forever();
}
