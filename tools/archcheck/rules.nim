import std/[strutils]

const
  domainTables = ["session.", "player.", "rating.", "tournament.", "community.",
    "achievement."]
  # `cli.nim` is the process edge for every tool: `dsnOrFail` reads the DSN that
  # used to be read in sixteen `main.nim` files.
  envAllowlist = ["shared/platform-lib/clock.nim", "shared/platform-lib/cli.nim"]

proc scanFloorViolation*(scanned, minimum: int): string =
  ## A walker that visits nothing compares nothing and still prints `ok`. The
  ## caller turns a non-empty result into a failure so a partial checkout or a
  ## broken walker cannot pass as a clean tree.
  if scanned >= minimum:
    return ""
  "scanned only " & $scanned & " file(s), below the " & $minimum &
    " file floor: partial checkout or broken walker"

proc envAllowed(file: string): bool =
  ## Environment reads belong to the process edge (apps/, tools/) and to
  ## infrastructure adapters that build their configuration from it.
  file.startsWith("apps/") or file.startsWith("tools/") or
    file in envAllowlist or file.contains("/infrastructure/")

proc scanStrings(lines: seq[string]): tuple[code: seq[string],
    interior: seq[bool]] =
  ## Removes string literal contents (both "..." and triple-quoted blocks) so SQL
  ## `now()` and `?` are not mistaken for Nim code. `interior[index]` is true
  ## when the line begins inside a triple-quoted literal, which is the only way
  ## to tell a fixture block from code that happens to sit at the same indent.
  var triple = false
  var quoted = false
  for line in lines:
    result.interior.add triple
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
    result.code.add(rendered)

proc stripStrings(lines: seq[string]): seq[string] =
  scanStrings(lines).code

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
  # A mutable builder is one statement: `var sql = "select ..."` followed by
  # `sql.add(" and ...")` calls reaches the database whole, so judging the
  # fragments alone would report a scope the base already applies.
  var accumulated: seq[SqlStatement] = @[]
  var consumed: seq[int] = @[]
  for (name, position) in bindings:
    var text = resolveExpression(tokens, position, bindings, @[])
    var added = false
    var index = position + 1
    while index + 1 < tokens.len:
      # `sql.add` is one token: the tokenizer keeps the dot inside a name, so
      # `player.players` and `sql.add` are both single identifiers.
      if tokens[index].kind == tkIdent and tokens[index].text == name & ".add":
        var argument = index + 1
        if argument < tokens.len and tokens[argument].text == "(":
          inc argument
        if argument < tokens.len:
          text.add(resolveExpression(tokens, argument, bindings, @[]))
          consumed.add(argument)
          added = true
      inc index
    if added:
      # The base is judged on its own as well: a fragment appended in another
      # branch must not be the only thing that scopes an unscoped base.
      accumulated.add(SqlStatement(text: resolveExpression(tokens, position,
        bindings, @[]), offset: tokens[position].pos))
      accumulated.add(SqlStatement(text: text, offset: tokens[position].pos))
      consumed.add(position)
  for index in 0 ..< tokens.len:
    let token = tokens[index]
    var start = -1
    if token.kind == tkLiteral and index notin consumed and
       (index == 0 or tokens[index - 1].kind != tkAmp):
      start = index
    elif token.kind == tkIdent and index notin consumed and
         (index == 0 or tokens[index - 1].kind != tkAmp) and
         index + 1 < tokens.len and tokens[index + 1].kind == tkAmp:
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
  result.add(accumulated)

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

proc sourcesIn(level: string): seq[(string, string)] =
  ## Each table the level names, paired with the qualifier a subquery would
  ## use: its alias, or the qualified table name when it has none.
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
      let tableEnd = index
      let table = level[tableStart ..< tableEnd]
      while index < level.len and level[index] in {' ', '\t', '\n', '\r'}:
        inc index
      if index + 2 < level.len and level[index ..< index + 2] == "as":
        index += 2
        while index < level.len and level[index] in {' ', '\t', '\n', '\r'}:
          inc index
      let aliasStart = index
      while index < level.len and level[index] in {'a'..'z', '0'..'9', '_'}:
        inc index
      let word = if index > aliasStart: level[aliasStart ..< index] else: ""
      if word.len == 0 or word in clauseEnders:
        result.add((table, table))
      else:
        result.add((word, table))

