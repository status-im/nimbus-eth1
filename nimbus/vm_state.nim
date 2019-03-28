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
  ./utils, json, vm_types, vm/transaction_tracer

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

proc init*(self: BaseVMState, prevStateRoot: Hash256, header: BlockHeader,
           chainDB: BaseChainDB, tracerFlags: set[TracerFlags] = {}) =
  self.prevHeaders = @[]
  self.name = "BaseVM"
  self.accessLogs = newAccessLogs()
  self.blockHeader = header
  self.chaindb = chainDB
  self.tracer.initTracer(tracerFlags)
  self.tracingEnabled = TracerFlags.EnableTracing in tracerFlags
  self.logEntries = @[]
  self.blockHeader.stateRoot = prevStateRoot
  self.accountDb = newAccountStateDB(chainDB.db, prevStateRoot, chainDB.pruneTrie)

proc newBaseVMState*(prevStateRoot: Hash256, header: BlockHeader,
                     chainDB: BaseChainDB, tracerFlags: set[TracerFlags] = {}): BaseVMState =
  new result
  result.init(prevStateRoot, header, chainDB, tracerFlags)

proc stateRoot*(vmState: BaseVMState): Hash256 =
  vmState.blockHeader.stateRoot

method blockhash*(vmState: BaseVMState): Hash256 {.base, gcsafe.} =
  vmState.blockHeader.hash

method coinbase*(vmState: BaseVMState): EthAddress {.base, gcsafe.} =
  vmState.blockHeader.coinbase

method timestamp*(vmState: BaseVMState): EthTime {.base, gcsafe.} =
  vmState.blockHeader.timestamp

method blockNumber*(vmState: BaseVMState): BlockNumber {.base, gcsafe.} =
  # it should return current block number
  # and not head.blockNumber
  vmState.blockHeader.blockNumber

method difficulty*(vmState: BaseVMState): UInt256 {.base, gcsafe.} =
  vmState.blockHeader.difficulty

method gasLimit*(vmState: BaseVMState): GasInt {.base, gcsafe.} =
  vmState.blockHeader.gasLimit

method getAncestorHash*(vmState: BaseVMState, blockNumber: BlockNumber): Hash256 {.base, gcsafe.} =
  var ancestorDepth = vmState.blockHeader.blockNumber - blockNumber - 1
  if ancestorDepth >= constants.MAX_PREV_HEADER_DEPTH or ancestorDepth < 0:
    return

  result = vmState.chainDB.getBlockHash(blockNumber)
  #TODO: should we use deque here?
  # someday we may revive this code when
  # we already have working miner
  when false:
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
          doAssert `db`.rootHash == `vmState`.blockHeader.stateRoot
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

proc getTracingResult*(vmState: BaseVMState): JsonNode =
  doAssert(vmState.tracingEnabled)
  vmState.tracer.trace

proc addLogs*(vmState: BaseVMState, logs: seq[Log]) =
  shallowCopy(vmState.logEntries, logs)

proc getAndClearLogEntries*(vmState: BaseVMState): seq[Log] =
  shallowCopy(result, vmState.logEntries)
  vmState.logEntries = @[]

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
