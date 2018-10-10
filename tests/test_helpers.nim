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
  ../nimbus/transaction,
  ../nimbus/vm/interpreter/[gas_costs, vm_forks],
  ../tests/test_generalstate_failing

type
  Status* {.pure.} = enum OK, Fail, Skip

func slowTest*(folder: string, name: string): bool =
  # TODO: add vmPerformance and loop check here
  result = folder == "stQuadraticComplexityTest" or
           name in @["randomStatetest352.json", "randomStatetest1.json",
                     "randomStatetest32.json", "randomStatetest347.json",
                     "randomStatetest393.json", "randomStatetest626.json",
                     "CALLCODE_Bounds.json", "DELEGATECALL_Bounds3.json",
                     "CALLCODE_Bounds4.json", "CALL_Bounds.json",
                     "DELEGATECALL_Bounds2.json", "CALL_Bounds3.json",
                     "CALLCODE_Bounds2.json", "CALLCODE_Bounds3.json",
                     "DELEGATECALL_Bounds.json", "CALL_Bounds2a.json",
                     "CALL_Bounds2.json",
                     "CallToNameRegistratorMemOOGAndInsufficientBalance.json",
                     "CallToNameRegistratorTooMuchMemory0.json"]

func failIn32Bits(folder, name: string): bool =
  return name in @[
    "randomStatetest94.json",
    "calldatacopy_dejavu.json",
    "calldatacopy_dejavu2.json",
    "codecopy_dejavu.json",
    "codecopy_dejavu2.json",
    "extcodecopy_dejavu.json",
    "log1_dejavu.json",
    "log2_dejavu.json",
    "log3_dejavu.json",
    "log4_dejavu.json",
    "mload_dejavu.json",
    "mstore_dejavu.json",
    "mstroe8_dejavu.json",
    "sha3_dejavu.json",
    "HighGasLimit.json",
    "OverflowGasRequire2.json",
    "RevertInCreateInInit.json",
    "FailedCreateRevertsDeletion.json",

    # TODO: obvious theme; check returndatasize/returndatacopy
    "call_ecrec_success_empty_then_returndatasize.json",
    "call_then_call_value_fail_then_returndatasize.json",
    "returndatacopy_after_failing_callcode.json",
    "returndatacopy_after_failing_delegatecall.json",
    "returndatacopy_after_failing_staticcall.json",
    "returndatacopy_after_revert_in_staticcall.json",
    "returndatacopy_after_successful_callcode.json",
    "returndatacopy_after_successful_delegatecall.json",
    "returndatacopy_after_successful_staticcall.json",
    "returndatacopy_following_call.json",
    "returndatacopy_following_failing_call.json",
    "returndatacopy_following_revert.json",
    "returndatacopy_following_too_big_transfer.json",
    "returndatacopy_initial.json",
    "returndatacopy_initial_256.json",
    "returndatacopy_initial_big_sum.json",
    "returndatacopy_overrun.json",
    "returndatasize_after_failing_callcode.json",
    "returndatasize_after_failing_staticcall.json",
    "returndatasize_after_oog_after_deeper.json",
    "returndatasize_after_successful_callcode.json",
    "returndatasize_after_successful_delegatecall.json",
    "returndatasize_after_successful_staticcall.json",
    "returndatasize_bug.json",
    "returndatasize_initial.json",
    "returndatasize_initial_zero_read.json",
    "call_then_create_successful_then_returndatasize.json",
    "call_outsize_then_create_successful_then_returndatasize.json"]

func validTest*(folder: string, name: string): bool =
  # tests we want to skip or which segfault will be skipped here
  result = (folder != "vmPerformance" or "loop" notin name) and
           (not slowTest(folder, name) and
            # TODO: check whether these are still useful
            name notin @["static_Call1024BalanceTooLow.json",
                         "Call1024BalanceTooLow.json", "ExtCodeCopyTests.json"])

proc lacksHomesteadPostStates*(filename: string): bool =
  # XXX: Until Nimbus supports Byzantine or newer forks, as opposed
  # to Homestead, ~1k of ~2.5k GeneralStateTests won't work. Nimbus
  # supporting Byzantine should trigger removal of this function. A
  # possible alternate approach of avoiding double-reading fixtures
  # seemed less than ideal, as by the time that happens, output has
  # already appeared. Compatible with non-GST fixtures. Will become
  # expensive once BlockchainTests appear, so try to remove first.
  let fixtures = parseJSON(readFile(filename))
  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    break

  return fixture.kind == JObject and fixture.has_key("transaction") and
    (fixture.has_key("post") and not fixture["post"].has_key("Homestead"))

