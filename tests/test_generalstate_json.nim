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


proc validateTransaction(vmState: BaseVMState, transaction: Transaction, sender: EthAddress): bool =
  # XXX: https://github.com/status-im/nimbus/issues/35#issuecomment-391726518
  # XXX: lots of avoidable u256 construction
  var readOnlyDB = vmState.readOnlyStateDB
  let limitAndValue = transaction.gasLimit.u256 + transaction.value
  let gas_cost = transaction.gasLimit.u256 * transaction.gasPrice.u256

  transaction.gasLimit >= transaction.getFixtureIntrinsicGas and
    transaction.gasPrice <= (1 shl 34) and
    limitAndValue <= readOnlyDB.getBalance(sender) and
    transaction.accountNonce == readOnlyDB.getNonce(sender) and
    readOnlyDB.getBalance(sender) >= gas_cost

proc setupComputation(header: BlockHeader, vmState: var BaseVMState, transaction: Transaction, sender: EthAddress) : BaseComputation =
  let message = newMessage(
      gas = transaction.gasLimit - transaction.getFixtureIntrinsicGas,
      gasPrice = transaction.gasPrice,
      to = transaction.to,
      sender = sender,
      value = transaction.value,
      data = transaction.payload,
      code = vmState.readOnlyStateDB.getCode(transaction.to).toSeq,
      options = newMessageOptions(origin = sender,
                                  createAddress = transaction.to))

  # doAssert not message.isCreate
  result = newBaseComputation(vmState, header.blockNumber, message)
  result.precompiles = initTable[string, Opcode]()
  doAssert result.isOriginComputation

proc execComputation(computation: var BaseComputation, vmState: var BaseVMState): bool =
  try:
    computation.executeOpcodes()
    vmState.mutateStateDB:
      for deletedAccount in computation.getAccountsForDeletion:
        db.deleteAccount deletedAccount

    result = not computation.isError
  except ValueError:
    result = false

proc testFixtureIndexes(header: BlockHeader, pre: JsonNode, transaction: Transaction, sender: EthAddress, expectedHash: string) =
  var vmState = newBaseVMState(header, newBaseChainDB(newMemoryDb()))
  vmState.mutateStateDB:
    setupStateDB(pre, db)

  defer:
    #echo vmState.readOnlyStateDB.dumpAccount("c94f5374fce5edbc8e2a8697c15331677e6ebf0b")
    doAssert "0x" & `$`(vmState.readOnlyStateDB.rootHash).toLowerAscii == expectedHash

  if not validateTransaction(vmState, transaction, sender):
    vmState.mutateStateDB:
      # pre-EIP158 (e.g., Byzantium) should ensure currentCoinbase exists
      # in later forks, don't create at all
      db.addBalance(header.coinbase, 0.u256)
    return

  # TODO: replace with cachingDb or similar approach; necessary
  # when calls/subcalls/etc come in, too.
  var readOnly = vmState.readOnlyStateDB
  let storageRoot = readOnly.getStorageRoot(transaction.to)

  let gas_cost = transaction.gasLimit.u256 * transaction.gasPrice.u256
  vmState.mutateStateDB:
    db.setNonce(sender, db.getNonce(sender) + 1)
    db.addBalance(transaction.to, transaction.value)
    db.subBalance(sender, transaction.value + gas_cost)

  var computation = setupComputation(header, vmState, transaction, sender)
  if execComputation(computation, vmState):
    let
      gasRemaining = computation.gasMeter.gasRemaining.u256
      gasRefunded = computation.gasMeter.gasRefunded.u256
      gasUsed = transaction.gasLimit.u256 - gasRemaining
      gasRefund = min(gasRefunded, gasUsed div 2)
      gasRefundAmount = (gasRefund + gasRemaining) * transaction.gasPrice.u256

    vmState.mutateStateDB:
      if header.coinbase notin computation.getAccountsForDeletion:
        db.subBalance(header.coinbase, gasRefundAmount)
        db.addBalance(header.coinbase, gas_cost)
      db.addBalance(sender, gasRefundAmount)
    # TODO: only here does one commit, with some nuance/caveat
  else:
    vmState.mutateStateDB:
      # XXX: the coinbase has to be committed; the rest are basically reverts
      db.subBalance(transaction.to, transaction.value)
      db.addBalance(sender, transaction.value)
      db.setStorageRoot(transaction.to, storageRoot)
      db.addBalance(header.coinbase, gas_cost)

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    break

  let fenv = fixture["env"]
  var emptyRlpHash = keccak256.digest(rlp.encode(""))
  let header = BlockHeader(
    coinbase: fenv["currentCoinbase"].getStr.ethAddressFromHex,
    difficulty: fromHex(UInt256, fenv{"currentDifficulty"}.getStr),
    blockNumber: fenv{"currentNumber"}.getHexadecimalInt.u256,
    gasLimit: fenv{"currentGasLimit"}.getHexadecimalInt.GasInt,
    timestamp: fenv{"currentTimestamp"}.getHexadecimalInt.int64.fromUnix,
    stateRoot: emptyRlpHash
    )

  let ftrans = fixture["transaction"]
  for expectation in fixture["post"]["Homestead"]:
    let
      expectedHash = expectation["hash"].getStr
      indexes = expectation["indexes"]
      dataIndex = indexes["data"].getInt
      gasIndex = indexes["gas"].getInt
      valueIndex = indexes["value"].getInt
    let transaction = ftrans.getFixtureTransaction(dataIndex, gasIndex, valueIndex)
    let sender = ftrans.getFixtureTransactionSender
    testFixtureIndexes(header, fixture["pre"], transaction, sender, expectedHash)
