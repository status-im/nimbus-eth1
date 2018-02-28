import
  os, macros, json, strformat, strutils, ttmath, utils / [hexadecimal, address, padding], chain, vm_state, constants, db / [db_chain, state_db], vm / forks / frontier / vm, parseutils, ospaths, tables

type
  Status* {.pure.} = enum OK, Fail, Skip

proc validTest*(folder: string, name: string): bool =
  # tests we want to skip or which segfault will be skipped here
  # TODO fix 
  result = "calldatacopy" notin name and
    "balanceAddressInputTooBigRightMyAddress." notin name and
    "callstatelessToReturn1" notin name and
    "arith" notin name and
    folder notin @["vmRandomTest", "vmSystemOperations", "vmPerformance", "vmEnvironmentalInfo", "vmLogTest", "vmSha3Test", "vmIOandFlowOperations"]
  #result = name == "exp2.json"

macro jsonTest*(s: static[string], handler: untyped): untyped =
  let testStatusIMPL = ident("testStatusIMPL")
  result = quote:
    var z = 0
    var filenames: seq[(string, string, string)] = @[]
    var status = initOrderedTable[string, OrderedTable[string, Status]]()
    for filename in walkDirRec("tests" / "fixtures" / `s`):
      var (folder, name) = filename.splitPath()
      let last = folder.splitPath().tail
      if not status.hasKey(last):
        status[last] = initOrderedTable[string, Status]()
      status[last][name] = Status.Skip
      if last.validTest(name):
        filenames.add((filename, last, name))
    for child in filenames:
      let (filename, folder, name) = child
      test filename:
        echo folder, name
        status[folder][name] = Status.FAIL
        `handler`(parseJSON(readFile(filename)), `testStatusIMPL`)
        if `testStatusIMPL` == OK:
          status[folder][name] = Status.OK
        z += 1

    status.sort do (a: (string, OrderedTable[string, Status]), b: (string, OrderedTable[string, Status])) -> int:
     cmp(a[0], b[0])

    let symbol: array[Status, string] = ["+", "-", " "]
    var raw = ""
    raw.add(`s` & "\n")
    raw.add("===\n")
    for folder, statuses in status:
      raw.add("## " & folder & "\n")
      raw.add("```diff\n")
      var sortedStatuses = statuses
      sortedStatuses.sort do (a: (string, Status), b: (string, Status)) -> int:
        cmp(a[0], b[0])
      var okCount = 0
      var failCount = 0
      var skipCount = 0
      for name, final in sortedStatuses:
        raw.add(symbol[final] & " " & name.padRight(64, " ") & $final & "\n")
        case final:
          of Status.OK: okCount += 1
          of Status.Fail: failCount += 1
          of Status.Skip: skipCount += 1
      raw.add("```\n")
      let sum = okCount + failCount + skipCount
      raw.add("OK: " & $okCount & "/" & $sum & " Fail: " & $failCount & "/" & $sum & " Skip: " & $skipCount & "/" & $sum & "\n")
    writeFile(`s` & ".md", raw)

proc setupStateDB*(desiredState: JsonNode, stateDB: var AccountStateDB) =
  for account, accountData in desiredState:
    for slot, value in accountData{"storage"}:
      stateDB.setStorage(account, slot.parseInt.u256, value.getInt.u256)

    let nonce = accountData{"nonce"}.getInt.u256
    let code = accountData{"code"}.getStr
    let balance = accountData{"balance"}.getInt.u256

    stateDB.setNonce(account, nonce)
    stateDB.setCode(account, code)
    stateDB.setBalance(account, balance)

proc getHexadecimalInt*(j: JsonNode): int =
  discard parseHex(j.getStr, result)
