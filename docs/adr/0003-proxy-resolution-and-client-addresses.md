# ADR-0003: Per-request upstream resolution and trusted client addresses

- Date: 2026-10-06
- Status: accepted

## Context

All sites share one nginxproxy. Its site configurations declared static `upstream <slug>_nginx` blocks, which nginx resolves when it starts or reloads. When one project's nginx container was stopped outside `deactivate.sh` or crashed, the next proxy restart or reload failed with `host not found in upstream`, taking every site offline. The proxy also used nginx's default 60-second read timeout while project nginx allowed 300 seconds, so long Moodle operations (course restore, large uploads) failed at the proxy with 504.

Every request passes through two nginx layers. Project nginx did not process `X-Forwarded-For`, so PHP's `REMOTE_ADDR`, and therefore Moodle's logs, IP restrictions, and login throttling, always showed nginxproxy's Docker address. The previous README workaround, switching Moodle's *Logged IP address source* to `HTTP_X_FORWARDED_FOR`, lets clients choose the recorded address.

## Options

1. Keep static upstreams and document the failure mode (status quo).
2. Resolve each project's container per request through Docker's embedded DNS.
3. Replace nginxproxy with a proxy that discovers containers dynamically (Traefik or Caddy).

For client addresses:

1. Configure Moodle to read `X-Forwarded-For` (`getremoteaddrconf`, `reverseproxyignore`).
2. Use nginx's realip module in project nginx, trusting private peers and taking the last `X-Forwarded-For` entry.

## Decision

Resolve upstreams per request (option 2): each site configuration sets `resolver 127.0.0.11` and passes `$mooship_upstream` to `proxy_pass`. A missing project produces 502 for its own domain only; configuration checks no longer depend on running containers. The proxy streams request bodies (`proxy_request_buffering off`) and uses the same 300-second read and send timeouts as project nginx. Option 3 remains a candidate for a larger redesign: it would also remove certbot containers and SSL block toggling, but it changes the archive format, certificates, and every operational script.

Use nginx's realip module (client option 2). `set_real_ip_from` covers the private ranges that Docker allocates networks from, and `real_ip_recursive off` takes only the last `X-Forwarded-For` entry, which nginxproxy appends from its TCP peer. Moodle keeps its default `REMOTE_ADDR` source. Recursive mode was rejected because clients on private networks (for example a university LAN) would then let a forged header through.

Project nginx's port-80 server redirects to HTTPS except ACME challenges; `lib/web.py` already replaces that server for `--no-ssl`, so HTTP sites are unaffected.

## Consequences

Existing proxies keep their copy of `site-template.conf`, and existing `sites/<slug>.conf` files keep static upstreams until an administrator regenerates them; deployment warns when the copy differs from the bundled template. Per-request resolution adds a cached DNS lookup (`valid=10s`) per site. The trusted ranges assume project nginx is reachable only through Docker networks, which holds because it publishes no host ports.

## Validation

`tests/test_http_roundtrip.py` runs real nginx → nginx → PHP-FPM containers: PHP must see the client container's address with and without a forged `X-Forwarded-For`; removing a project's nginx must leave `nginx -t` and `nginx -s reload` working on the proxy, which then answers 502. It also checks the HTTPS redirect, ACME over HTTP, the Moodle router fallback, and X-Accel-Redirect. `tests/test_web.py` checks the templates.

References: [ngx_http_realip_module](https://nginx.org/en/docs/http/ngx_http_realip_module.html), [proxy_pass with variables and resolver](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_pass), [Moodle: Configuring the Router](https://docs.moodle.org/en/Configuring_the_Router).
