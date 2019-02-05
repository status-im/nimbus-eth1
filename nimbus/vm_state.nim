# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  macros, strformat, tables, sets,
  eth/common, eth/trie/db,
  ./constants, ./errors, ./transaction, ./db/[db_chain, state_db],
  ./utils/header, json, vm_types, vm/transaction_tracer

proc newAccessLogs*: AccessLogs =
  AccessLogs(reads: initTable[string, string](), writes: initTable[string, string]())

proc update*[K, V](t: var Table[K, V], elements: Table[K, V]) =
  for k, v in elements:
    t[k] = v

proc `$`*(vmState: BaseVMState): string =
  if vmState.isNil:
    result = "nil"
  else:
    result = &"VMState {vmState.name}:\n  header: {vmState.blockHeader}\n  chaindb:  {vmState.chaindb}"

proc newBaseVMState*(header: BlockHeader, chainDB: BaseChainDB, tracerFlags: set[TracerFlags] = {}): BaseVMState =
  new result
  result.prevHeaders = @[]
  result.name = "BaseVM"
  result.accessLogs = newAccessLogs()
  result.blockHeader = header
  result.chaindb = chainDB
  result.tracer.initTracer(tracerFlags)
  result.tracingEnabled = TracerFlags.EnableTracing in tracerFlags
  result.logEntries = @[]
  result.accountDb = newAccountStateDB(chainDB.db, header.stateRoot, chainDB.pruneTrie)

proc stateRoot*(vmState: BaseVMState): Hash256 =
  vmState.blockHeader.stateRoot

method blockhash*(vmState: BaseVMState): Hash256 {.base, gcsafe.} =
  vmState.blockHeader.hash

method coinbase*(vmState: BaseVMState): EthAddress {.base, gcsafe.} =
  vmState.blockHeader.coinbase

method timestamp*(vmState: BaseVMState): EthTime {.base, gcsafe.} =
  vmState.blockHeader.timestamp

method blockNumber*(vmState: BaseVMState): BlockNumber {.base, gcsafe.} =
  vmState.blockHeader.blockNumber

method difficulty*(vmState: BaseVMState): UInt256 {.base, gcsafe.} =
  vmState.blockHeader.difficulty

method gasLimit*(vmState: BaseVMState): GasInt {.base, gcsafe.} =
  vmState.blockHeader.gasLimit

method getAncestorHash*(vmState: BaseVMState, blockNumber: BlockNumber): Hash256 {.base, gcsafe.} =
  var ancestorDepth = vmState.blockHeader.blockNumber - blockNumber - 1
  if ancestorDepth >= constants.MAX_PREV_HEADER_DEPTH or ancestorDepth < 0:
    return

  let idx = ancestorDepth.toInt
  if idx >= vmState.prevHeaders.len:
    return

  var header = vmState.prevHeaders[idx]
  result = header.hash

when false:
  # this was an older version of `mutateStateDB`, kept here for reference
  # until `mutateStateDB` is fully implemented.
  macro db*(vmState: untyped, readOnly: bool, handler: untyped): untyped =
    # vm.state.db:
    #   setupStateDB(fixture{"pre"}, stateDb)
    #   code = db.getCode(fixture{"exec"}{"address"}.getStr)
    let db = ident("db")
    result = quote:
      block:
        var `db` = `vmState`.chaindb.getStateDB(`vmState`.blockHeader.stateRoot, `readOnly`)
        `handler`
        if `readOnly`:
          # This acts as a secondary check that no mutation took place for
          # read_only databases.
          assert `db`.rootHash == `vmState`.blockHeader.stateRoot
        elif `vmState`.blockHeader.stateRoot != `db`.rootHash:
          `vmState`.blockHeader.stateRoot = `db`.rootHash

        # TODO
        # `vmState`.accessLogs.reads.update(`db`.db.accessLogs.reads)
        # `vmState`.accessLogs.writes.update(`db`.db.accessLogs.writes)

        # remove the reference to the underlying `db` object to ensure that no
        # further modifications can occur using the `State` object after
        # leaving the context.
        # TODO `db`.db = nil
        # state._trie = None

proc getStateDb*(vmState: BaseVMState; stateRoot: Hash256): AccountStateDB =
  # TODO: use AccountStateDB revert/commit after JournalDB implemented
  vmState.accountDb.rootHash = stateRoot
  vmState.accountDb

proc readOnlyStateDB*(vmState: BaseVMState): ReadOnlyStateDB {.inline.} =
  ReadOnlyStateDB(vmState.accountDb)

template mutateStateDB*(vmState: BaseVMState, body: untyped) =
  # This should provide more clever change handling in the future
  # TODO: use AccountStateDB revert/commit after JournalDB implemented
  block:
    let initialStateRoot = vmState.blockHeader.stateRoot
    var db {.inject.} = vmState.getStateDB(initialStateRoot)

    body

    let finalStateRoot = db.rootHash
    if finalStateRoot != initialStateRoot:
      vmState.blockHeader.stateRoot = finalStateRoot

export DbTransaction, commit, rollback, dispose, safeDispose

proc beginTransaction*(vmState: BaseVMState): DbTransaction =
  vmState.chaindb.db.beginTransaction()

proc getTracingResult*(vmState: BaseVMState): JsonNode =
  assert(vmState.tracingEnabled)
  vmState.tracer.trace

proc addLogEntry*(vmState: BaseVMState, log: Log) =
  vmState.logEntries.add(log)

proc getAndClearLogEntries*(vmState: BaseVMState): seq[Log] =
  shallowCopy(result, vmState.logEntries)
  vmState.logEntries = @[]

proc clearLogs*(vmState: BaseVMState) =
  # call this when computation error
  vmState.logEntries.setLen(0)

proc enableTracing*(vmState: BaseVMState) =
  vmState.tracingEnabled = true

proc disableTracing*(vmState: BaseVMState) =
  vmState.tracingEnabled = false

iterator tracedAccounts*(vmState: BaseVMState): EthAddress =
  for acc in vmState.tracer.accounts:
    yield acc

iterator tracedAccountsPairs*(vmState: BaseVMState): (int, EthAddress) =
  var idx = 0
  for acc in vmState.tracer.accounts:
    yield (idx, acc)
    inc idx

proc removeTracedAccounts*(vmState: BaseVMState, accounts: varargs[EthAddress]) =
  for acc in accounts:
    vmState.tracer.accounts.excl acc

