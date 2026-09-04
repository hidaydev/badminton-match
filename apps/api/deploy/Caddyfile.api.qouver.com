# Caddy site untuk majadu-api — tambahkan ke /etc/caddy/Caddyfile di VPS.
# Syarat: DNS api.qouver.com → A → 198.51.100.10 (Cloudflare).
# Setelah ditambah: systemctl reload caddy

api.qouver.com {
	# dev instance (bm_dev) — frontend branch ui-revamp
	handle /majadu-dev/* {
		uri strip_prefix /majadu-dev
		reverse_proxy 127.0.0.1:8081
	}
	# prod instance (bm) — frontend branch main
	handle /majadu/* {
		uri strip_prefix /majadu
		reverse_proxy 127.0.0.1:8080
	}
	handle {
		respond "not found" 404
	}
}
