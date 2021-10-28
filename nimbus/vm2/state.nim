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
  std/[json, macros, options, sets, strformat, tables],
  ../../stateless/[witness_from_tree, witness_types],
  ../config,
  ../constants,
  ../db/[db_chain, accounts_cache],
  ../errors,
  ../forks,
  ../utils,
  ../utils/ec_recover,
  ./transaction_tracer,
  ./types,
  eth/[common, keys]

# Forward declaration
proc consensusEnginePoA*(vmState: BaseVMState): bool

proc getMinerAddress(vmState: BaseVMState): EthAddress =
  if not vmState.consensusEnginePoA:
    return vmState.blockHeader.coinbase

  let account = vmState.blockHeader.ecRecover
  if account.isErr:
    let msg = "Could not recover account address: " & $account.error
    raise newException(ValidationError, msg)

  account.value

proc `$`*(vmState: BaseVMState): string =
  if vmState.isNil:
    result = "nil"
  else:
    result = &"VMState {vmState.name}:\n  header: {vmState.blockHeader}\n  chaindb:  {vmState.chaindb}"

proc init*(self: BaseVMState, prevStateRoot: Hash256, header: BlockHeader,
           chainDB: BaseChainDB, tracerFlags: set[TracerFlags] = {}) =
  self.prevHeaders = @[]
  self.name = "BaseVM"
  self.blockHeader = header
  self.chaindb = chainDB
  self.tracer.initTracer(tracerFlags)
  self.logEntries = @[]
  self.accountDb = AccountsCache.init(chainDB.db, prevStateRoot, chainDB.pruneTrie)
  self.touchedAccounts = initHashSet[EthAddress]()
  {.gcsafe.}:
    self.minerAddress = self.getMinerAddress()

proc newBaseVMState*(prevStateRoot: Hash256, header: BlockHeader,
                     chainDB: BaseChainDB, tracerFlags: set[TracerFlags] = {}): BaseVMState =
  new result
  result.init(prevStateRoot, header, chainDB, tracerFlags)

proc newBaseVMState*(prevStateRoot: Hash256,
                     chainDB: BaseChainDB, tracerFlags: set[TracerFlags] = {}): BaseVMState =
  new result
  var header: BlockHeader
  result.init(prevStateRoot, header, chainDB, tracerFlags)

proc consensusEnginePoA*(vmState: BaseVMState): bool =
  # PoA consensus engine have no reward for miner
  # TODO: this need to be fixed somehow
  # using `real` engine configuration
  vmState.chainDB.config.poaEngine

proc updateBlockHeader*(vmState: BaseVMState, header: BlockHeader) =
  vmState.blockHeader = header
  vmState.touchedAccounts.clear()
  vmState.selfDestructs.clear()
  if EnableTracing in vmState.tracer.flags:
    vmState.tracer.initTracer(vmState.tracer.flags)
  vmState.logEntries = @[]
  vmState.receipts = @[]
  vmState.minerAddress = vmState.getMinerAddress()

method blockhash*(vmState: BaseVMState): Hash256 {.base, gcsafe.} =
  vmState.blockHeader.hash

method coinbase*(vmState: BaseVMState): EthAddress {.base, gcsafe.} =
  vmState.minerAddress

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

method baseFee*(vmState: BaseVMState): UInt256 {.base, gcsafe.} =
  vmState.blockHeader.baseFee

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
