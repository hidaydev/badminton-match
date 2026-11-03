import std/json
import logger

type
  Problem* = object
    status*: int
    code*: string
    i18nKey*: string
    detail*: string

proc newProblem*(status: int, code, i18nKey: string, detail = ""): Problem =
  Problem(status: status, code: code, i18nKey: i18nKey, detail: detail)

proc toJson*(problem: Problem): string =
  ## RFC 9457-shaped body. Detail is redacted like any other log-bound value.
  let node = %*{
    "type": "about:blank",
    "title": problem.code,
    "status": problem.status,
    "code": problem.code,
    "i18nKey": problem.i18nKey,
    "detail": redact(problem.detail),
  }
  $node