proc aliasesIn(level: string): seq[string] =
  ## Qualifiers a subquery may name for the tables this level declares.
  for (qualifier, _) in sourcesIn(level):
    result.add(qualifier)

type
  SqlLevel = object
    ## One query level of a statement and the aliases visible from its parent
    ## levels, so a correlated subquery can inherit the outer scope.
    text: string
    parent: int
    outerAliases: seq[string]

proc inlineOperand(current: string): bool =
  ## `x = (select ...)` and `x in (select ...)` are predicates: the body is
  ## part of the clause, so a community lookup inside one is a scope. An
  ## `exists (...)` subquery is a different question and is judged on its own.
  let text = current.strip()
  if text.len == 0:
    return false
  if text[^1] == '=':
    return true
  var index = text.len
  while index > 0 and text[index - 1] in {'a'..'z', '0'..'9', '_', '.'}:
    dec index
  text[index .. ^1] == "in"

proc sqlLevels(sql: string): seq[SqlLevel] =
  ## The statement split into query levels. A parenthesised `select`/`with` is
  ## its own level, so a `community_id` in an unrelated subquery cannot scope
  ## the outer table; other parentheses stay in the level they belong to.
  ## Parent links are kept because a subquery's correlation often names an
  ## alias that the parent declares *after* the subquery: a select-list
  ## subquery is written before the `from` that introduces `s`.
  var levels = @[SqlLevel(text: "", parent: -1)]
  var current = ""
  var currentLevel = 0
  var stack: seq[(string, int, bool)] = @[]
  var index = 0
  while index < sql.len:
    let c = sql[index]
    if c == '(':
      let word = wordAt(sql, index + 1)
      if word == "select" or word == "with":
        if inlineOperand(current):
          stack.add((current, currentLevel, false))
          current = "("
        else:
          stack.add((current, currentLevel, true))
          levels.add(SqlLevel(text: "", parent: currentLevel))
          currentLevel = levels.len - 1
          current = ""
      else:
        stack.add((current, currentLevel, false))
        current = "("
    elif c == ')':
      if stack.len == 0:
        current.add(c)
      else:
        let (outer, outerLevel, subquery) = stack.pop()
        if subquery:
          levels[currentLevel].text = current
          current = outer
          currentLevel = outerLevel
        else:
          current = outer & current & ")"
    else:
      current.add(c)
    inc index
  levels[currentLevel].text = current
  for i in 1 ..< levels.len:
    var chain: seq[int] = @[]
    var parent = levels[i].parent
    while parent >= 0:
      chain.add(parent)
      parent = levels[parent].parent
    var aliases: seq[string] = @[]
    for j in countdown(chain.len - 1, 0):
      for alias in aliasesIn(levels[chain[j]].text):
        if alias notin aliases:
          aliases.add(alias)
    levels[i].outerAliases = aliases
  levels

proc segmentText(text: string, start: int,
                 enders: openArray[string]): string =
  ## The clause that opens at `start`, up to the next clause keyword *at the
  ## same paren depth*. A `select` inside `community_id = (select ... $1)` is
  ## part of the predicate, not the end of the clause.
  var depth = 0
  var index = start
  while index < text.len:
    let c = text[index]
    if c == '(':
      inc depth
    elif c == ')':
      if depth == 0:
        break
      dec depth
    elif depth == 0:
      var ends = false
      for ender in enders:
        if index + ender.len <= text.len and
           text[index ..< index + ender.len] == ender and
           (index == 0 or text[index - 1] notin {'a'..'z', '0'..'9', '_', '.'}) and
           (index + ender.len >= text.len or
            text[index + ender.len] notin {'a'..'z', '0'..'9', '_'}):
          ends = true
          break
      if ends:
        break
    inc index
  text[start ..< index]

proc parameterOperand(text: string, start: int): bool =
  ## True when the operand at `start` is a parameter, a parameter list, or
  ## `any(...)` over one. An alias, column or literal does not say which
  ## community the caller may read.
  var index = start
  while index < text.len and text[index] in {' ', '\t', '\n', '\r'}:
    inc index
  if index >= text.len:
    return false
  if text[index] == '$':
    return true
  if text[index] == '(':
    var depth = 0
    var cursor = index
    while cursor < text.len:
      if text[cursor] == '(':
        inc depth
      elif text[cursor] == ')':
        dec depth
        if depth == 0:
          return '$' in text[index + 1 ..< cursor]
      inc cursor
    return false
  if wordAt(text, index) != "any":
    return false
  let open = text.find('(', index)
  if open < 0:
    return false
  parameterOperand(text, open)

