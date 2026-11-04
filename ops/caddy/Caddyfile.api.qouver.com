# api.qouver.com - one-time edit of the server's Caddyfile, then never again.
#
# The live site currently has handlers for several applications (/majadu,
# /hooks, /sds, /skyward). The cutover must not replace that site block: it only
# swaps which handler snippet the /majadu subtree uses.
#
# 1. Install the three snippets and the switchable symlink:
#      /srv/qouver/apps/majadu/caddy/{site-v1,site-v2,site-maintenance}.caddy
#      /srv/qouver/apps/majadu/caddy/active.caddy -> site-v1.caddy
#    (cutover.sh copies them from ops/caddy/ and manages the symlink.)
#
# 2. Replace the two-line /majadu handler in /etc/caddy/Caddyfile with the
#    import:
#
#      handle /majadu/* {
#          uri strip_prefix /majadu
#          reverse_proxy 127.0.0.1:8080
#      }
#    becomes
#      import /srv/qouver/apps/majadu/caddy/active.caddy
#
# 3. Keep share codes out of the access log. In the same site block, add the
#    matcher and one directive to the existing log statement:
#
#      @share path /majadu/s/*
#      log {
#          import log_access
#          skip_log @share
#      }
#
#    `skip_log` needs Caddy 2.7+. The rest of log_access (output, format) stays
#    as it is, so other applications keep their logs unchanged.
#
# 4. Validate and reload before trusting it:
#      caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
#      sudo systemctl reload caddy
#
# The snippets themselves are handler blocks:
#   site-v1.caddy          -> reverse proxy 127.0.0.1:8080 (v1, schema bm)
#   site-v2.caddy          -> reverse proxy 127.0.0.1:8080 (v2, schema bm2)
#   site-maintenance.caddy -> 503 + Retry-After for /majadu/*, other handlers live
#
# `X-Client-IP` is written by the proxy and client XFF/X-Real-IP are dropped.
# The API only reads X-Client-IP from a trusted peer, so the two sides agree on
# which header is the truth.
