# Repository layout

```
bench/CONTRACT.md         the interfaces terraform, cloud-init and CI code against
bench/src/profile.zig     c100, c1k, c10k — the ramp parameters, compiled in
bench/src/suite.zig       the per-proxy loop; the only place an error is caught
bench/src/ramp.zig        one ramp, embedding zrk's runner.run in-process
bench/src/cadvisor.zig    1Hz container sampling + the identity witness
bench/src/analysis.zig    the measurement math (ported from the old report.py)
bench/src/{svg,html}.zig  inline-SVG charts -> a self-contained report.html
bench/src/http.zig        the one bounded HTTP client (std.http.Client has no deadline)
bench/src/{ycs,commands}  Object Storage, the compute sweep, the CLI
compose.yaml              every service, proxies behind profiles, limits enforced
compose.cloud.yaml        host networking + cpuset + peer-IP overlay
proxies/<p>/              one static config per proxy (upstream is the backend0..3 pool)
backend/                  nginx origin, canned bodies generated at start (x4)
cloud/                    terraform: VPC + 6 ephemeral VMs, no public IPs
docs/METHODOLOGY.md       what is measured, and what makes the numbers comparable
docs/RUNNING.md           profiles, the make targets, CI, the local caveat
docs/SETUP.md             the one-time cloud setup CI cannot do for you
.github/workflows/        ci.yml (every push) + the nightly
```
