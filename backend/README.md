# backend/

The origin is defined declaratively in [`../nix/backend.nix`](../nix/backend.nix)
and baked into the image, not deployed at runtime — so every backend host is
byte-identical and there's nothing to converge.

It is nginx on `:9000` serving canned, fixed-size bodies generated once into the
Nix store:

| Path | Size |
| --- | --- |
| `/64` | 64 B |
| `/1k` | 1 KiB |
| `/10k` | 10 KiB |
| `/100k` | 100 KiB |

`access_log` is off, `keepalive_requests` is effectively unbounded (no mid-run
GOAWAY), `worker_processes auto`. It exists only to *not be the bottleneck*: the
saturation self-check (`../loadgen/self_check.sh`) voids any run where a backend
saturates before the proxy does.

To change sizes or the responder, edit `nix/backend.nix` and rebuild the image.