proc bindsCommunity(segment: string): bool =
  ## A scope predicate compares community_id with a value the caller supplies.
  ## `community_id = community_id` and `on s.community_id = p.community_id`
  ## only say two rows agree; neither picks a community.
  var index = 0
  while true:
    let found = segment.find("community_id", index)
    if found < 0:
      return false
    index = found + "community_id".len
    var cursor = index
    while cursor < segment.len and segment[cursor] in {' ', '\t', '\n', '\r'}:
      inc cursor
    if cursor >= segment.len:
      continue
    if segment[cursor] == '=':
      if parameterOperand(segment, cursor + 1):
        return true
    elif segment[cursor .. ^1].startsWith("in"):
      let open = segment.find('(', cursor)
      if open >= 0 and parameterOperand(segment, open):
        return true

proc squash(text: string): string =
  ## One space between words, so a predicate written across lines still reads.
  var pending = false
  for c in text:
    if c in {' ', '\t', '\n', '\r'}:
      pending = result.len > 0
    else:
      if pending:
        result.add(' ')
        pending = false
      result.add(c)

proc cteBodies(text: string): seq[(string, string)] =
  ## `name as (` introduces a CTE, paired with its body. A join may only
  ## inherit scope from a CTE that is itself scoped; carrying a community_id
  ## column does not make an arbitrary table a community-keyed source.
  var index = 0
  while index < text.len:
    if text[index] in {'a'..'z', '0'..'9', '_'} and
       (index == 0 or text[index - 1] notin {'a'..'z', '0'..'9', '_', '.'}):
      var finish = index
      while finish < text.len and text[finish] in {'a'..'z', '0'..'9', '_'}:
        inc finish
      let word = text[index ..< finish]
      var cursor = finish
      while cursor < text.len and text[cursor] in {' ', '\t', '\n', '\r'}:
        inc cursor
      if cursor + 2 <= text.len and text[cursor ..< cursor + 2] == "as":
        var after = cursor + 2
        while after < text.len and text[after] in {' ', '\t', '\n', '\r'}:
          inc after
        if after < text.len and text[after] == '(':
          var depth = 0
          var close = -1
          var scan = after
          while scan < text.len:
            if text[scan] == '(':
              inc depth
            elif text[scan] == ')':
              dec depth
              if depth == 0:
                close = scan
                break
            inc scan
          if close > after:
            result.add((word, text[after + 1 ..< close]))
      index = finish
      continue
    inc index

proc equalityScoped(level: string, safeCtes: seq[string]): bool =
  ## `X.community_id = Y.community_id` scopes the level when one side is a CTE
  ## that is itself scoped, declared in this statement. Two domain tables
  ## agreeing with each other say nothing about the caller.
  var safe: seq[string] = @[]
  var domain: seq[string] = @[]
  for (qualifier, table) in sourcesIn(level):
    var isDomain = false
    for prefix in domainTables:
      if table.startsWith(prefix):
        isDomain = true
        break
    if isDomain:
      domain.add(qualifier)
    elif table in safeCtes:
      safe.add(qualifier)
  if safe.len == 0 or domain.len == 0:
    return false
  let text = squash(level)
  for left in domain:
    for right in safe:
      if (left & ".community_id = " & right & ".community_id") in text or
         (right & ".community_id = " & left & ".community_id") in text:
        return true

proc levelScoped(level: string, safeCtes: seq[string]): bool =
  ## A level is scoped when a `where`, `join ... on` or `having` clause binds
  ## community_id, or - for an insert, which has no where clause - the column
  ## list names it.
  if equalityScoped(level, safeCtes):
    return true
  for keyword in ["where", "on", "having"]:
    for position in verbPositions(level, keyword):
      if bindsCommunity(segmentText(level, position + keyword.len, clauseEnders)):
        return true
  for position in verbPositions(level, "insert"):
    if "community_id" in segmentText(level, position, ["values", "select"]):
      return true

