# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, strformat, strutils, tables, json, ospaths, times,
  byteutils, ranges/typedranges, nimcrypto/[keccak, hash], options,
  rlp, eth_trie/db, eth_common,
  eth_keys, chronicles,
  ./test_helpers,
  ../nimbus/[constants, errors],
  ../nimbus/[vm_state, vm_types, vm_state_transactions],
  ../nimbus/utils/[header, addresses],
  ../nimbus/vm/interpreter,
  ../nimbus/db/[db_chain, state_db]

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus)

suite "generalstate json tests":
  jsonTest("GeneralStateTests", testFixture)


proc testFixtureIndexes(header: BlockHeader, pre: JsonNode, transaction: Transaction, sender: EthAddress, expectedHash: string, testStatusIMPL: var TestStatus, fork: Fork) =
  when enabledLogLevel <= TRACE:
    let tracerFlags = {TracerFlags.EnableTracing}
  else:
    let tracerFlags: set[TracerFlags] = {}
  var vmState = newBaseVMState(header, newBaseChainDB(newMemoryDb()), tracerFlags)
  vmState.mutateStateDB:
    setupStateDB(pre, db)

  defer:
    #echo vmState.readOnlyStateDB.dumpAccount("c94f5374fce5edbc8e2a8697c15331677e6ebf0b")
    let obtainedHash = "0x" & `$`(vmState.readOnlyStateDB.rootHash).toLowerAscii
    check obtainedHash == expectedHash

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
    db.subBalance(sender, transaction.value + gas_cost)

  if transaction.isContractCreation and transaction.payload.len > 0:
    vmState.mutateStateDB:
      # TODO: move into applyCreateTransaction
      # fixtures/GeneralStateTests/stTransactionTest/TransactionSendingToZero.json
      # fixtures/GeneralStateTests/stTransactionTest/TransactionSendingToEmpty.json
      #db.addBalance(generateAddress(sender, transaction.accountNonce), transaction.value)

      let createGasUsed = applyCreateTransaction(db, transaction, vmState, sender, some(fork))
      db.addBalance(header.coinbase, createGasUsed)
    return
  var computation = setupComputation(header, vmState, transaction, sender, some(fork))

  vmState.mutateStateDB:
    # contract creation transaction.to == 0, so ensure happens after
    db.addBalance(transaction.to, transaction.value)

  # What remains is call and/or value transfer
  if execComputation(computation):
    let
      gasRemaining = computation.gasMeter.gasRemaining.u256
      gasRefunded = computation.gasMeter.gasRefunded.u256
      gasUsed = transaction.gasLimit.u256 - gasRemaining
      gasRefund = min(gasRefunded, gasUsed div 2)
      gasRefundAmount = (gasRefund + gasRemaining) * transaction.gasPrice.u256

    vmState.mutateStateDB:
      # TODO if the balance/etc calls were gated on gAFD or similar,
      # that would simplify/combine codepaths
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
  for fork in supportedForks:
    if fixture["post"].has_key(forkNames[fork]):
      # echo "[fork: ", forkNames[fork], "]"
      for expectation in fixture["post"][forkNames[fork]]:
        let
          expectedHash = expectation["hash"].getStr
          indexes = expectation["indexes"]
          dataIndex = indexes["data"].getInt
          gasIndex = indexes["gas"].getInt
          valueIndex = indexes["value"].getInt
        let transaction = ftrans.getFixtureTransaction(dataIndex, gasIndex, valueIndex)
        let sender = ftrans.getFixtureTransactionSender
        testFixtureIndexes(header, fixture["pre"], transaction, sender, expectedHash, testStatusIMPL, fork)
