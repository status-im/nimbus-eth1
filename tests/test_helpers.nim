import
  os, macros, json, strformat, strutils, ttmath, utils / [hexadecimal, address], chain, vm_state, constants, db / [db_chain, state_db], vm / forks / frontier / vm, parseutils, ospaths

proc generateTest(filename: string, handler: NimNode): NimNode =
  echo filename
  let testStatusIMPL = ident("testStatusIMPL")
  result = quote:
    test `filename`:
      `handler`(parseJSON(readFile(`filename`)), `testStatusIMPL`)

macro jsonTest*(s: static[string], handler: untyped): untyped =
  result = nnkStmtList.newTree()
  #echo &"tests/fixtures/{s}"
  var z = 0
  for filename in walkDirRec("tests" / "fixtures" / s):
    var (folder, name) = filename.splitPath()
    #if "Arithmetic" in folder: #
    if name.startswith("swap"):
      echo name
      result.add(generateTest(filename, handler))
      z += 1

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
