# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  os, macros, json, strformat, strutils, parseutils, ospaths, tables,
  byteutils, eth_common, eth_keys, ranges/typedranges,
  ../nimbus/[vm_state, constants],
  ../nimbus/db/[db_chain, state_db],
  ../nimbus/transaction

type
  Status* {.pure.} = enum OK, Fail, Skip

proc validTest*(folder: string, name: string): bool =
  # tests we want to skip or which segfault will be skipped here
  # TODO fix
  #if true:
  #  return "or0" in name
  #if true:
  #  return folder == "vmEnvironmentalInfo"

  result = "calldatacopy" notin name and
    "balanceAddressInputTooBigRightMyAddress." notin name and
    "callstatelessToReturn1" notin name and
    folder notin @["vmRandomTest", "vmSystemOperations", "vmPerformance"]
  #result = name == "exp2.json"

macro jsonTest*(s: static[string], handler: untyped): untyped =
  let
    testStatusIMPL = ident("testStatusIMPL")
    # workaround for strformat in quote do: https://github.com/nim-lang/Nim/issues/8220
    symbol = newIdentNode"symbol"
    final  = newIdentNode"final"
    name   = newIdentNode"name"
    formatted = newStrLitNode"{symbol[final]} {name:<64}{$final}{'\n'}"
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

    status.sort do (a: (string, OrderedTable[string, Status]),
                    b: (string, OrderedTable[string, Status])) -> int: cmp(a[0], b[0])

    let `symbol`: array[Status, string] = ["+", "-", " "]
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
      for `name`, `final` in sortedStatuses:
        raw.add(&`formatted`)
        case `final`:
          of Status.OK: okCount += 1
          of Status.Fail: failCount += 1
          of Status.Skip: skipCount += 1
      raw.add("```\n")
      let sum = okCount + failCount + skipCount
      raw.add("OK: " & $okCount & "/" & $sum & " Fail: " & $failCount & "/" & $sum & " Skip: " & $skipCount & "/" & $sum & "\n")
    writeFile(`s` & ".md", raw)

proc ethAddressFromHex(s: string): EthAddress = hexToByteArray(s, result)

proc setupStateDB*(wantedState: JsonNode, stateDB: var AccountStateDB) =
  for ac, accountData in wantedState:
    let account = ethAddressFromHex(ac)
    for slot, value in accountData{"storage"}:
      stateDB.setStorage(account, slot.parseHexInt.u256, value.getInt.u256)

    let nonce = accountData{"nonce"}.getInt.u256
    let code = hexToSeqByte(accountData{"code"}.getStr).toRange
    let balance = UInt256.fromHex accountData{"balance"}.getStr

    stateDB.setNonce(account, nonce)
    stateDB.setCode(account, code)
    stateDB.setBalance(account, balance)

proc verifyStateDB*(wantedState: JsonNode, stateDB: AccountStateDB) =
  for ac, accountData in wantedState:
    let account = ethAddressFromHex(ac)
    for slot, value in accountData{"storage"}:
      let
        slotId = UInt256.fromHex slot
        wantedValue = UInt256.fromHex value.getStr

      let (actualValue, found) = stateDB.getStorage(account, slotId)
      # echo "FOUND ", found
      # echo "ACTUAL VALUE ", actualValue.toHex
      doAssert found
      doAssert actualValue == wantedValue

    let
      wantedCode = hexToSeqByte(accountData{"code"}.getStr).toRange
      wantedBalance = UInt256.fromHex accountData{"balance"}.getStr
      wantedNonce = accountData{"nonce"}.getInt.u256

      actualCode = stateDB.getCode(account)
      actualBalance = stateDB.getBalance(account)
      actualNonce = stateDB.getNonce(account)

    doAssert wantedCode == actualCode
    doAssert wantedBalance == actualBalance
    doAssert wantedNonce == actualNonce

proc getHexadecimalInt*(j: JsonNode): int =
  discard parseHex(j.getStr, result)
