# Caddy site untuk majadu-api — tambahkan ke /etc/caddy/Caddyfile di VPS.
# Syarat: DNS api.qouver.com → A → 198.51.100.10 (Cloudflare).
# Setelah ditambah: systemctl reload caddy

api.qouver.com {
	# prod instance (bm) — frontend branch main (dev /majadu-dev di-sunset 2026-09-04)
	handle /majadu/* {
		uri strip_prefix /majadu
		reverse_proxy 127.0.0.1:8080
	}
	handle {
		respond "not found" 404
	}
}
