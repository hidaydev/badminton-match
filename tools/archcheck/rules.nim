import std/[strutils]

const
  domainTables = ["session.", "player.", "rating.", "tournament.", "community."]
  # `cli.nim` is the process edge for every tool: `dsnOrFail` reads the DSN that
  # used to be read in sixteen `main.nim` files.
  envAllowlist = ["shared/platform-lib/clock.nim", "shared/platform-lib/cli.nim"]

proc envAllowed(file: string): bool =
  ## Environment reads belong to the process edge (apps/, tools/) and to
  ## infrastructure adapters that build their configuration from it.
  file.startsWith("apps/") or file.startsWith("tools/") or
    file in envAllowlist or file.contains("/infrastructure/")

proc stripStrings(lines: seq[string]): seq[string] =
  ## Removes string literal contents (both "..." and triple-quoted blocks) so SQL
  ## `now()` and `?` are not mistaken for Nim code.
  var triple = false
  var quoted = false
  for line in lines:
    var rendered = ""
    var index = 0
    while index < line.len:
      let c = line[index]
      if triple:
        if index + 2 < line.len and c == '"' and line[index + 1] == '"' and
           line[index + 2] == '"':
          triple = false
          index += 3
        else:
          index.inc
      elif quoted:
        if c == '\\':
          index += 2
        elif c == '"':
          quoted = false
          index.inc
        else:
          index.inc
      elif index + 2 < line.len and c == '"' and line[index + 1] == '"' and
           line[index + 2] == '"':
        triple = true
        index += 3
      elif c == '"':
        quoted = true
        index.inc
      else:
        rendered.add(c)
        index.inc
    result.add(rendered)

proc literalEnd(source: string, start: int): int =
  ## Index just past the literal that opens at `start`, which is a double quote.
  if start + 2 < source.len and source[start + 1] == '"' and
     source[start + 2] == '"':
    var index = start + 3
    while index + 2 < source.len:
      if source[index] == '"' and source[index + 1] == '"' and
         source[index + 2] == '"':
        return index + 3
      inc index
    return source.len
  var index = start + 1
  while index < source.len and source[index] != '"':
    if source[index] == '\\' and index + 1 < source.len:
      inc index
    inc index
  if index < source.len:
    inc index
  index

proc literalBody(source: string, start, finish: int): string =
  let triple = start + 2 < finish and source[start + 1] == '"' and
               source[start + 2] == '"'
  let first = start + (if triple: 3 else: 1)
  let last = finish - (if triple: 3 else: 1)
  if last <= first: "" else: source[first ..< last]

type
  SqlStatement* = object
    ## One `&` chain of literals and named constants, folded into the single
    ## value the database receives.
    text*: string
    offset*: int

  TokenKind = enum
    tkLiteral, tkAmp, tkIdent, tkOther

  Token = object
    kind: TokenKind
    text: string
    pos: int

proc tokenize(source: string): seq[Token] =
  ## Strings are tokens; comments are dropped. Identifier tokens include the
  ## dots of a qualified name, so `a.b` is one name that no constant binds.
  var index = 0
  while index < source.len:
    let c = source[index]
    if c == '#':
      while index < source.len and source[index] != '\n':
        inc index
    elif c == '"':
      let finish = literalEnd(source, index)
      result.add(Token(kind: tkLiteral, text: literalBody(source, index, finish),
        pos: index))
      index = finish
    elif c == '&':
      result.add(Token(kind: tkAmp, text: "&", pos: index))
      inc index
    elif c in {'A'..'Z', 'a'..'z', '_'}:
      let start = index
      while index < source.len and
            source[index] in {'A'..'Z', 'a'..'z', '0'..'9', '_', '.'}:
        inc index
      result.add(Token(kind: tkIdent, text: source[start ..< index], pos: start))
    elif c in {' ', '\t', '\n', '\r'}:
      inc index
    else:
      result.add(Token(kind: tkOther, text: $c, pos: index))
      inc index

const bindingKeywords = ["const", "let", "var"]

proc bindingStarts(tokens: seq[Token]): seq[(string, int)] =
  ## `const name* = "..."` and `let name = ...` bind a name to the string
  ## expression after the `=`; a type annotation between name and `=` is
  ## skipped. Only string expressions are recorded, and the search stops at the
  ## next `=` of a different declaration.
  var index = 0
  while index + 2 < tokens.len:
    let token = tokens[index]
    if token.kind == tkIdent and token.text in bindingKeywords and
       tokens[index + 1].kind == tkIdent:
      let name = tokens[index + 1].text
      var position = index + 2
      while position < tokens.len and tokens[position].text != "=" and
            tokens[position].pos - token.pos < 200:
        inc position
      if position + 1 < tokens.len and tokens[position].text == "=" and
         tokens[position + 1].kind in {tkLiteral, tkIdent}:
        result.add((name, position + 1))
    inc index