proc unionBranches(text: string): seq[string] =
  ## Set operands are separate queries: a scoped branch must not answer for an
  ## unscoped one.
  const separators = ["union", "intersect", "except"]
  var start = 0
  var depth = 0
  var index = 0
  while index < text.len:
    let c = text[index]
    if c == '(':
      inc depth
    elif c == ')':
      dec depth
    elif depth == 0:
      var split = 0
      for separator in separators:
        if index + separator.len <= text.len and
           text[index ..< index + separator.len] == separator and
           (index == 0 or text[index - 1] notin {'a'..'z', '0'..'9', '_', '.'}) and
           (index + separator.len >= text.len or
            text[index + separator.len] notin {'a'..'z', '0'..'9', '_'}):
          split = separator.len
          break
      if split > 0:
        result.add(text[start ..< index])
        start = index + split
        index = start
        continue
    inc index
  result.add(text[start .. ^1])

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
  var safeCtes: seq[string] = @[]
  let bodies = cteBodies(text)
  var progressed = true
  while progressed:
    progressed = false
    for (name, body) in bodies:
      if name notin safeCtes and levelScoped(body, safeCtes):
        safeCtes.add(name)
        progressed = true
  for level in sqlLevels(text):
    for branch in unionBranches(level.text):
      if levelScoped(branch, safeCtes):
        continue
      # A subquery that names an alias of the enclosing query is correlated, so
      # it can only see the rows the enclosing level already scoped.
      var correlated = false
      for alias in level.outerAliases:
        if referencesAlias(branch, alias):
          correlated = true
          break
      if correlated:
        continue
      for table in domainTables:
        if branch.contains(table):
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

const featureModuleRoots = ["account/", "achievement/", "community/", "player/",
  "rating/", "session/", "share/", "tournament/"]

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

proc deliverySqlAllowed(file, routine: string,
                        allowed: openArray[string]): bool =
  ## `path/` exempts a whole tree, `path` a whole file, `path:routine` every
  ## statement in one routine. The delivery allowlist names the handlers that
  ## still own SQL while BE-06 moves them into `modules/<name>/application/`.
  for entry in allowed:
    if entry.len == 0:
      continue
    if entry.endsWith("/") and file.startsWith(entry):
      return true
    if entry == file:
      return true
    if routine.len > 0 and entry == file & ":" & routine:
      return true

proc deliverySqlViolations*(path, source: string,
                            allowed: openArray[string] = []): seq[string] =
  ## BE-06: the delivery layer must not hold SQL or the application pool. A
  ## handler calls an application service, which owns the transaction and the
  ## statement; anything still here is a documented exception until the batch
  ## moves it. A new routine with SQL fails without an allowlist entry.
  let file = normalize(path)
  if not file.startsWith("apps/") or file.contains("/tests/"):
    return
  for statement in sqlStatements(source):
    let text = statement.text.strip().toLowerAscii()
    if not (text.startsWith("select ") or text.startsWith("insert ") or
            text.startsWith("update ") or text.startsWith("delete ") or
            text.startsWith("with ") or text.startsWith("--")):
      continue
    let routine = enclosingRoutine(source, statement.offset)
    if deliverySqlAllowed(file, routine, allowed):
      continue
    result.add(file & ":" & $lineOf(source, statement.offset) &
      ": SQL in the delivery layer; move it to modules/<name>/application" &
      (if routine.len > 0: " (proc " & routine & ")" else: ""))
  # `application.db` is the process-global pool. A store call receives a `Db`
  # and a route should not reach for the global itself.
  let originalLines = source.splitLines()
  let codeLines = stripStrings(originalLines)
  var offset = 0
  var reported: seq[string] = @[]
  for index in 0 ..< codeLines.len:
    if codeLines[index].contains("application.db"):
      let routine = enclosingRoutine(source, offset)
      if not deliverySqlAllowed(file, routine, allowed) and
          routine notin reported:
        result.add(file & ":" & $(index + 1) &
          ": delivery layer holds application.db; inject the service instead" &
          (if routine.len > 0: " (proc " & routine & ")" else: ""))
        reported.add(routine)
    offset += originalLines[index].len + 1

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
      if file.startsWith("modules/platform/") and not file.contains("/tests/"):
        # `platform` is the primitive layer every feature builds on: an import
        # in the other direction makes the graph cyclic the day a feature
        # happens to need platform in turn. `db/` is the shared driver, not a
        # feature, so it stays allowed.
        for feature in featureModuleRoots:
          if line.contains(feature):
            result.add(file & ":" & $lineNumber &
              ": platform must not import a feature module (" &
              feature[0 ..< feature.len - 1] & ")")
  let codeLines = stripStrings(source.splitLines())
  # The clock module itself and test support files may read the wall clock. A
  # `_test.nim` is judged like product code (QA-07): pinning the clock through
  # `MAJADU_NOW` is the only way a test may choose an instant, so a stray
  # `epochTime()` in a suite is a defect rather than a fixture.
  let clockExempt = file == "shared/platform-lib/clock.nim" or
    (file.contains("/tests/") and not file.endsWith("_test.nim"))
  for index in 0 ..< codeLines.len:
    let trimmed = codeLines[index].strip()
    if trimmed.startsWith("#"):
      continue
    if (trimmed.contains("now()") or trimmed.contains("times.now(")) and
       not clockExempt and not trimmed.contains("default now()"):
      result.add(file & ":" & $(index + 1) & ": use clock.utcNow(), not now()")
    if trimmed.contains("epochTime(") and not clockExempt:
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

