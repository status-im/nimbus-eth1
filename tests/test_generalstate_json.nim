# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, strformat, strutils, sequtils, tables, json, ospaths, times,
  byteutils, ranges/typedranges, nimcrypto/[keccak, hash],
  rlp, eth_trie/[types, memdb], eth_common,
  eth_keys,
  ./test_helpers,
  ../nimbus/[constants, errors],
  ../nimbus/[vm_state, vm_types],
  ../nimbus/utils/header,
  ../nimbus/vm/interpreter,
  ../nimbus/db/[db_chain, state_db]

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus)

suite "generalstate json tests":
  jsonTest("GeneralStateTests", testFixture)


proc stringFromBytes(x: ByteRange): string =
  result = newString(x.len)
  for i in 0 ..< x.len:
    result[i] = char(x[i])

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    break

  let fenv = fixture["env"]
  var emptyRlpHash = keccak256.digest(rlp.encode("").toOpenArray)
  let header = BlockHeader(
    coinbase: fenv{"currentCoinbase"}.getStr.parseAddress,
    difficulty: fromHex(UInt256, fenv{"currentDifficulty"}.getStr),
    blockNumber: fenv{"currentNumber"}.getHexadecimalInt.u256,
    gasLimit: fenv{"currentGasLimit"}.getHexadecimalInt.GasInt,
    timestamp: fenv{"currentTimestamp"}.getHexadecimalInt.int64.fromUnix,
    stateRoot: emptyRlpHash
    )

  let ftrans = fixture["transaction"]
  let transaction = ftrans.getFixtureTransaction
  let sender = ftrans.getFixtureTransactionSender
  let gas_cost = (transaction.gasLimit * transaction.gasPrice).u256

  var memDb = newMemDB()
  var vmState = newBaseVMState(header, newBaseChainDB(trieDB memDb))
  vmState.mutateStateDB:
    setupStateDB(fixture{"pre"}, db)

  doAssert transaction.accountNonce == vmState.readOnlyStateDB.getNonce(sender)
  doAssert vmState.readOnlyStateDB.getBalance(sender) >= gas_cost

  # TODO: implement other sorts of transctions
  # TODO: check whether it's to an empty address
  let code = fixture["pre"].getFixtureCode(transaction.to)
  doAssert code.len > 2

  let currentCoinbase = fenv["currentCoinbase"].getStr.ethAddressFromHex

  vmState.mutateStateDB:
    db.setBalance(sender, db.getBalance(sender) - gas_cost)
    db.deltaBalance(currentCoinbase, gas_cost)
    db.setNonce(sender, db.getNonce(sender) + 1)

  # build_message (Py-EVM)
  # FIXME: detect contact creation address; only run if transaction.to addr has .code
  let message = newMessage(
      gas = transaction.gasLimit - transaction.getFixtureIntrinsicGas,
      gasPrice = transaction.gasPrice,
      to = transaction.to,
      sender = sender,
      value = transaction.value,
      data = transaction.payload,
      code = code,
      options = newMessageOptions(origin = sender,
                                  createAddress = transaction.to))

  var computation = newBaseComputation(vmState, header.blockNumber, message)
  computation.vmState = vmState

  # XXX: https://github.com/status-im/nimbus/issues/122
  computation.precompiles = initTable[string, Opcode]()

  doAssert computation.isOriginComputation

  try:
    computation.executeOpcodes()

    let
      gasRemaining = computation.gasMeter.gasRemaining
      gasRefunded = computation.gasMeter.gasRefunded
      gasUsed = transaction.gasLimit - gasRemaining
      gasRefund = min(gasRefunded, gasUsed div 2)
      gasRefundAmount = (gasRefund + gasRemaining) * transaction.gasPrice

    vmState.mutateStateDB:
      db.setBalance(currentCoinbase, db.getBalance(currentCoinbase) - gasRefundAmount.u256)
      db.deltaBalance(sender, gasRefundAmount.u256)
      db.deltaBalance(transaction.to, transaction.value)
      db.setBalance(sender, db.getBalance(sender) - transaction.value)

  except ValueError:
    echo "Computation error"

  # TODO: do this right
  doAssert "0x" & `$`(vmState.readOnlyStateDB.rootHash).toLowerAscii == fixture["post"]["Homestead"][0]["hash"].getStr
