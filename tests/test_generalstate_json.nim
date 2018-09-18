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
  # XXX: this is becoming a mess. refactor.
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
  if transaction.gasLimit < transaction.getFixtureIntrinsicGas or
     transaction.gasPrice > (1 shl 34) or
     transaction.accountNonce != vmState.readOnlyStateDB.getNonce(sender) or
     vmState.readOnlyStateDB.getBalance(sender) < gas_cost:
    vmState.mutateStateDb:
      # pre-EIP158 (e.g., Byzantium, should ensure currentCoinbase exists)
      # but in later forks, don't create at all
      db.deltaBalance(currentCoinbase, 0.u256)

    # FIXME: don't repeat this code
    doAssert "0x" & `$`(vmState.readOnlyStateDB.rootHash).toLowerAscii == fixture["post"]["Homestead"][0]["hash"].getStr
    return

  # TODO: implement other sorts of transactions
  # TODO: check whether it's to an empty address

  # This address might not have code. This is fine.
  let code = fixture["pre"].getFixtureCode(transaction.to)

  vmState.mutateStateDB:
    # TODO: combine some of these
    # Also, in general, map out/etc the whole vmState.mutateStateDB flow set
    db.setBalance(sender, db.getBalance(sender) - gas_cost)
    db.deltaBalance(currentCoinbase, gas_cost)
    db.setNonce(sender, db.getNonce(sender) + 1)
    db.deltaBalance(transaction.to, transaction.value)
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

  var computation = newBaseComputation(vmState, header.blockNumber, message)
  computation.vmState = vmState

  # XXX: https://github.com/status-im/nimbus/issues/122
  computation.precompiles = initTable[string, Opcode]()

  doAssert computation.isOriginComputation

  try:
    computation.executeOpcodes()

    let deletedAccounts = computation.getAccountsForDeletion
    computation.gasMeter.refundGas(24_000 * deletedAccounts.len)
    vmState.mutateStateDB:
      for deletedAccount in deletedAccounts:
        db.deleteAccount deletedAccount

    let
      gasRemaining = computation.gasMeter.gasRemaining.u256
      gasRefunded = computation.gasMeter.gasRefunded.u256
      gasUsed = transaction.gasLimit.u256 - gasRemaining
      gasRefund = min(gasRefunded, gasUsed div 2)
      gasRefundAmount = (gasRefund + gasRemaining) * transaction.gasPrice.u256

    if not computation.isError:
      vmState.mutateStateDB:
        db.setBalance(currentCoinbase, db.getBalance(currentCoinbase) - gasRefundAmount)
        db.deltaBalance(sender, gasRefundAmount)
      # TODO: only here does one commit, with some nuance/caveat
    else:
      # TODO: replace with transactional commit/revert state (foo.revert, or just implicit)
      vmState.mutateStateDB:
        db.setBalance(transaction.to, db.getBalance(transaction.to) - transaction.value)
        db.deltaBalance(sender, transaction.value)
  except ValueError:
    # TODO: replace with transactional commit/revert state (here, foo.revert)
    vmState.mutateStateDB:
      db.setBalance(transaction.to, db.getBalance(transaction.to) - transaction.value)
      db.deltaBalance(sender, transaction.value)
    echo "Computation error"

  # TODO: do this right
  doAssert "0x" & `$`(vmState.readOnlyStateDB.rootHash).toLowerAscii == fixture["post"]["Homestead"][0]["hash"].getStr
