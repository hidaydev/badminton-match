import std/[os, strutils]
import mummy

proc trustedProxies*(): seq[string] =
  ## Only these peers may assert a client address. Defaults to loopback, which is
  ## where Caddy sits in every deployment we ship.
  let raw = getEnv("MAJADU_TRUSTED_PROXIES", "127.0.0.1,::1")
  for part in raw.split(','):
    let trimmed = part.strip()
    if trimmed.len > 0:
      result.add(trimmed)

proc peerProxied*(request: Request, trusted: seq[string]): bool =
  let peer = request.remoteAddress
  peer in trusted or peer.startsWith("127.") and "127.0.0.1" in trusted

proc clientIp*(request: Request, trusted: seq[string]): string =
  ## `X-Forwarded-For` is never read: it is client-controlled and chains are
  ## ambiguous. `X-Client-IP` is written by Caddy and is only honoured when the
  ## TCP peer is a trusted proxy.
  if peerProxied(request, trusted):
    let forwarded = request.headers["X-Client-IP"]
    if forwarded.len > 0:
      return forwarded
  request.remoteAddress