# QA-02: a test that cannot fail is worse than no test, because the suite
# reports success. R-01 judges the test block itself; a `check` that only runs
# inside a nested proc the block calls counts as an assertion the block itself
# never made. R-02 judges the assertions that are present.

const
  identifierChars = {'A'..'Z', 'a'..'z', '0'..'9', '_'}
  # The statements a test uses to fail. `fail(` is matched as text because
  # unittest's `fail` is a template without parentheses in every call site.
  assertionWords = ["check", "expect", "doAssert", "require"]
  # A nested routine is not the test block's own assertion. Its body is skipped
  # rather than its one-line declaration, so `proc helper()` does not hide the
  # `check` calls that follow it.
  routineWords = ["proc ", "func ", "template ", "iterator ", "method ",
    "converter ", "macro ", "proc("]

type
  TestBlock = object
    name: string
    line: int
    indent: int
    first: int
    last: int
    inline: string
    found: bool

proc lineIndent(line: string): int =
  while result < line.len and line[result] == ' ':
    inc result

proc isBlankOrComment(line: string): bool =
  let trimmed = line.strip()
  trimmed.len == 0 or trimmed.startsWith("#")

proc codeOf(line: string): string =
  ## A line with string contents and a trailing comment removed. The caller
  ## passes lines already stripped as one block, so a triple-quoted string that
  ## spans several lines does not leak its text into the scan.
  line.split('#')[0]

proc blockHeader(line: string): TestBlock =
  ## Reads `test "name": body` and `test "name":` (body on the next lines).
  ## `test(...)` calls and names built from concatenation are not recognised:
  ## the unittest template's block form is what the rule can judge.
  let trimmed = line.strip()
  if not trimmed.startsWith("test "):
    return
  var index = "test ".len
  if index >= trimmed.len or trimmed[index] != '"':
    return
  let open = index
  inc index
  while index < trimmed.len:
    if trimmed[index] == '\\':
      index += 2
      continue
    if trimmed[index] == '"':
      break
    inc index
  if index >= trimmed.len:
    return
  let close = index
  var after = close + 1
  while after < trimmed.len and trimmed[after] in {' ', '\t'}:
    inc after
  if after >= trimmed.len or trimmed[after] != ':':
    return
  result.found = true
  result.name = trimmed[open + 1 ..< close]
  result.inline = trimmed[after + 1 .. ^1].strip()

proc testBlocks(lines: seq[string], interior: seq[bool]): seq[TestBlock] =
  ## One entry per `test "..."` block. A block ends at the first code line that
  ## is not indented further than the `test` line, so a sibling test or the next
  ## suite statement closes it.
  ##
  ## `interior` is `scanStrings(...).interior`: a line that begins inside a
  ## triple-quoted literal cannot close the block, however it is indented. A
  ## JSON fixture written flush left used to end its own test before the `check`
  ## calls below it, and the rule then reported a test with assertions as empty.
  var index = 0
  while index < lines.len:
    var entry = blockHeader(lines[index])
    if not entry.found:
      inc index
      continue
    entry.line = index + 1
    entry.indent = lineIndent(lines[index])
    entry.first = index + 1
    if entry.inline.len > 0:
      entry.last = index + 1
    else:
      var stop = index + 1
      while stop < lines.len:
        if interior[stop] or isBlankOrComment(lines[stop]):
          inc stop
          continue
        if lineIndent(lines[stop]) <= entry.indent:
          break
        inc stop
      entry.last = stop
    result.add(entry)
    index = if entry.last > index + 1: entry.last else: index + 1

