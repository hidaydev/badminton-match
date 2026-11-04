import std/[json, options, strutils]

type
  CreateProblem* = enum
    cpInvalidSlug = "invalid_slug"
    cpInvalidName = "invalid_name"
    cpInvalidAdminEmail = "invalid_admin_email"

  CreateCheck* = object
    problems*: seq[CreateProblem]
    slug*: string
    timezone*: string

const slugMinLength = 2
const slugMaxLength = 40
const slugChars = {'a'..'z', '0'..'9', '-'}

proc normalizeSlug*(raw: string): string =
  ## Lowercase, collapse separators and trim hyphens. Anything outside the
  ## allowlist is an error rather than being silently dropped, so two different
  ## names can never normalise into the same slug by accident.
  var lowered = ""
  for c in raw.strip().toLowerAscii():
    case c
    of ' ', '_': lowered.add('-')
    of slugChars: lowered.add(c)
    else: raise newException(ValueError, "slug contains an unsupported character")
  while lowered.contains("--"):
    lowered = lowered.replace("--", "-")
  lowered = lowered.strip(chars = {'-'})
  if lowered.len < slugMinLength or lowered.len > slugMaxLength:
    raise newException(ValueError, "slug must be 2-40 characters")
  lowered

proc validEmail*(value: string): bool =
  ## Deliberately minimal: the address is only used to attach the first admin
  ## and is stored hashed, so this rejects obvious noise without pretending to
  ## implement RFC 5322.
  if value.count('@') != 1 or value.contains(' ') or value.contains('\t'):
    return false
  let parts = value.split('@')
  parts[0].len > 0 and parts[1].contains('.') and not parts[1].startsWith('.') and
    not parts[1].endsWith('.')

proc resolveTimezone*(requested: Option[string], registryDefault: string): string =
  ## The default is always the registry value; there is no built-in fallback.
  if requested.isSome and requested.get.strip().len > 0:
    requested.get.strip()
  else:
    registryDefault

proc checkCreate*(slug, name, adminEmail: string,
                  registryTimezone: string,
                  timezone: Option[string]): CreateCheck =
  result.timezone = resolveTimezone(timezone, registryTimezone)
  try:
    result.slug = normalizeSlug(slug)
  except ValueError:
    result.problems.add(cpInvalidSlug)
  if name.strip().len == 0:
    result.problems.add(cpInvalidName)
  if not validEmail(adminEmail):
    result.problems.add(cpInvalidAdminEmail)

proc directoryEnabled*(platformDefault: bool, settings: JsonNode,
                       key: string): bool =
  ## A community flips the directory on through its own settings; the platform
  ## value is the default and the ceiling.
  if settings.kind == JObject and settings.hasKey(key) and
     settings[key].kind == JBool:
    return settings[key].getBool()
  platformDefault

proc directoryVisible*(enabled, isMember: bool): bool =
  ## A disabled directory is a 404 for everyone; an enabled one is still only
  ## readable by members.
  enabled and isMember

proc directoryEntry*(slug, name: string): JsonNode =
  ## The directory never exposes counts, owners or settings.
  %*{"slug": slug, "name": name}