proc resolveExpression(tokens: seq[Token], start: int,
                       bindings: seq[(string, int)],
                       seen: seq[string]): string =
  ## Concatenates literal bodies and the values of names bound in this file:
  ## `"a " & chunk & " b"` becomes one text. A name bound in another file adds
  ## nothing, but folding continues: the visible part is still one statement.
  var index = start
  while index < tokens.len:
    let token = tokens[index]
    if token.kind == tkLiteral:
      result.add(token.text)
      inc index
    elif token.kind == tkIdent:
      var binding = -1
      for position in 0 ..< bindings.len:
        if bindings[position][0] == token.text:
          binding = position
          break
      if binding < 0 or token.text in seen:
        inc index
      else:
        result.add(resolveExpression(tokens, bindings[binding][1], bindings,
          seen & token.text))
        inc index
    else:
      break
    if index < tokens.len and tokens[index].kind == tkAmp:
      inc index
      continue
    break

proc operandName(token: Token): string =
  if token.kind == tkIdent: token.text else: ""

proc sqlStatements*(source: string): seq[SqlStatement] =
  ## Every string expression whose value reaches the database: literals and the
  ## names they are concatenated with are folded, so a statement split across
  ## `&` operands is judged as one statement. A binding is only judged on its
  ## own when the name is not used in another chain; otherwise the chain that
  ## carries the rest of the statement is the one that matters.
  let tokens = tokenize(source)
  let bindings = bindingStarts(tokens)
  var usedOperand: seq[string] = @[]
  for index in 0 ..< tokens.len:
    if tokens[index].kind != tkAmp:
      continue
    if index > 0:
      let name = operandName(tokens[index - 1])
      if name.len > 0:
        usedOperand.add(name)
    if index + 1 < tokens.len:
      let name = operandName(tokens[index + 1])
      if name.len > 0:
        usedOperand.add(name)
  for index in 0 ..< tokens.len:
    let token = tokens[index]
    var start = -1
    if token.kind == tkLiteral and
       (index == 0 or tokens[index - 1].kind != tkAmp):
      start = index
    elif token.kind == tkIdent and index + 1 < tokens.len and
         tokens[index + 1].kind == tkAmp:
      start = index
    if start < 0:
      continue
    # A binding's own literal is skipped when the name is concatenated
    # elsewhere: that other chain holds the rest of the statement.
    var isBindingValue = false
    for (name, position) in bindings:
      if position == start and name in usedOperand:
        isBindingValue = true
        break
    if isBindingValue:
      continue
    let text = resolveExpression(tokens, start, bindings, @[])
    if text.strip().len == 0:
      continue
    result.add(SqlStatement(text: text, offset: token.pos))

const sqlVerbs = ["select", "insert", "update", "delete", "with"]

proc verbPositions(text, word: string): seq[int] =
  ## Whole-word occurrences, so `updated_at` is not a verb and `player.delete`
  ## is an audit action, not a statement.
  var index = 0
  while true:
    let found = text.find(word, index)
    if found < 0:
      break
    let before = if found == 0: ' ' else: text[found - 1]
    let after = if found + word.len >= text.len: ' ' else: text[found + word.len]
    if before notin {'a'..'z', '0'..'9', '_', '.'} and
       after notin {'a'..'z', '0'..'9', '_'}:
      result.add(found)
    index = found + 1

proc isSql(text: string): bool =
  ## A verb anywhere, not only at the start: a fragment such as
  ## `"from session.sessions where id = $1"` is part of a statement too.
  for verb in sqlVerbs:
    if verbPositions(text, verb).len > 0:
      return true

proc wordAt(text: string, start: int): string =
  var index = start
  while index < text.len and text[index] in {' ', '\t', '\n', '\r'}:
    inc index
  let first = index
  while index < text.len and text[index] in {'a'..'z', 'A'..'Z', '_'}:
    inc index
  text[first ..< index]

const clauseEnders = ["where", "group", "order", "having", "limit", "offset",
  "returning", "union", "join", "left", "right", "inner", "full", "cross",
  "on", "set", "values", "select", "from", "insert", "update", "delete", "with"]

proc referencesAlias(level, alias: string): bool =
  ## `p.` as a qualifier, not the tail of a longer name.
  var index = 0
  while true:
    let found = level.find(alias & ".", index)
    if found < 0:
      return false
    let before = if found == 0: ' ' else: level[found - 1]
    if before notin {'a'..'z', '0'..'9', '_', '.'}:
      return true
    index = found + 1