proc hasWord(line, word: string): bool =
  ## Whole-word occurrence, so `checkpoint` is not a `check` and `required` is
  ## not a `require`.
  var index = 0
  while true:
    let found = line.find(word, index)
    if found < 0:
      return false
    let before = if found == 0: ' ' else: line[found - 1]
    let after = if found + word.len >= line.len: ' ' else: line[found + word.len]
    if before notin identifierChars and after notin identifierChars:
      return true
    index = found + 1

proc hasAssertion(code: string): bool =
  for word in assertionWords:
    if hasWord(code, word):
      return true
  "fail(" in code

proc startsRoutine(line: string): bool =
  let trimmed = line.strip()
  for word in routineWords:
    if trimmed.startsWith(word):
      return true

proc routineHeader(line: string): tuple[name, keyword: string, found: bool] =
  ## The name of a routine declared on this line. `proc`, `func` and the macro
  ## family are the ones a test can call to assert on its behalf.
  let trimmed = line.strip()
  for keyword in ["proc", "func", "template", "iterator", "method", "macro",
                  "converter"]:
    if not trimmed.startsWith(keyword):
      continue
    if trimmed.len == keyword.len or
       trimmed[keyword.len] notin {' ', '('}:
      continue
    var index = keyword.len
    while index < trimmed.len and trimmed[index] == ' ':
      inc index
    let start = index
    while index < trimmed.len and (trimmed[index] in identifierChars or
                                   trimmed[index] == '*'):
      inc index
    if index == start:
      return
    result.found = true
    result.keyword = keyword
    result.name = trimmed[start ..< index].replace("*", "")
    return

proc assertingRoutines*(source: string): seq[string] =
  ## Module-level routines that can fail: a test that calls one has made an
  ## assertion even though the `check` sits in the helper. Only top-level
  ## routines are collected, so a proc defined inside a test block stays
  ## invisible and its `check` does not count for that block.
  let lines = source.splitLines()
  let code = stripStrings(lines)
  var index = 0
  while index < lines.len:
    if lineIndent(lines[index]) != 0:
      inc index
      continue
    let header = routineHeader(lines[index])
    if not header.found:
      inc index
      continue
    var stop = index + 1
    while stop < lines.len:
      if isBlankOrComment(lines[stop]):
        inc stop
        continue
      if lineIndent(lines[stop]) <= 0:
        break
      inc stop
    for position in index ..< stop:
      let text = codeOf(code[position])
      # A macro or template that raises a compile-time error is an assertion:
      # the test cannot pass when the shape it checks is wrong.
      let compileTime = header.keyword in ["template", "macro"] and
        "error(" in text
      if compileTime or hasAssertion(text):
        result.add(header.name)
        break
    index = stop

proc callsRoutine(code: string, names: openArray[string]): bool =
  for name in names:
    var index = 0
    while true:
      let found = code.find(name & "(", index)
      if found < 0:
        break
      let before = if found == 0: ' ' else: code[found - 1]
      if before notin identifierChars:
        return true
      index = found + 1

proc checkExpressions(code: string): seq[string] =
  ## The expression after every `check` word, up to `;` or the end of the line.
  var index = 0
  while index < code.len:
    let found = code.find("check", index)
    if found < 0:
      break
    let before = if found == 0: ' ' else: code[found - 1]
    let after = if found + "check".len >= code.len: ' '
                else: code[found + "check".len]
    if before in identifierChars or after in identifierChars:
      index = found + "check".len
      continue
    var start = found + "check".len
    while start < code.len and code[start] in {' ', '\t'}:
      inc start
    var stop = code.find(';', start)
    if stop < 0:
      stop = code.len
    var expression = code[start ..< stop].strip()
    if expression.startsWith("(") and expression.endsWith(")"):
      expression = expression[1 ..< expression.len - 1].strip()
    result.add(expression)
    index = stop + 1

proc sameIdentifier(expression: string): bool =
  ## `x == x` cannot fail. Both sides must be the same identifier, dots
  ## included, so a repeated field read is caught as well.
  let equals = expression.find("==")
  if equals < 0 or (equals + 2 < expression.len and expression[equals + 2] == '='):
    return false
  let left = expression[0 ..< equals].strip()
  let right = expression[equals + 2 .. ^1].strip()
  if left.len == 0 or left != right:
    return false
  # `1 == 1` is a constant comparison, not a value read twice; only a name can
  # be mistaken for an assertion about the code.
  var named = false
  for c in left:
    if c in {'A'..'Z', 'a'..'z', '_'}:
      named = true
    elif c notin identifierChars and c != '.':
      return false
  named

