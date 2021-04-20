# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../constants,
  ../db/accounts_cache,
  ./interpreter/op_codes,
  ./transaction_tracer,
  ./v2state,
  ./v2types,
  chronicles,
  eth/[common, keys],
  options,
  sets

logScope:
  topics = "vm compu helper"

when defined(chronicles_log_level):
  import stew/byteutils

template accountExists*(c: Computation, address: EthAddress): bool =
  if c.fork >= FkSpurious:
    not c.vmState.readOnlyStateDB.isDeadAccount(address)
  else:
    c.vmState.readOnlyStateDB.accountExists(address)

proc addLogEntry*(c: Computation, log: Log) {.inline.} =
  c.logEntries.add(log)

template fork*(c: Computation): untyped =
  c.vmState.fork

template gasCosts*(c: Computation): untyped =
  c.vmState.gasCosts

template getBalance*(c: Computation, address: EthAddress): Uint256 =
  c.vmState.readOnlyStateDB.getBalance(address)

template getBlockHash*(c: Computation, blockNumber: Uint256): Hash256 =
  c.vmState.getAncestorHash(blockNumber.vmWordToBlockNumber)

template getBlockNumber*(c: Computation): Uint256 =
  c.vmState.blockNumber.blockNumberToVmWord

template getChainId*(c: Computation): uint =
  c.vmState.chaindb.config.chainId.uint

template getCode*(c: Computation, address: EthAddress): seq[byte] =
  c.vmState.readOnlyStateDB.getCode(address)

template getCodeHash*(c: Computation, address: EthAddress): Hash256 =
  let
    db = c.vmState.readOnlyStateDB
  if not db.accountExists(address) or db.isEmptyAccount(address):
    default(Hash256)
  else:
    db.getCodeHash(address)

template getCodeSize*(c: Computation, address: EthAddress): uint =
  uint(c.vmState.readOnlyStateDB.getCodeSize(address))

template getCoinbase*(c: Computation): EthAddress =
  c.vmState.coinbase

template getDifficulty*(c: Computation): DifficultyInt =
  c.vmState.difficulty

template getGasLimit*(c: Computation): GasInt =
  c.vmState.gasLimit

template getGasPrice*(c: Computation): GasInt =
  c.vmState.txGasPrice

template getOrigin*(c: Computation): EthAddress =
  c.vmState.txOrigin

template getStorage*(c: Computation, slot: Uint256): Uint256 =
  c.vmState.readOnlyStateDB.getStorage(c.msg.contractAddress, slot)

template getTimestamp*(c: Computation): int64 =
  c.vmState.timestamp.toUnix

proc prepareTracer*(c: Computation) {.inline.} =
  c.vmState.tracer.prepare(c.msg.depth)

proc selfDestruct*(c: Computation, beneficiary: EthAddress) =
  c.vmState.mutateStateDB:
    let
      localBalance = c.getBalance(c.msg.contractAddress)
      beneficiaryBalance = c.getBalance(beneficiary)

    # Transfer to beneficiary
    db.setBalance(beneficiary, localBalance + beneficiaryBalance)

    # Zero the balance of the address being deleted.
    # This must come after sending to beneficiary in case the
    # contract named itself as the beneficiary.
    db.setBalance(c.msg.contractAddress, 0.u256)

    trace "SELFDESTRUCT",
      contractAddress = c.msg.contractAddress.toHex,
      localBalance = localBalance.toString,
      beneficiary = beneficiary.toHex

  c.touchedAccounts.incl beneficiary
  # Register the account to be deleted
  c.suicides.incl(c.msg.contractAddress)

proc setError*(c: Computation, msg: string, burnsGas = false) {.inline.} =
  c.error = Error(info: msg, burnsGas: burnsGas)

proc traceOpCodeStarted*(c: Computation, op: Op): int {.inline.} =
  c.vmState.tracer.traceOpCodeStarted(c, op)

proc traceOpCodeEnded*(c: Computation, op: Op, lastIndex: int) {.inline.} =
  c.vmState.tracer.traceOpCodeEnded(c, op, lastIndex)

proc tracingEnabled*(c: Computation): bool {.inline.} =
  TracerFlags.EnableTracing in c.vmState.tracer.flags


# deprecated, related to nimvm/evmc implementation
proc execSelfDestruct*(c: Computation, address: EthAddress) {.deprecated.} =
  c.selfDestruct(address)
