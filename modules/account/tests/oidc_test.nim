import std/[strutils, unittest, uri]
import ../infrastructure/oidc

proc config(secret: string): OidcConfig =
  OidcConfig(authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
    tokenUrl: "https://oauth2.googleapis.com/token",
    jwksUrl: "https://www.googleapis.com/oauth2/v3/certs",
    issuer: "https://accounts.google.com", clientId: "client-1",
    clientSecret: secret, redirectUri: "https://majadu.vercel.app/api/auth/callback")

suite "token exchange request":
  test "a configured secret is sent, because a web client is confidential":
    let body = tokenRequestBody(config("s3cret"), "the-code", "the-verifier")
    check body == "grant_type=authorization_code&code=the-code" &
      "&client_id=client-1" &
      "&redirect_uri=" & encodeUrl("https://majadu.vercel.app/api/auth/callback") &
      "&code_verifier=the-verifier&client_secret=s3cret"

  test "a public client without a secret sends no empty parameter":
    let body = tokenRequestBody(config(""), "the-code", "the-verifier")
    check not body.contains("client_secret")

  test "the code and the verifier are encoded, not spliced in":
    let body = tokenRequestBody(config("a&b"), "co de", "ver&ifier")
    check body.contains("code=co+de")
    check body.contains("code_verifier=ver%26ifier")
    check body.contains("client_secret=a%26b")