proc aliasesIn(level: string): seq[string] =
  ## Table aliases declared in one query level: the word after the table named
  ## by `from`/`join`/`update`/`into`, when it is not a clause keyword.
  for keyword in ["from", "join", "update", "into"]:
    for position in verbPositions(level, keyword):
      var index = position + keyword.len
      while index < level.len and level[index] in {' ', '\t', '\n', '\r'}:
        inc index
      let tableStart = index
      while index < level.len and
            level[index] in {'a'..'z', '0'..'9', '_', '.'}:
        inc index
      if index == tableStart:
        continue
      while index < level.len and level[index] in {' ', '\t', '\n', '\r'}:
        inc index
      if index + 2 < level.len and level[index ..< index + 2] == "as":
        index += 2
        while index < level.len and level[index] in {' ', '\t', '\n', '\r'}:
          inc index
      let aliasStart = index
      while index < level.len and level[index] in {'a'..'z', '0'..'9', '_'}:
        inc index
      if index == aliasStart:
        continue
      let word = level[aliasStart ..< index]
      if word in clauseEnders:
        continue
      result.add(word)

type
  SqlLevel = object
    ## One query level of a statement and the aliases visible from its parent
    ## levels, so a correlated subquery can inherit the outer scope.
    text: string
    outerAliases: seq[string]

proc sqlLevels(sql: string): seq[SqlLevel] =
  ## The statement split into query levels. A parenthesised `select`/`with` is
  ## its own level, so a `community_id` in an unrelated subquery cannot scope
  ## the outer table; other parentheses stay in the level they belong to.
  var stack: seq[(string, seq[string], bool, seq[string])] = @[]
  var current = ""
  var currentAliases: seq[string] = @[]
  var index = 0
  while index < sql.len:
    let c = sql[index]
    if c == '(':
      let word = wordAt(sql, index + 1)
      let subquery = word == "select" or word == "with"
      if subquery:
        stack.add((current, currentAliases, true,
          currentAliases & aliasesIn(current)))
        current = ""
        currentAliases = @[]
      else:
        stack.add((current, currentAliases, false, @[]))
        current = "("
    elif c == ')':
      if stack.len == 0:
        current.add(c)
      else:
        let (outer, outerAliases, subquery, subAliases) = stack.pop()
        if subquery:
          result.add(SqlLevel(text: current, outerAliases: subAliases))
          current = outer & " "
          currentAliases = outerAliases
        else:
          current = outer & current & ")"
          currentAliases = outerAliases
    else:
      current.add(c)
    inc index
  result.add(SqlLevel(text: current, outerAliases: currentAliases))
  for (outer, _, _, _) in stack:
    if outer.strip().len > 0:
      result.add(SqlLevel(text: outer))

proc segmentContains(text: string, start: int,
                     enders: openArray[string]): bool =
  ## The clause that opens at `start`, up to the next clause keyword. A scope
  ## predicate is one that lives in that clause.
  var finish = text.len
  for ender in enders:
    for position in verbPositions(text, ender):
      if position > start and position < finish:
        finish = position
  text[start ..< finish].contains("community_id")

proc levelScoped(level: string): bool =
  ## A level is scoped when a `where`, `join ... on` or `having` clause names
  ## community_id, or - for an insert, which has no where clause - the column
  ## list names it.
  for keyword in ["where", "on", "having"]:
    for position in verbPositions(level, keyword):
      if segmentContains(level, position + keyword.len, clauseEnders):
        return true
  for position in verbPositions(level, "insert"):
    if segmentContains(level, position, ["values", "select"]):
      return true

proc unscopedTable*(statement: string): string =
  ## The first domain table named at a query level that does not scope by
  ## community_id, or "" when every level that names one is scoped.
  # A literal that writes a newline as `\n` must read as one word boundary.
  let text = statement.toLowerAscii().replace("\\n", " ")
    .replace("\\t", " ").replace("\\r", " ")
  if not isSql(text):
    return ""
  var namesTable = false
  for table in domainTables:
    if text.contains(table):
      namesTable = true
      break
  if not namesTable:
    return ""
  for level in sqlLevels(text):
    if levelScoped(level.text):
      continue
    # A subquery that names an alias of the enclosing query is correlated, so
    # it can only see the rows the enclosing level already scoped.
    var correlated = false
    for alias in level.outerAliases:
      if referencesAlias(level.text, alias):
        correlated = true
        break
    if correlated:
      continue
    for table in domainTables:
      if level.text.contains(table):
        return table

