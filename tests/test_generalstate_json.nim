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
  # XXX: this is a terrible mess. refactor.
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
  let gas_cost = transaction.gasLimit.u256 * transaction.gasPrice.u256

  var memDb = newMemDB()
  var vmState = newBaseVMState(header, newBaseChainDB(newMemoryDb()))
  vmState.mutateStateDB:
    setupStateDB(fixture{"pre"}, db)

  let currentCoinbase = fenv["currentCoinbase"].getStr.ethAddressFromHex

  # XXX: https://github.com/status-im/nimbus/issues/35#issuecomment-391726518
  # TODO: put yellow paper ref here from that link justifying the limit (1 shl 34 is stand-in)
  # XXX: clean up lots of avoidable u256 construction
  var readOnlyDB = vmState.readOnlyStateDB
  let limitAndValue = transaction.gasLimit.u256 + transaction.value
  if transaction.gasLimit < transaction.getFixtureIntrinsicGas or
     transaction.gasPrice > (1 shl 34) or
     limitAndValue > readOnlyDB.getBalance(sender) or
     #limitAndValue > header.gasLimit.u256 or
     transaction.accountNonce != readOnlyDB.getNonce(sender) or
     readOnlyDB.getBalance(sender) < gas_cost:
    vmState.mutateStateDb:
      # pre-EIP158 (e.g., Byzantium, should ensure currentCoinbase exists)
      # but in later forks, don't create at all
      db.addBalance(currentCoinbase, 0.u256)

    # FIXME: don't repeat this code
    # TODO: iterate over all fixture indexes
    doAssert "0x" & `$`(vmState.readOnlyStateDB.rootHash).toLowerAscii == fixture["post"]["Homestead"][0]["hash"].getStr
    return

  # This address might not have code. This is fine.
  let code = fixture["pre"].getFixtureCode(transaction.to)

  # TODO: replace with cachingDb or similar approach; necessary
  # when calls/subcalls/etc come in, too.
  var foo = vmState.readOnlyStateDB
  let storageRoot = foo.getStorageRoot(transaction.to)

  vmState.mutateStateDB:
    # TODO: combine some of these
    # Also, in general, map out/etc the whole vmState.mutateStateDB flow set
    db.setBalance(sender, db.getBalance(sender) - gas_cost)
    db.setNonce(sender, db.getNonce(sender) + 1)
    db.addBalance(transaction.to, transaction.value)
    db.setBalance(sender, db.getBalance(sender) - transaction.value)

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

  # doAssert not message.isCreate

  var computation = newBaseComputation(vmState, header.blockNumber, message)
  computation.precompiles = initTable[string, Opcode]()

  doAssert computation.isOriginComputation

  # TODO: delineate here during refactoring; try block not low-hanging fruit to split
  # until transactional db comes in
  try:
    computation.executeOpcodes()

    let deletedAccounts = computation.getAccountsForDeletion
    computation.gasMeter.refundGas(24_000 * deletedAccounts.len)

    let
      gasRemaining = computation.gasMeter.gasRemaining.u256
      gasRefunded = computation.gasMeter.gasRefunded.u256
      gasUsed = transaction.gasLimit.u256 - gasRemaining
      gasRefund = min(gasRefunded, gasUsed div 2)
      gasRefundAmount = (gasRefund + gasRemaining) * transaction.gasPrice.u256

    # TODO: investigate if these mutate blocks can be combined
    vmState.mutateStateDB:
      for deletedAccount in deletedAccounts:
        db.deleteAccount deletedAccount

    if not computation.isError:
      vmState.mutateStateDB:
        if currentCoinbase notin deletedAccounts:
          db.setBalance(currentCoinbase, db.getBalance(currentCoinbase) - gasRefundAmount)
          db.addBalance(currentCoinbase, gas_cost)
        db.addBalance(sender, gasRefundAmount)
      # TODO: only here does one commit, with some nuance/caveat
    else:
      # XXX: both error paths are intentionally indentical, for merging, with refactoring
      # TODO: replace with transactional commit/revert state (foo.revert or implicit)
      vmState.mutateStateDB:
        # XXX: the coinbase has to be committed; the rest are basically reverts
        db.setBalance(transaction.to, db.getBalance(transaction.to) - transaction.value)
        db.addBalance(sender, transaction.value)
        db.setStorageRoot(transaction.to, storageRoot)
        db.addBalance(currentCoinbase, gas_cost)
  except ValueError:
    # TODO: replace with transactional commit/revert state (foo.revert or implicit)
    vmState.mutateStateDB:
      # XXX: the coinbase has to be committed; the rest are basically reverts
      db.setBalance(transaction.to, db.getBalance(transaction.to) - transaction.value)
      db.addBalance(sender, transaction.value)
      db.setStorageRoot(transaction.to, storageRoot)
      db.addBalance(currentCoinbase, gas_cost)

  #echo vmState.readOnlyStateDB.dumpAccount("b94f5374fce5edbc8e2a8697c15331677e6ebf0b")
  #echo vmState.readOnlyStateDB.dumpAccount("a94f5374fce5edbc8e2a8697c15331677e6ebf0b")
  #echo vmState.readOnlyStateDB.dumpAccount("c94f5374fce5edbc8e2a8697c15331677e6ebf0b")

  # TODO: do this right
  doAssert "0x" & `$`(vmState.readOnlyStateDB.rootHash).toLowerAscii == fixture["post"]["Homestead"][0]["hash"].getStr
