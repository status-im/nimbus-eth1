# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  os, macros, json, strformat, strutils, parseutils, ospaths, tables,
  stint,
  ../src/utils/[hexadecimal, address, padding],
  ../src/[chain, vm_state, constants],
  ../src/db/[db_chain, state_db], ../src/vm/forks/f20150730_frontier/frontier_vm,
  ../src/vm/base, ../src/transaction

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

    status.sort do (a: (string, OrderedTable[string, Status]),
                    b: (string, OrderedTable[string, Status])) -> int: cmp(a[0], b[0])

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

method newTransaction*(
  vm: VM, addr_from, addr_to: string,
  amount: UInt256,
  private_key: string,
  gas_price = 10.u256,
  gas = 100000.u256,
  data: seq[byte] = @[]
): BaseTransaction =
  # TODO: amount should be an Int to deal with negatives
  new result

  # Todo getStateDB is incomplete
  let nonce = vm.state.readOnlyStateDB.getNonce(addr_from)

  # TODO
  # if !private key: create_unsigned_transaction
  # else: create_signed_transaction
