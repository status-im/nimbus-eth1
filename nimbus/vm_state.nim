# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  macros, strformat, tables, sets, options,
  eth/common,
  vm/interpreter/[vm_forks, gas_costs],
  ./constants, ./db/[db_chain, accounts_cache],
  ./utils, json, vm_types, vm/transaction_tracer,
  ./config, ../stateless/[multi_keys, witness_from_tree, witness_types]

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
  self.logEntries = @[]
  self.accountDb = AccountsCache.init(chainDB.db, prevStateRoot, chainDB.pruneTrie)
  self.touchedAccounts = initHashSet[EthAddress]()

proc newBaseVMState*(prevStateRoot: Hash256, header: BlockHeader,
                     chainDB: BaseChainDB, tracerFlags: set[TracerFlags] = {}): BaseVMState =
  new result
  result.init(prevStateRoot, header, chainDB, tracerFlags)

proc newBaseVMState*(prevStateRoot: Hash256,
                     chainDB: BaseChainDB, tracerFlags: set[TracerFlags] = {}): BaseVMState =
  new result
  var header: BlockHeader
  result.init(prevStateRoot, header, chainDB, tracerFlags)

proc setupTxContext*(vmState: BaseVMState, origin: EthAddress, gasPrice: GasInt, forkOverride=none(Fork)) =
  ## this proc will be called each time a new transaction
  ## is going to be executed
  vmState.txOrigin = origin
  vmState.txGasPrice = gasPrice
  vmState.fork =
    if forkOverride.isSome:
      forkOverride.get
    else:
      vmState.chainDB.config.toFork(vmState.blockHeader.blockNumber)
  vmState.gasCosts = vmState.fork.forkToSchedule

proc updateBlockHeader*(vmState: BaseVMState, header: BlockHeader) =
  vmState.blockHeader = header
  vmState.touchedAccounts.clear()
  vmState.suicides.clear()
  if EnableTracing in vmState.tracer.flags:
    vmState.tracer.initTracer(vmState.tracer.flags)
  vmState.logEntries = @[]
  vmState.receipts = @[]

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

when defined(geth):
  import db/geth_db

method getAncestorHash*(vmState: BaseVMState, blockNumber: BlockNumber): Hash256 {.base, gcsafe.} =
  var ancestorDepth = vmState.blockHeader.blockNumber - blockNumber - 1
  if ancestorDepth >= constants.MAX_PREV_HEADER_DEPTH:
    return
  if blockNumber >= vmState.blockHeader.blockNumber:
    return

  when defined(geth):
    result = vmState.chainDB.headerHash(blockNumber.truncate(uint64))
  else:
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

proc readOnlyStateDB*(vmState: BaseVMState): ReadOnlyStateDB {.inline.} =
  ReadOnlyStateDB(vmState.accountDb)

template mutateStateDB*(vmState: BaseVMState, body: untyped) =
  block:
    var db {.inject.} = vmState.accountDb
    body

proc getTracingResult*(vmState: BaseVMState): JsonNode {.inline.} =
  doAssert(EnableTracing in vmState.tracer.flags)
  vmState.tracer.trace

proc getAndClearLogEntries*(vmState: BaseVMState): seq[Log] =
  shallowCopy(result, vmState.logEntries)
  vmState.logEntries = @[]

proc enableTracing*(vmState: BaseVMState) {.inline.} =
  vmState.tracer.flags.incl EnableTracing

proc disableTracing*(vmState: BaseVMState) {.inline.} =
  vmState.tracer.flags.excl EnableTracing

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

proc status*(vmState: BaseVMState): bool {.inline.} =
  ExecutionOK in vmState.flags

proc `status=`*(vmState: BaseVMState, status: bool) =
 if status: vmState.flags.incl ExecutionOK
 else: vmState.flags.excl ExecutionOK

proc generateWitness*(vmState: BaseVMState): bool {.inline.} =
  GenerateWitness in vmState.flags

proc `generateWitness=`*(vmState: BaseVMState, status: bool) =
 if status: vmState.flags.incl GenerateWitness
 else: vmState.flags.excl GenerateWitness

proc buildWitness*(vmState: BaseVMState): seq[byte] =
  let rootHash = vmState.accountDb.rootHash
  let mkeys = vmState.accountDb.makeMultiKeys()
  let flags = if vmState.fork >= FKSpurious: {wfEIP170} else: {}

  # build witness from tree
  var wb = initWitnessBuilder(vmState.chainDB.db, rootHash, flags)
  result = wb.buildWitness(mkeys)
