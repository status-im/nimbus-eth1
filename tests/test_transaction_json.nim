# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, os, tables, strutils],
  unittest2,
  eth/rlp,
  ./test_helpers,
  eth/common/transaction_utils,
  ../nimbus/transaction,
  ../nimbus/core/validate,
  ../nimbus/utils/utils

const
  FIXTURE_FORK_SKIPS = ["_info", "rlp", "Constantinople"]

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus)

proc transactionJsonMain*() =
  suite "Transactions tests":
    jsonTest("eth_tests" / "TransactionTests", "TransactionTests", testFixture)

when isMainModule:
  transactionJsonMain()

proc txHash(tx: Transaction): string =
  rlpHash(tx).toHex()

proc testTxByFork(tx: Transaction, forkData: JsonNode, forkName: string, testStatusIMPL: var TestStatus) =
  tx.validateTxBasic(nameToFork[forkName]).isOkOr:
    return

  if forkData.len > 0 and "sender" in forkData:
    let sender = Address.fromHex(forkData["sender"].getStr)
    check "hash" in forkData
    check tx.txHash == forkData["hash"].getStr
    check tx.recoverSender().expect("valid signature") == sender

func noHash(fixture: JsonNode): bool =
  result = true
  for forkName, forkData in fixture:
    if forkName notin FIXTURE_FORK_SKIPS:
      if forkData.len == 0: return
      if "hash" in forkData: return false

# nimbus rlp cannot allow type mismatch
# e.g. uint256 value put into int64
# so we skip noHash check. this behavior
# is different compared to py-evm
const SKIP_TITLES = [
  "TransactionWithGasLimitxPriceOverflow",
  "TransactionWithHighNonce256",
  "TransactionWithHighGasPrice",
  "V_equals38"
  ]

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus) =
  var
    title: string
    rlpData: seq[byte]
    tx: Transaction

  for key, fixture in node:
    title = key

    try:
      rlpData = safeHexToSeqByte(fixture["rlp"].getStr)
    except ValueError:
      # bad rlp bytes
      check noHash(fixture)
      return

    try:
      tx = rlp.decode(rlpData, Transaction)
    except RlpTypeMismatch, MalformedRlpError, UnsupportedRlpError:
      if title in SKIP_TITLES:
        return
      check noHash(fixture)
      return

    for forkName, fork in fixture:
      if forkName notin FIXTURE_FORK_SKIPS:
        testTxByFork(tx, fork, forkName, testStatusIMPL)
