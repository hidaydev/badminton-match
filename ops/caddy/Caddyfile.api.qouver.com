# Site file for api.qouver.com - copy to /etc/caddy/Caddyfile (or import it from
# there) and reload Caddy.
#
# The active snippet is a symlink the operator never edits by hand:
#   /srv/qouver/apps/majadu/caddy/active.caddy -> site-v1.caddy
#                                              -> site-v2.caddy
#                                              -> site-maintenance.caddy
# cutover.sh, rollback.sh and deploy failure handling move that symlink and run
# `caddy validate` before every reload, so a bad switch is refused instead of
# taking the site down.

import /srv/qouver/apps/majadu/caddy/active.caddy
