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
  ## The peer must be one of the configured addresses exactly. A prefix rule
  ## ("any 127/8 peer") would let a second local process, a sidecar, or a
  ## container on the same host assert an address of its choosing, and the
  ## address is the key for every anonymous bucket. `::1` is honoured only when
  ## it is in the list, because mummy reports the IPv6 form of loopback
  ## separately from the IPv4 one.
  request.remoteAddress in trusted

proc forwardedIp*(request: Request, trusted: seq[string]): string =
  ## The address a trusted proxy asserted, or empty when this peer may not
  ## speak for a client. The header is unsigned, so it is only ever read from
  ## the edge that terminates the connection.
  if peerProxied(request, trusted):
    let forwarded = request.headers["X-Client-IP"]
    if forwarded.len > 0:
      return forwarded
  ""

proc clientIp*(request: Request, trusted: seq[string]): string =
  ## `X-Forwarded-For` is never read: it is client-controlled and chains are
  ## ambiguous. `X-Client-IP` is written by Caddy and is only honoured when the
  ## TCP peer is a trusted proxy.
  let forwarded = forwardedIp(request, trusted)
  if forwarded.len > 0:
    return forwarded
  request.remoteAddress