proc alwaysTrueLength(expression: string): bool =
  ## `len(x) >= 0` holds for every string, sequence and map.
  let start = expression.find("len(")
  if start < 0:
    return false
  var depth = 0
  var index = start + "len(".len - 1
  while index < expression.len:
    if expression[index] == '(':
      inc depth
    elif expression[index] == ')':
      dec depth
      if depth == 0:
        break
    inc index
  if index >= expression.len:
    return false
  var rest = expression[index + 1 .. ^1].strip()
  rest = rest.replace(" ", "").replace("\t", "")
  rest == ">=0"

proc inElseArm(body: seq[(int, string)], position: int): bool =
  ## `check false` is a deliberate unreachable marker inside an `else` arm and a
  ## vacuous assertion everywhere else. The arm is read from the nearest less
  ## indented line above, which is the branch header that owns this line.
  let text = body[position][1]
  let code = codeOf(text)
  let checkAt = code.find("check")
  if checkAt > 0 and code[0 ..< checkAt].strip().startsWith("else"):
    return true
  let own = lineIndent(text)
  var index = position - 1
  while index >= 0:
    let candidate = body[index][1]
    if isBlankOrComment(candidate):
      dec index
      continue
    if lineIndent(candidate) < own:
      return candidate.strip().startsWith("else")
    dec index
  false

proc honestAllowed(file, name: string, allowed: openArray[string]): bool =
  ## `path:test name` exempts one block, `path` a whole file. A new test in an
  ## allowlisted file is still judged; a line number would move with every edit.
  for entry in allowed:
    if entry.len == 0:
      continue
    if entry == file or entry == file & ":" & name:
      return true

proc honestTestViolations*(path, source: string,
                           allowed: openArray[string] = [],
                           asserting: openArray[string] = []): seq[string] =
  ## R-01 and R-02 from the test quality plan, section 10. Only `*_test.nim`
  ## files are passed here; the caller decides the scope. `asserting` is
  ## `assertingRoutines` over the tree, so a test that delegates its assertion
  ## to a shared helper is not reported as empty.
  let file = normalize(path)
  let raw = source.splitLines()
  # One strip over the whole file keeps a triple-quoted string that spans lines
  # from reading as code further down.
  let scanned = scanStrings(raw)
  let code = scanned.code
  for entry in testBlocks(raw, scanned.interior):
    if honestAllowed(file, entry.name, allowed):
      continue
    var body: seq[(int, string)] = @[]
    var bodyCode: seq[string] = @[]
    if entry.inline.len > 0:
      body.add((entry.line, entry.inline))
      bodyCode.add(codeOf(code[entry.line - 1]))
    else:
      for index in entry.first ..< entry.last:
        # The code view, not the raw line: a line inside a fixture string is
        # blank here, which is what keeps it out of the indent and routine
        # checks below.
        body.add((index + 1, code[index]))
        bodyCode.add(codeOf(code[index]))
    var asserts = false
    var routineIndent = -1
    for position in 0 ..< body.len:
      let text = body[position][1]
      if isBlankOrComment(text):
        continue
      let indent = lineIndent(text)
      if routineIndent >= 0:
        if indent > routineIndent:
          continue
        routineIndent = -1
      if startsRoutine(text):
        routineIndent = indent
        continue
      if hasAssertion(bodyCode[position]) or
         callsRoutine(bodyCode[position], asserting):
        asserts = true
    if not asserts:
      result.add(file & ":" & $entry.line & ": test \"" & entry.name &
        "\" has no assertion that can fail (R-01)")
    for position in 0 ..< body.len:
      let text = body[position][1]
      if isBlankOrComment(text):
        continue
      for expression in checkExpressions(bodyCode[position]):
        let line = body[position][0]
        if expression == "true":
          result.add(file & ":" & $line & ": `check true` cannot fail (R-02)")
        elif expression == "false" and not inElseArm(body, position):
          result.add(file & ":" & $line &
            ": `check false` outside an else arm cannot pass (R-02)")
        elif sameIdentifier(expression):
          result.add(file & ":" & $line & ": `" & expression &
            "` compares an identifier with itself (R-02)")
        elif alwaysTrueLength(expression):
          result.add(file & ":" & $line & ": `" & expression &
            "` is true for every value (R-02)")
