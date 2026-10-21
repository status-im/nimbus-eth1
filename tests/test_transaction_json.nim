# Nimbus
# Copyright (c) 2019-2026 Status Research & Development GmbH
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
  ../tools/common/helpers as chp,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/db/core_db,
  ../execution_chain/common/common,
  ../execution_chain/transaction,
  ../execution_chain/transaction/call_types,
  ../execution_chain/core/validate,
  ../execution_chain/utils/utils

const
  # Fixture fork names that differ from the `getChainConfig` names
  FIXTURE_CONFIG_NAMES = {
    "EIP150": "TangerineWhistle",
    "EIP158": "SpuriousDragon",
  }.toTable

  # Valid per the fixtures, but their gas price does not fit the 64-bit
  # `Transaction.gasPrice`, so decoding rejects them
  KNOWN_UNDECODABLE = [
    "GasLimitPriceProductOverflowtMinusOne",
    "TransactionWithHighGasPrice",
    "V_equals38",
  ]

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus)

proc transactionJsonMain*() =
  suite "Transactions tests":
    jsonTest("TransactionTests", "TransactionTests", testFixture)

transactionJsonMain()

proc testTxByFork(
    tx: Transaction, forkData: JsonNode, forkName: string,
    testStatusIMPL: var TestStatus) =
  let
    config = getChainConfig(FIXTURE_CONFIG_NAMES.getOrDefault(forkName, forkName)).expect("ok")
    memDB  = newCoreDbRef DefaultDbMemory
    com    = CommonRef.new(memDB, config)
    fork   = if forkName == "Paris": MergeFork else: nameToFork[forkName]
    sender = tx.recoverSender()
    res    =
      if sender.isNone: Result[void, string].err("cannot recover sender")
      else: validateTxBasic(com, tx, tx.intrinsicGas(fork, sender.get), fork)

  if "hash" in forkData:
    # Valid for this fork
    check res == Result[void, string].ok()
    if res.isOk:
      check:
        tx.computeRlpHash == Hash32.fromHex(forkData["hash"].getStr)
        sender.get == Address.fromHex(forkData["sender"].getStr)
  else:
    # Invalid for this fork
    check res.isErr

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus) =
  for title, fixture in node:
    let results = fixture["result"]
    var tx: Transaction
    try:
      tx = rlp.decode(safeHexToSeqByte(fixture["txbytes"].getStr), Transaction)
    except RlpError, ValueError:
      if title notin KNOWN_UNDECODABLE:
        # Only transactions that are invalid for every fork may fail to decode
        for forkName, forkData in results:
          check "exception" in forkData
      continue

    for forkName, forkData in results:
      if forkName in nameToFork or forkName == "Paris":
        testTxByFork(tx, forkData, forkName, testStatusIMPL)
