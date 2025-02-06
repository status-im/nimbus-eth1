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
  stew/assign2,
  ../db/ledger,
  ../common/[common, evmforks],
  ./interpreter/[op_codes, gas_costs],
  ./types,
  ./evm_errors

func forkDeterminationInfoForVMState(vmState: BaseVMState): ForkDeterminationInfo =
  forkDeterminationInfo(vmState.parent.number + 1, vmState.blockCtx.timestamp)

func determineFork(vmState: BaseVMState): EVMFork =
  vmState.com.toEVMFork(vmState.forkDeterminationInfoForVMState)

proc init(
      self:         BaseVMState;
      ac:           LedgerRef,
      parent:       Header;
      blockCtx:     BlockContext;
      com:          CommonRef;
      tracer:       TracerRef,
      flags:        set[VMFlag] = self.flags) =
  ## Initialisation helper
  # Take care to (re)set all fields since the VMState might be recycled
  self.com = com
  self.ledger = ac
  self.gasPool = blockCtx.gasLimit
  assign(self.parent, parent)
  assign(self.blockCtx, blockCtx)
  const txCtx = default(TxContext)
  assign(self.txCtx, txCtx)
  self.flags = flags
  self.fork = self.determineFork
  self.tracer = tracer
  self.receipts.setLen(0)
  self.cumulativeGasUsed = 0
  self.gasCosts = self.fork.forkToSchedule
  self.blobGasUsed = 0'u64
  self.allLogs.setLen(0)
  self.gasRefunded = 0

func blockCtx(header: Header): BlockContext =
  BlockContext(
    timestamp    : header.timestamp,
    gasLimit     : header.gasLimit,
    baseFeePerGas: header.baseFeePerGas,
    prevRandao   : header.prevRandao,
    difficulty   : header.difficulty,
    coinbase     : header.coinbase,
    excessBlobGas: header.excessBlobGas.get(0'u64),
    parentHash   : header.parentHash,
  )

# --------------

proc `$`*(vmState: BaseVMState): string
    {.gcsafe, raises: [].} =
  if vmState.isNil:
    result = "nil"
  else:
    result = &"VMState:"&
             &"\n  blockNumber: {vmState.parent.number + 1}"

proc new*(
      T:        type BaseVMState;
      parent:   Header;     ## parent header, account sync position
      blockCtx: BlockContext;
      com:      CommonRef;       ## block chain config
      tracer:   TracerRef = nil,
      storeSlotHash = false): T =
  ## Create a new `BaseVMState` descriptor from a parent block header. This
  ## function internally constructs a new account state cache rooted at
  ## `parent.stateRoot`
  ##
  ## This `new()` constructor and its variants (see below) provide a save
  ## `BaseVMState` environment where the account state cache is synchronised
  ## with the `parent` block header.
  new result
  result.init(
    ac       = LedgerRef.init(com.db, storeSlotHash),
    parent   = parent,
    blockCtx = blockCtx,
    com      = com,
    tracer   = tracer)

proc reinit*(self:     BaseVMState;     ## Object descriptor
             parent:   Header;     ## parent header, account sync pos.
             blockCtx: BlockContext;
             linear: bool
             ): bool =
  ## Re-initialise state descriptor. The `LedgerRef` database is
  ## re-initilaise only if its `getStateRoot()` doe not point to `parent.stateRoot`,
  ## already. Accumulated state data are reset. When linear, we assume that
  ## the state recently processed the parent block.
  ##
  ## This function returns `true` unless the `LedgerRef` database could be
  ## queries about its `getStateRoot()`, i.e. `isTopLevelClean` evaluated `true`. If
  ## this function returns `false`, the function argument `self` is left
  ## untouched.
  if not self.ledger.isTopLevelClean:
    return false

  let
    tracer = self.tracer
    com    = self.com
    db     = com.db
    ac     = if linear or self.ledger.getStateRoot() == parent.stateRoot: self.ledger
              else: LedgerRef.init(db, self.ledger.storeSlotHash)
    flags  = self.flags
  self.init(
    ac       = ac,
    parent   = parent,
    blockCtx = blockCtx,
    com      = com,
    tracer   = tracer,
    flags    = flags)
  true

proc reinit*(self:   BaseVMState; ## Object descriptor
             parent: Header; ## parent header, account sync pos.
             header: Header; ## header with tx environment data fields
             linear: bool
             ): bool =
  ## Variant of `reinit()`. The `parent` argument is used to sync the accounts
  ## cache and the `header` is used as a container to pass the `timestamp`,
  ## `gasLimit`, and `fee` values.
  ##
  ## It requires the `header` argument properly initalised so that for PoA
  ## networks, the miner address is retrievable via `ecRecover()`.
  self.reinit(
    parent   = parent,
    blockCtx = blockCtx(header),
    linear = linear
    )

proc init*(
      self:   BaseVMState;     ## Object descriptor
      parent: Header;     ## parent header, account sync position
      header: Header;     ## header with tx environment data fields
      com:    CommonRef;       ## block chain config
      tracer: TracerRef = nil,
      storeSlotHash = false) =
  ## Variant of `new()` constructor above for in-place initalisation. The
  ## `parent` argument is used to sync the accounts cache and the `header`
  ## is used as a container to pass the `timestamp`, `gasLimit`, and `fee`
  ## values.
  ##
  ## It requires the `header` argument properly initalised so that for PoA
  ## networks, the miner address is retrievable via `ecRecover()`.
  self.init(
    ac       = LedgerRef.init(com.db, storeSlotHash),
    parent   = parent,
    blockCtx = blockCtx(header),
    com      = com,
    tracer   = tracer)

proc new*(
      T:      type BaseVMState;
      parent: Header;     ## parent header, account sync position
      header: Header;     ## header with tx environment data fields
      com:    CommonRef;       ## block chain config
      tracer: TracerRef = nil,
      storeSlotHash = false): T =
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
    tracer = tracer,
    storeSlotHash = storeSlotHash)

