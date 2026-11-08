## TL-16: the mock API's route matcher.
##
## `matches` decides which recorded operation answers a request, so a change to
## the `{param}` rule or to the literal comparison changes the mock silently.
## The server itself is not started: the table and the handler are thin, and the
## matcher is the surface a regression hides in.
import std/unittest

import ../main

suite "mock api route matcher":
  test "a parameter segment matches one non-empty segment":
    check matches("/c/{slug}/members", "/c/club/members")
    check matches("/c/{slug}/members", "/c/other/members")
    check matches("/{id}", "/42")

  test "a different segment count never matches":
    check not matches("/c/{slug}/members", "/c/club")
    check not matches("/c/{slug}/members", "/c/club/members/extra")
    check not matches("/c", "/c/")

  test "an empty segment never satisfies a parameter":
    check not matches("/c/{slug}/members", "/c//members")

  test "a literal segment must be equal":
    check not matches("/c/{slug}/members", "/c/club/players")
    check not matches("/c/{slug}/members", "/d/club/members")
    # The trailing empty segment of a rooted path is compared literally.
    check not matches("/c/{slug}/members", "c/club/members")