macro jsonTest*(s: static[string], handler: untyped): untyped =
  let
    testStatusIMPL = ident("testStatusIMPL")
    # workaround for strformat in quote do: https://github.com/nim-lang/Nim/issues/8220
    symbol = newIdentNode"symbol"
    final  = newIdentNode"final"
    name   = newIdentNode"name"
    formatted = newStrLitNode"{symbol[final]} {name:<64}{$final}{'\n'}"
  result = quote:
    var filenames: seq[(string, string, string)] = @[]
    var status = initOrderedTable[string, OrderedTable[string, Status]]()
    for filename in walkDirRec("tests" / "fixtures" / `s`):
      var (folder, name) = filename.splitPath()
      let last = folder.splitPath().tail
      if not status.hasKey(last):
        status[last] = initOrderedTable[string, Status]()
      status[last][name] = Status.Skip
      if last.validTest(name) and not filename.lacksHomesteadPostStates:
        filenames.add((filename, last, name))
    for child in filenames:
      let (filename, folder, name) = child
      test filename:
        echo folder / name
        status[folder][name] = Status.FAIL
        try:
          `handler`(parseJSON(readFile(filename)), `testStatusIMPL`)
          if `testStatusIMPL` == OK:
            status[folder][name] = Status.OK
        except AssertionError:
          status[folder][name] = Status.FAIL
          if not allowedFailingGeneralStateTest(folder, name) and not failIn32Bits(folder, name):
            raise

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

func ethAddressFromHex*(s: string): EthAddress = hexToByteArray(s, result)

func safeHexToSeqByte*(hexStr: string): seq[byte] =
  if hexStr == "":
    @[]
  else:
    hexStr.hexToSeqByte

proc setupStateDB*(wantedState: JsonNode, stateDB: var AccountStateDB) =
  for ac, accountData in wantedState:
    let account = ethAddressFromHex(ac)
    for slot, value in accountData{"storage"}:
      stateDB.setStorage(account, fromHex(UInt256, slot), fromHex(UInt256, value.getStr))

    let nonce = accountData{"nonce"}.getStr.parseHexInt.AccountNonce
    let code = accountData{"code"}.getStr.safeHexToSeqByte.toRange
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
      doAssert actualValue == wantedValue, &"{actualValue.toHex} != {wantedValue.toHex}"

    let
      wantedCode = hexToSeqByte(accountData{"code"}.getStr).toRange
      wantedBalance = UInt256.fromHex accountData{"balance"}.getStr
      wantedNonce = accountData{"nonce"}.getInt.AccountNonce

      actualCode = stateDB.getCode(account)
      actualBalance = stateDB.getBalance(account)
      actualNonce = stateDB.getNonce(account)

    doAssert wantedCode == actualCode, &"{wantedCode} != {actualCode}"
    doAssert wantedBalance == actualBalance, &"{wantedBalance.toHex} != {actualBalance.toHex}"
    doAssert wantedNonce == actualNonce, &"{wantedNonce.toHex} != {actualNonce.toHex}"

func getHexadecimalInt*(j: JsonNode): int64 =
  # parseutils.parseHex works with int which will overflow in 32 bit
  var data: StUInt[64]
  data = fromHex(StUInt[64], j.getStr)
  result = cast[int64](data)

proc getFixtureTransaction*(j: JsonNode, dataIndex, gasIndex, valueIndex: int): Transaction =
  result.accountNonce = j["nonce"].getStr.parseHexInt.AccountNonce
  result.gasPrice = j["gasPrice"].getStr.parseHexInt
  result.gasLimit = j["gasLimit"][gasIndex].getStr.parseHexInt

  # TODO: there are a couple fixtures which appear to distinguish between
  # empty and 0 transaction.to.
  let rawTo = j["to"].getStr
  if rawTo == "":
    result.to = "0x".parseAddress
    result.isContractCreation = true
  else:
    result.to = rawTo.parseAddress
    result.isContractCreation = false
  result.value = fromHex(UInt256, j["value"][valueIndex].getStr)
  result.payload = j["data"][dataIndex].getStr.safeHexToSeqByte

proc getFixtureTransactionSender*(j: JsonNode): EthAddress =
  var secretKey = j["secretKey"].getStr
  removePrefix(secretKey, "0x")
  let privateKey = initPrivateKey(secretKey)

  var pubKey: PublicKey
  let transaction = j.getFixtureTransaction(0, 0, 0)
  if recoverSignatureKey(signMessage(privateKey, transaction.rlpEncode),
                         transaction.txHashNoSignature.data,
                         pubKey) == EthKeysStatus.Success:
    return pubKey.toCanonicalAddress()
  else:
    # XXX: appropriate failure mode; probably raise something
    discard
