import std/net
import mummy
import webby/httpheaders

proc fakeRequest*(peer: string,
                  headers: openArray[(string, string)] = []): Request =
  ## Builds a RequestObj without a socket. Only the fields the middleware reads
  ## are populated; `respond` must never be called on it.
  let request = cast[Request](alloc0(sizeof(RequestObj)))
  request.remoteAddress = peer
  request.httpMethod = "GET"
  request.path = "/"
  request.headers = emptyHttpHeaders()
  for (key, value) in headers:
    request.headers[key] = value
  request