proc new*(
      T:      type BaseVMState;
      header: Header;     ## header with tx environment data fields
      com:    CommonRef;       ## block chain config
      tracer: TracerRef = nil,
      storeSlotHash = false): EvmResult[T] =
  ## This is a variant of the `new()` constructor above where the field
  ## `header.parentHash`, is used to fetch the `parent` Header to be
  ## used in the `new()` variant, above.
  let parent = com.db.getBlockHeader(header.parentHash).valueOr:
    return err(evmErr(EvmHeaderNotFound))

  ok(BaseVMState.new(
      parent = parent,
      header = header,
      com    = com,
      tracer = tracer,
      storeSlotHash = storeSlotHash))

proc init*(
      vmState: BaseVMState;
      header:  Header;     ## header with tx environment data fields
      com:     CommonRef;       ## block chain config
      tracer:  TracerRef = nil,
      storeSlotHash = false): bool =
  ## Variant of `new()` which does not throw an exception on a dangling
  ## `Header` parent hash reference.
  let parent = com.db.getBlockHeader(header.parentHash).valueOr:
    return false
  vmState.init(
    parent = parent,
    header = header,
    com    = com,
    tracer = tracer,
    storeSlotHash = storeSlotHash)
  return true

func coinbase*(vmState: BaseVMState): Address =
  vmState.blockCtx.coinbase

func blockNumber*(vmState: BaseVMState): BlockNumber =
  # it should return current block number
  # and not head.number
  vmState.parent.number + 1

proc proofOfStake*(vmState: BaseVMState): bool =
  vmState.com.proofOfStake(Header(
    number: vmState.blockNumber,
    parentHash: vmState.blockCtx.parentHash,
    difficulty: vmState.blockCtx.difficulty,
  ))

proc difficultyOrPrevRandao*(vmState: BaseVMState): UInt256 =
  if vmState.proofOfStake():
    # EIP-4399/EIP-3675
    UInt256.fromBytesBE(vmState.blockCtx.prevRandao.data)
  else:
    vmState.blockCtx.difficulty

func baseFeePerGas*(vmState: BaseVMState): UInt256 =
  vmState.blockCtx.baseFeePerGas.get(0.u256)

