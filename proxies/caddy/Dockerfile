# Stock caddy is HTTP-only; the L4 benchmark needs the layer4 app
# (github.com/mholt/caddy-l4), which only ships as a source plugin — bake it
# in with xcaddy. The builder tag pins the caddy version to the runtime image.
# caddy 2.11 (not 2.9): caddy-l4 v0.1.1 requires caddy/v2@v2.11.3 and
# go >= 1.25 — neither of which older builders satisfy.
FROM caddy:2.11-builder AS builder
RUN xcaddy build --with github.com/mholt/caddy-l4@v0.1.1

FROM caddy:2.11
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
