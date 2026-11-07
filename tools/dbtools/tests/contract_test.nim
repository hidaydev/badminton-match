import std/[os, strutils, unittest]
import ../main

# The refusal is a decision about the directory, so it is tested without a
# database: `migrate` asks the same question before it opens a transaction.
suite "dbtools contract guard":
  var dir: string

  setup:
    dir = getTempDir() / "dbtools-contract"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)

  teardown:
    if dirExists(dir):
      removeDir(dir)

  test "a header line `-- contract` is refused without the flag":
    writeFile(dir / "0001_drop.sql",
      "-- 0001: the old column goes once nothing writes it.\n" &
      "-- contract\n\n" &
      "alter table probe drop column note;\n")
    let refusal = contractRefusal(dir, false)
    check refusal.contains("0001_drop.sql")
    check refusal.contains("-- contract")
    check refusal.contains("one release")

  test "the flag lets a contract migration through":
    writeFile(dir / "0001_drop.sql",
      "-- 0001: the old column goes once nothing writes it.\n" &
      "-- contract\n\n" &
      "alter table probe drop column note;\n")
    check contractRefusal(dir, true).len == 0

  test "the marker is only read from the header":
    writeFile(dir / "0001_drop.sql",
      "-- 0001: prose may call this a contract migration.\n\n" &
      "alter table probe drop column note;\n" &
      "-- contract\n")
    check contractRefusal(dir, false).len == 0

  test "an ordinary migration is not refused":
    writeFile(dir / "0001_add.sql",
      "-- 0001: add the column.\n\n" &
      "alter table probe add column note text;\n")
    check contractRefusal(dir, false).len == 0

  test "a blank line before the marker still counts as the header":
    writeFile(dir / "0001_drop.sql",
      "\n-- 0001: the old column goes once nothing writes it.\n" &
      "  -- contract  \n\n" &
      "alter table probe drop column note;\n")
    check contractRefusal(dir, false).contains("0001_drop.sql")