proc normalize(path: string): string =
  path.replace('\\', '/')

proc importLines(source: string): seq[(int, string)] =
  let lines = stripStrings(source.splitLines())
  for index in 0 ..< lines.len:
    let trimmed = lines[index].strip()
    if trimmed.startsWith("import ") or trimmed.startsWith("from "):
      result.add((index + 1, trimmed))

const communityRoots = ["apps/", "modules/", "tools/"]

proc communityAllowed(file, routine: string,
                      allowed: openArray[string]): bool =
  ## `path/` exempts a whole tree, `path` a whole file, `path:routine` every
  ## statement in one routine. Anything narrower would need line numbers that
  ## move every time the file is edited.
  for entry in allowed:
    if entry.len == 0:
      continue
    if entry.endsWith("/") and file.startsWith(entry):
      return true
    if entry == file:
      return true
    if routine.len > 0 and entry == file & ":" & routine:
      return true

proc lineOf(source: string, offset: int): int =
  var line = 1
  for index in 0 ..< min(offset, source.len):
    if source[index] == '\n':
      inc line
  line

proc enclosingRoutine(source: string, offset: int): string =
  ## The `proc`/`func`/`template` the statement sits in, read backwards from it.
  ## Nothing more precise is needed: the allowlist names a routine, not a line.
  let lines = source[0 ..< min(offset, source.len)].splitLines()
  for index in countdown(lines.len - 1, 0):
    let line = lines[index].strip()
    for keyword in ["proc ", "func ", "template ", "method ", "iterator "]:
      if line.startsWith(keyword):
        var name = ""
        for c in line[keyword.len .. ^1].strip():
          if c in {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
            name.add(c)
          else:
            break
        return name
  ""

proc violationsFor*(path, source: string,
                    allowed: openArray[string] = []): seq[string] =
  let file = normalize(path)
  for (lineNumber, line) in importLines(source):
    if file.startsWith("modules/"):
      if line.contains("apps/") or line.contains("mummy"):
        result.add(file & ":" & $lineNumber &
          ": modules must not import the delivery layer (apps/ or mummy)")
      elif not file.contains("/tests/") and
           (line.contains("api/") or line.contains("routes_gen")):
        # `config.nims` puts `apps` on the path, so `import api/src/routes_gen`
        # reaches the delivery layer without the `apps/` prefix. Tests may read
        # the route table (the authz matrix does); product code may not.
        result.add(file & ":" & $lineNumber &
          ": modules must not import the delivery layer (api/)")
      if file.contains("/domain/") and
         (line.contains("db/db") or line.contains("db_connector")):
        result.add(file & ":" & $lineNumber &
          ": domain must not import the database layer")
  let codeLines = stripStrings(source.splitLines())
  for index in 0 ..< codeLines.len:
    let trimmed = codeLines[index].strip()
    if trimmed.startsWith("#"):
      continue
    if (trimmed.contains("now()") or trimmed.contains("times.now(")) and
       file != "shared/platform-lib/clock.nim" and
       not file.contains("/tests/") and not trimmed.contains("default now()"):
      result.add(file & ":" & $(index + 1) & ": use clock.utcNow(), not now()")
    if trimmed.contains("epochTime(") and
       file != "shared/platform-lib/clock.nim" and
       not file.contains("/tests/"):
      result.add(file & ":" & $(index + 1) &
        ": use clock.utcNow(), not epochTime()")
    if trimmed.contains("getEnv(") and not envAllowed(file) and
       not file.contains("/tests/"):
      result.add(file & ":" & $(index + 1) &
        ": environment access is only allowed at the process edge")

  # Community scope is checked on SQL string expressions only. Prose in comments
  # mentions the tables too, and must not be reported. The delivery layer is
  # scanned like the domain modules: a statement in `apps/` reads and writes
  # tenant rows just as one in `modules/` does. `tools/` is platform-level, and
  # the allowlist records that decision rather than leaving it implicit.
  var scannable = false
  for root in communityRoots:
    if file.startsWith(root):
      scannable = true
  if scannable and not file.contains("/tests/"):
    for statement in sqlStatements(source):
      let table = unscopedTable(statement.text)
      if table.len == 0:
        continue
      let routine = enclosingRoutine(source, statement.offset)
      if communityAllowed(file, routine, allowed):
        continue
      var message = file & ":" & $lineOf(source, statement.offset) &
        ": SQL touches " & table &
        " without community_id in the same statement"
      if routine.len > 0:
        message.add(" (proc " & routine & ")")
      result.add(message)
