# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[options, sets, strformat],
  eth/keys,
  ../../stateless/[witness_from_tree, witness_types, multi_keys],
  ../db/ledger,
  ../common/[common, evmforks],
  ./async/data_sources,
  ./interpreter/[op_codes, gas_costs],
  ./types

proc init(
      self:         BaseVMState;
      ac:           LedgerRef,
      parent:       BlockHeader;
      blockCtx:     BlockContext;
      com:          CommonRef;
      tracer:       TracerRef,
      asyncFactory: AsyncOperationFactory = AsyncOperationFactory(maybeDataSource: none[AsyncDataSource]()),
      flags:        set[VMFlag] = self.flags)
    {.gcsafe.} =
  ## Initialisation helper
  self.parent = parent
  self.blockCtx = blockCtx
  self.gasPool = blockCtx.gasLimit
  self.com = com
  self.tracer = tracer
  self.stateDB = ac
  self.asyncFactory = asyncFactory
  self.flags = flags

func blockCtx(com: CommonRef, header: BlockHeader):
                BlockContext {.gcsafe, raises: [CatchableError].} =
  BlockContext(
    timestamp    : header.timestamp,
    gasLimit     : header.gasLimit,
    fee          : header.fee,
    prevRandao   : header.prevRandao,
    difficulty   : header.difficulty,
    coinbase     : com.minerAddress(header),
    excessBlobGas: header.excessBlobGas.get(0'u64),
  )

# --------------

proc `$`*(vmState: BaseVMState): string
    {.gcsafe, raises: [ValueError].} =
  if vmState.isNil:
    result = "nil"
  else:
    result = &"VMState:"&
             &"\n  blockNumber: {vmState.parent.blockNumber + 1}"

proc new*(
      T:        type BaseVMState;
      parent:   BlockHeader;     ## parent header, account sync position
      blockCtx: BlockContext;
      com:      CommonRef;       ## block chain config
      tracer:   TracerRef = nil): T
    {.gcsafe.} =
  ## Create a new `BaseVMState` descriptor from a parent block header. This
  ## function internally constructs a new account state cache rooted at
  ## `parent.stateRoot`
  ##
  ## This `new()` constructor and its variants (see below) provide a save
  ## `BaseVMState` environment where the account state cache is synchronised
  ## with the `parent` block header.
  new result
  result.init(
    ac       = com.ledgerType.init(com.db, parent.stateRoot, com.pruneTrie),
    parent   = parent,
    blockCtx = blockCtx,
    com      = com,
    tracer   = tracer)

proc reinit*(self:     BaseVMState;     ## Object descriptor
             parent:   BlockHeader;     ## parent header, account sync pos.
             blockCtx: BlockContext
             ): bool
    {.gcsafe.} =
  ## Re-initialise state descriptor. The `LedgerRef` database is
  ## re-initilaise only if its `rootHash` doe not point to `parent.stateRoot`,
  ## already. Accumulated state data are reset.
  ##
  ## This function returns `true` unless the `LedgerRef` database could be
  ## queries about its `rootHash`, i.e. `isTopLevelClean` evaluated `true`. If
  ## this function returns `false`, the function argument `self` is left
  ## untouched.
  if self.stateDB.isTopLevelClean:
    let
      tracer = self.tracer
      com    = self.com
      db     = com.db
      ac     = if self.stateDB.rootHash == parent.stateRoot: self.stateDB
               else: com.ledgerType.init(db, parent.stateRoot, com.pruneTrie)
      flags  = self.flags
    self[].reset
    self.init(
      ac       = ac,
      parent   = parent,
      blockCtx = blockCtx,
      com      = com,
      tracer   = tracer,
      flags    = flags)
    return true
  # else: false

proc reinit*(self:   BaseVMState; ## Object descriptor
             parent: BlockHeader; ## parent header, account sync pos.
             header: BlockHeader; ## header with tx environment data fields
             ): bool
    {.gcsafe, raises: [CatchableError].} =
  ## Variant of `reinit()`. The `parent` argument is used to sync the accounts
  ## cache and the `header` is used as a container to pass the `timestamp`,
  ## `gasLimit`, and `fee` values.
  ##
  ## It requires the `header` argument properly initalised so that for PoA
  ## networks, the miner address is retrievable via `ecRecover()`.
  result = self.reinit(
    parent   = parent,
    blockCtx = self.com.blockCtx(header),
    )

proc reinit*(self:      BaseVMState; ## Object descriptor
             header:    BlockHeader; ## header with tx environment data fields
             ): bool
    {.gcsafe, raises: [CatchableError].} =
  ## This is a variant of the `reinit()` function above where the field
  ## `header.parentHash`, is used to fetch the `parent` BlockHeader to be
  ## used in the `update()` variant, above.
  var parent: BlockHeader
  if self.com.db.getBlockHeader(header.parentHash, parent):
    return self.reinit(
      parent    = parent,
      header    = header)

proc init*(
      self:   BaseVMState;     ## Object descriptor
      parent: BlockHeader;     ## parent header, account sync position
      header: BlockHeader;     ## header with tx environment data fields
      com:    CommonRef;       ## block chain config
      tracer: TracerRef = nil)
    {.gcsafe, raises: [CatchableError].} =
  ## Variant of `new()` constructor above for in-place initalisation. The
  ## `parent` argument is used to sync the accounts cache and the `header`
  ## is used as a container to pass the `timestamp`, `gasLimit`, and `fee`
  ## values.
  ##
  ## It requires the `header` argument properly initalised so that for PoA
  ## networks, the miner address is retrievable via `ecRecover()`.
  self.init(
    ac       = com.ledgerType.init(com.db, parent.stateRoot, com.pruneTrie),
    parent   = parent,
    blockCtx = com.blockCtx(header),
    com      = com,
    tracer   = tracer)

proc new*(
      T:      type BaseVMState;
      parent: BlockHeader;     ## parent header, account sync position
      header: BlockHeader;     ## header with tx environment data fields
      com:    CommonRef;       ## block chain config
      tracer: TracerRef = nil): T
    {.gcsafe, raises: [CatchableError].} =
  ## This is a variant of the `new()` constructor above where the `parent`
  ## argument is used to sync the accounts cache and the `header` is used
  ## as a container to pass the `timestamp`, `gasLimit`, and `fee` values.
  ##
  ## It requires the `header` argument properly initalised so that for PoA
  ## networks, the miner address is retrievable via `ecRecover()`.
  new result
  result.init(
    parent = parent,
    header = header,
    com    = com,
    tracer = tracer)

proc new*(
      T:      type BaseVMState;
      header: BlockHeader;     ## header with tx environment data fields
      com:    CommonRef;       ## block chain config
      tracer: TracerRef = nil): T
    {.gcsafe, raises: [CatchableError].} =
  ## This is a variant of the `new()` constructor above where the field
  ## `header.parentHash`, is used to fetch the `parent` BlockHeader to be
  ## used in the `new()` variant, above.
  BaseVMState.new(
    parent = com.db.getBlockHeader(header.parentHash),
    header = header,
    com    = com,
    tracer = tracer)

proc init*(
      vmState: BaseVMState;
      header:  BlockHeader;     ## header with tx environment data fields
      com:     CommonRef;       ## block chain config
      tracer:  TracerRef = nil): bool
    {.gcsafe, raises: [CatchableError].} =
  ## Variant of `new()` which does not throw an exception on a dangling
  ## `BlockHeader` parent hash reference.
  var parent: BlockHeader
  if com.db.getBlockHeader(header.parentHash, parent):
    vmState.init(
      parent = parent,
      header = header,
      com    = com,
      tracer = tracer)
    return true

proc statelessInit*(
    vmState:      BaseVMState;
    parent:       BlockHeader;     ## parent header, account sync position
    header:       BlockHeader;     ## header with tx environment data fields
    com:          CommonRef;       ## block chain config
    asyncFactory: AsyncOperationFactory;
    tracer:       TracerRef = nil): bool
    {.gcsafe, raises: [CatchableError].} =
  vmState.init(
    ac          = com.ledgerType.init(com.db, parent.stateRoot, com.pruneTrie),
    parent      = parent,
    blockCtx    = com.blockCtx(header),
    com         = com,
    tracer      = tracer,
    asyncFactory = asyncFactory)
  return true

proc coinbase*(vmState: BaseVMState): EthAddress =
  vmState.blockCtx.coinbase

proc blockNumber*(vmState: BaseVMState): BlockNumber =
  # it should return current block number
  # and not head.blockNumber
  vmState.parent.blockNumber + 1

proc difficultyOrPrevRandao*(vmState: BaseVMState): UInt256 =
  if vmState.com.consensus == ConsensusType.POS:
    # EIP-4399/EIP-3675
    UInt256.fromBytesBE(vmState.blockCtx.prevRandao.data)
  else:
    vmState.blockCtx.difficulty

proc baseFee*(vmState: BaseVMState): UInt256 =
  vmState.blockCtx.fee.get(0.u256)

method getAncestorHash*(
    vmState: BaseVMState, blockNumber: BlockNumber):
    Hash256 {.base, gcsafe, raises: [CatchableError].} =
  let db = vmState.com.db
  db.getBlockHash(blockNumber)

proc readOnlyStateDB*(vmState: BaseVMState): ReadOnlyStateDB {.inline.} =
  ReadOnlyStateDB(vmState.stateDB)

template mutateStateDB*(vmState: BaseVMState, body: untyped) =
  block:
    var db {.inject.} = vmState.stateDB
    body

proc getAndClearLogEntries*(vmState: BaseVMState): seq[Log] =
  vmState.stateDB.getAndClearLogEntries()

proc status*(vmState: BaseVMState): bool =
  ExecutionOK in vmState.flags

proc `status=`*(vmState: BaseVMState, status: bool) =
 if status: vmState.flags.incl ExecutionOK
 else: vmState.flags.excl ExecutionOK

proc generateWitness*(vmState: BaseVMState): bool =
  GenerateWitness in vmState.flags

proc `generateWitness=`*(vmState: BaseVMState, status: bool) =
  if status: vmState.flags.incl GenerateWitness
  else: vmState.flags.excl GenerateWitness

proc buildWitness*(
    vmState: BaseVMState,
    mkeys: MultiKeysRef): seq[byte] {.raises: [CatchableError].} =
  let rootHash = vmState.stateDB.rootHash
  let flags = if vmState.fork >= FkSpurious: {wfEIP170} else: {}

  # A valid block having no transactions should return an empty witness
  if mkeys.keys.len() == 0:
    return @[]

  # build witness from tree
  var wb = initWitnessBuilder(vmState.com.db, rootHash, flags)
  wb.buildWitness(mkeys)

proc buildWitness*(
    vmState: BaseVMState): seq[byte] {.raises: [CatchableError].} =
  let mkeys = vmState.stateDB.makeMultiKeys()
  buildWitness(vmState, mkeys)

func forkDeterminationInfoForVMState*(vmState: BaseVMState): ForkDeterminationInfo =
  # FIXME-Adam: Is this timestamp right? Note that up above in blockNumber we add 1;
  # should timestamp be adding 12 or something?
  # Also, can I get the TD? Do I need to?
  forkDeterminationInfo(vmState.blockNumber, vmState.blockCtx.timestamp)

func determineFork*(vmState: BaseVMState): EVMFork =
  vmState.com.toEVMFork(vmState.forkDeterminationInfoForVMState)

func tracingEnabled*(vmState: BaseVMState): bool =
  vmState.tracer.isNil.not

proc captureTxStart*(vmState: BaseVMState, gasLimit: GasInt) =
  if vmState.tracingEnabled:
    vmState.tracer.captureTxStart(gasLimit)

proc captureTxEnd*(vmState: BaseVMState, restGas: GasInt) =
  if vmState.tracingEnabled:
    vmState.tracer.captureTxEnd(restGas)

proc captureStart*(vmState: BaseVMState, comp: Computation,
                   sender: EthAddress, to: EthAddress,
                   create: bool, input: openArray[byte],
                   gasLimit: GasInt, value: UInt256) =
  if vmState.tracingEnabled:
    vmState.tracer.captureStart(comp, sender, to, create, input, gasLimit, value)

proc captureEnd*(vmState: BaseVMState, comp: Computation, output: openArray[byte],
                 gasUsed: GasInt, error: Option[string]) =
  if vmState.tracingEnabled:
    vmState.tracer.captureEnd(comp, output, gasUsed, error)

proc captureEnter*(vmState: BaseVMState, comp: Computation, op: Op,
                   sender: EthAddress, to: EthAddress,
                   input: openArray[byte], gasLimit: GasInt,
                   value: UInt256) =
  if vmState.tracingEnabled:
    vmState.tracer.captureEnter(comp, op, sender, to, input, gasLimit, value)

proc captureExit*(vmState: BaseVMState, comp: Computation, output: openArray[byte],
                  gasUsed: GasInt, error: Option[string]) =
  if vmState.tracingEnabled:
    vmState.tracer.captureExit(comp, output, gasUsed, error)

proc captureOpStart*(vmState: BaseVMState, comp: Computation, pc: int,
                   op: Op, gas: GasInt,
                   depth: int): int =
  if vmState.tracingEnabled:
    let fixed = vmState.gasCosts[op].kind == GckFixed
    result = vmState.tracer.captureOpStart(comp, fixed, pc, op, gas, depth)

proc captureGasCost*(vmState: BaseVMState,
                    comp: Computation,
                    op: Op, gasCost: GasInt, gasRemaining: GasInt,
                    depth: int) =
  if vmState.tracingEnabled:
    let fixed = vmState.gasCosts[op].kind == GckFixed
    vmState.tracer.captureGasCost(comp, fixed, op, gasCost, gasRemaining, depth)

proc captureOpEnd*(vmState: BaseVMState, comp: Computation, pc: int,
                   op: Op, gas: GasInt, refund: GasInt,
                   rData: openArray[byte],
                   depth: int, opIndex: int) =
  if vmState.tracingEnabled:
    let fixed = vmState.gasCosts[op].kind == GckFixed
    vmState.tracer.captureOpEnd(comp, fixed, pc, op, gas, refund, rData, depth, opIndex)

proc captureFault*(vmState: BaseVMState, comp: Computation, pc: int,
                   op: Op, gas: GasInt, refund: GasInt,
                   rData: openArray[byte],
                   depth: int, error: Option[string]) =
  if vmState.tracingEnabled:
    let fixed = vmState.gasCosts[op].kind == GckFixed
    vmState.tracer.captureFault(comp, fixed, pc, op, gas, refund, rData, depth, error)

proc capturePrepare*(vmState: BaseVMState, comp: Computation, depth: int) =
  if vmState.tracingEnabled:
    vmState.tracer.capturePrepare(comp, depth)