method getAncestorHash*(
    vmState: BaseVMState, blockNumber: BlockNumber): Hash32 {.gcsafe, base.} =
  let db = vmState.com.db
  let blockHash = db.getBlockHash(blockNumber).valueOr:
    return default(Hash32)
  blockHash

proc readOnlyLedger*(vmState: BaseVMState): ReadOnlyLedger {.inline.} =
  ReadOnlyLedger(vmState.ledger)

template mutateLedger*(vmState: BaseVMState, body: untyped) =
  block:
    var db {.inject.} = vmState.ledger
    body

proc getAndClearLogEntries*(vmState: BaseVMState): seq[Log] =
  vmState.ledger.getAndClearLogEntries()

proc status*(vmState: BaseVMState): bool =
  ExecutionOK in vmState.flags

proc `status=`*(vmState: BaseVMState, status: bool) =
 if status: vmState.flags.incl ExecutionOK
 else: vmState.flags.excl ExecutionOK

proc collectWitnessData*(vmState: BaseVMState): bool =
  CollectWitnessData in vmState.flags

proc `collectWitnessData=`*(vmState: BaseVMState, status: bool) =
  if status: vmState.flags.incl CollectWitnessData
  else: vmState.flags.excl CollectWitnessData

func tracingEnabled*(vmState: BaseVMState): bool =
  vmState.tracer.isNil.not

proc captureTxStart*(vmState: BaseVMState, gasLimit: GasInt) =
  if vmState.tracingEnabled:
    vmState.tracer.captureTxStart(gasLimit)

proc captureTxEnd*(vmState: BaseVMState, restGas: GasInt) =
  if vmState.tracingEnabled:
    vmState.tracer.captureTxEnd(restGas)

proc captureStart*(vmState: BaseVMState, comp: Computation,
                   sender: Address, to: Address,
                   create: bool, input: openArray[byte],
                   gasLimit: GasInt, value: UInt256) =
  if vmState.tracingEnabled:
    vmState.tracer.captureStart(comp, sender, to, create, input, gasLimit, value)

proc captureEnd*(vmState: BaseVMState, comp: Computation, output: openArray[byte],
                 gasUsed: GasInt, error: Opt[string]) =
  if vmState.tracingEnabled:
    vmState.tracer.captureEnd(comp, output, gasUsed, error)

proc captureEnter*(vmState: BaseVMState, comp: Computation, op: Op,
                   sender: Address, to: Address,
                   input: openArray[byte], gasLimit: GasInt,
                   value: UInt256) =
  if vmState.tracingEnabled:
    vmState.tracer.captureEnter(comp, op, sender, to, input, gasLimit, value)

proc captureExit*(vmState: BaseVMState, comp: Computation, output: openArray[byte],
                  gasUsed: GasInt, error: Opt[string]) =
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
  let fixed = vmState.gasCosts[op].kind == GckFixed
  vmState.tracer.captureGasCost(comp, fixed, op, gasCost, gasRemaining, depth)

proc captureOpEnd*(vmState: BaseVMState, comp: Computation, pc: int,
                   op: Op, gas: GasInt, refund: int64,
                   rData: openArray[byte],
                   depth: int, opIndex: int) =
  if vmState.tracingEnabled:
    let fixed = vmState.gasCosts[op].kind == GckFixed
    vmState.tracer.captureOpEnd(comp, fixed, pc, op, gas, refund, rData, depth, opIndex)

proc captureFault*(vmState: BaseVMState, comp: Computation, pc: int,
                   op: Op, gas: GasInt, refund: int64,
                   rData: openArray[byte],
                   depth: int, error: Opt[string]) =
  if vmState.tracingEnabled:
    let fixed = vmState.gasCosts[op].kind == GckFixed
    vmState.tracer.captureFault(comp, fixed, pc, op, gas, refund, rData, depth, error)

proc capturePrepare*(vmState: BaseVMState, comp: Computation, depth: int) =
  if vmState.tracingEnabled:
    vmState.tracer.capturePrepare(comp, depth)
