# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, macros, options, sets, strformat, tables],
  eth/[keys],
  ../../stateless/[witness_from_tree, witness_types],
  ../db/accounts_cache,
  ../common/[common, evmforks],
  ../errors,
  ./transaction_tracer,
  ./types

{.push raises: [].}

template safeExecutor(info: string; code: untyped) =
  try:
    code
  except CatchableError as e:
    raise (ref CatchableError)(msg: e.msg)
  except Defect as e:
    raise (ref Defect)(msg: e.msg)
  except:
    let e = getCurrentException()
    raise newException(VmStateError, info & "(): " & $e.name & " -- " & e.msg)

proc init(
      self:        BaseVMState;
      ac:          AccountsCache;
      parent:      BlockHeader;
      timestamp:   EthTime;
      gasLimit:    GasInt;
      fee:         Option[UInt256];
      prevRandao:  Hash256;
      difficulty:  UInt256;
      miner:       EthAddress;
      com:         CommonRef;
      tracer:      TransactionTracer)
    {.gcsafe.} =
  ## Initialisation helper
  self.prevHeaders = @[]
  self.parent = parent
  self.timestamp = timestamp
  self.gasLimit = gasLimit
  self.fee = fee
  self.prevRandao = prevRandao
  self.blockDifficulty = difficulty
  self.com = com
  self.tracer = tracer
  self.logEntries = @[]
  self.stateDB = ac
  self.touchedAccounts = initHashSet[EthAddress]()
  self.minerAddress = miner

proc init(
      self:        BaseVMState;
      ac:          AccountsCache;
      parent:      BlockHeader;
      timestamp:   EthTime;
      gasLimit:    GasInt;
      fee:         Option[UInt256];
      prevRandao:  Hash256;
      difficulty:  UInt256;
      miner:       EthAddress;
      com:         CommonRef;
      tracerFlags: set[TracerFlags])
    {.gcsafe.} =
  var tracer: TransactionTracer
  tracer.initTracer(tracerFlags)
  self.init(
    ac        = ac,
    parent    = parent,
    timestamp = timestamp,
    gasLimit  = gasLimit,
    fee       = fee,
    prevRandao= prevRandao,
    difficulty= difficulty,
    miner     = miner,
    com       = com,
    tracer    = tracer)

# --------------

proc `$`*(vmState: BaseVMState): string
    {.gcsafe, raises: [ValueError].} =
  if vmState.isNil:
    result = "nil"
  else:
    result = &"VMState:"&
             &"\n  blockNumber: {vmState.parent.blockNumber + 1}"

proc new*(
      T:           type BaseVMState;
      parent:      BlockHeader;     ## parent header, account sync position
      timestamp:   EthTime;         ## tx env: time stamp
      gasLimit:    GasInt;          ## tx env: gas limit
      fee:         Option[UInt256]; ## tx env: optional base fee
      prevRandao:  Hash256;         ## tx env: POS block randomness
      difficulty:  UInt256,         ## tx env: difficulty
      miner:       EthAddress;      ## tx env: coinbase(PoW) or signer(PoA)
      com:         CommonRef;       ## block chain config
      tracerFlags: set[TracerFlags] = {}): T
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
    ac          = AccountsCache.init(com.db.db, parent.stateRoot, com.pruneTrie),
    parent      = parent,
    timestamp   = timestamp,
    gasLimit    = gasLimit,
    fee         = fee,
    prevRandao  = prevRandao,
    difficulty  = difficulty,
    miner       = miner,
    com         = com,
    tracerFlags = tracerFlags)

proc reinit*(self:      BaseVMState;     ## Object descriptor
             parent:    BlockHeader;     ## parent header, account sync pos.
             timestamp: EthTime;         ## tx env: time stamp
             gasLimit:  GasInt;          ## tx env: gas limit
             fee:       Option[UInt256]; ## tx env: optional base fee
             prevRandao:Hash256;         ## tx env: POS block randomness
             difficulty:UInt256,         ## tx env: difficulty
             miner:     EthAddress;      ## tx env: coinbase(PoW) or signer(PoA)
             ): bool
    {.gcsafe.} =
  ## Re-initialise state descriptor. The `AccountsCache` database is
  ## re-initilaise only if its `rootHash` doe not point to `parent.stateRoot`,
  ## already. Accumulated state data are reset.
  ##
  ## This function returns `true` unless the `AccountsCache` database could be
  ## queries about its `rootHash`, i.e. `isTopLevelClean` evaluated `true`. If
  ## this function returns `false`, the function argument `self` is left
  ## untouched.
  if self.stateDB.isTopLevelClean:
    let
      tracer = self.tracer
      com    = self.com
      db     = com.db
      ac     = if self.stateDB.rootHash == parent.stateRoot: self.stateDB
               else: AccountsCache.init(db.db, parent.stateRoot, com.pruneTrie)
    self[].reset
    self.init(
      ac          = ac,
      parent      = parent,
      timestamp   = timestamp,
      gasLimit    = gasLimit,
      fee         = fee,
      prevRandao  = prevRandao,
      difficulty  = difficulty,
      miner       = miner,
      com         = com,
      tracer      = tracer)
    return true
  # else: false

proc reinit*(self:      BaseVMState; ## Object descriptor
             parent:    BlockHeader; ## parent header, account sync pos.
             header:    BlockHeader; ## header with tx environment data fields
             ): bool
    {.gcsafe, raises: [CatchableError].} =
  ## Variant of `reinit()`. The `parent` argument is used to sync the accounts
  ## cache and the `header` is used as a container to pass the `timestamp`,
  ## `gasLimit`, and `fee` values.
  ##
  ## It requires the `header` argument properly initalised so that for PoA
  ## networks, the miner address is retrievable via `ecRecover()`.
  result = self.reinit(
    parent    = parent,
    timestamp = header.timestamp,
    gasLimit  = header.gasLimit,
    fee       = header.fee,
    prevRandao= header.prevRandao,
    difficulty= header.difficulty,
    miner     = self.com.minerAddress(header))

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
      self:        BaseVMState;     ## Object descriptor
      parent:      BlockHeader;     ## parent header, account sync position
      header:      BlockHeader;     ## header with tx environment data fields
      com:         CommonRef;       ## block chain config
      tracerFlags: set[TracerFlags] = {})
    {.gcsafe, raises: [CatchableError].} =
  ## Variant of `new()` constructor above for in-place initalisation. The
  ## `parent` argument is used to sync the accounts cache and the `header`
  ## is used as a container to pass the `timestamp`, `gasLimit`, and `fee`
  ## values.
  ##
  ## It requires the `header` argument properly initalised so that for PoA
  ## networks, the miner address is retrievable via `ecRecover()`.
  self.init(
    ac          = AccountsCache.init(com.db.db, parent.stateRoot, com.pruneTrie),
    parent      = parent,
    timestamp   = header.timestamp,
    gasLimit    = header.gasLimit,
    fee         = header.fee,
    prevRandao  = header.prevRandao,
    difficulty  = header.difficulty,
    miner       = com.minerAddress(header),
    com         = com,
    tracerFlags = tracerFlags)

proc new*(
      T:           type BaseVMState;
      parent:      BlockHeader;     ## parent header, account sync position
      header:      BlockHeader;     ## header with tx environment data fields
      com:         CommonRef;       ## block chain config
      tracerFlags: set[TracerFlags] = {}): T
    {.gcsafe, raises: [CatchableError].} =
  ## This is a variant of the `new()` constructor above where the `parent`
  ## argument is used to sync the accounts cache and the `header` is used
  ## as a container to pass the `timestamp`, `gasLimit`, and `fee` values.
  ##
  ## It requires the `header` argument properly initalised so that for PoA
  ## networks, the miner address is retrievable via `ecRecover()`.
  new result
  result.init(
    parent      = parent,
    header      = header,
    com         = com,
    tracerFlags = tracerFlags)

proc new*(
      T:           type BaseVMState;
      header:      BlockHeader;     ## header with tx environment data fields
      com:         CommonRef;       ## block chain config
      tracerFlags: set[TracerFlags] = {}): T
    {.gcsafe, raises: [CatchableError].} =
  ## This is a variant of the `new()` constructor above where the field
  ## `header.parentHash`, is used to fetch the `parent` BlockHeader to be
  ## used in the `new()` variant, above.
  BaseVMState.new(
    parent      = com.db.getBlockHeader(header.parentHash),
    header      = header,
    com         = com,
    tracerFlags = tracerFlags)

proc init*(
      vmState:     BaseVMState;
      header:      BlockHeader;     ## header with tx environment data fields
      com:         CommonRef;       ## block chain config
      tracerFlags: set[TracerFlags] = {}): bool
    {.gcsafe, raises: [CatchableError].} =
  ## Variant of `new()` which does not throw an exception on a dangling
  ## `BlockHeader` parent hash reference.
  var parent: BlockHeader
  if com.db.getBlockHeader(header.parentHash, parent):
    vmState.init(
      parent      = parent,
      header      = header,
      com         = com,
      tracerFlags = tracerFlags)
    return true

method coinbase*(vmState: BaseVMState): EthAddress {.base, gcsafe.} =
  vmState.minerAddress

method blockNumber*(vmState: BaseVMState): BlockNumber {.base, gcsafe.} =
  # it should return current block number
  # and not head.blockNumber
  vmState.parent.blockNumber + 1

method difficulty*(vmState: BaseVMState): UInt256 {.base, gcsafe.} =
  if vmState.com.consensus == ConsensusType.POS:
    # EIP-4399/EIP-3675
    UInt256.fromBytesBE(vmState.prevRandao.data, allowPadding = false)
  else:
    vmState.blockDifficulty

method baseFee*(vmState: BaseVMState): UInt256 {.base, gcsafe.} =
  if vmState.fee.isSome:
    vmState.fee.get
  else:
    0.u256

when defined(geth):
  import db/geth_db

method getAncestorHash*(
    vmState: BaseVMState, blockNumber: BlockNumber):
    Hash256 {.base, gcsafe, raises: [CatchableError].} =
  let db = vmState.com.db
  when defined(geth):
    result = db.headerHash(blockNumber.truncate(uint64))
  else:
    result = db.getBlockHash(blockNumber)

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
  ReadOnlyStateDB(vmState.stateDB)

template mutateStateDB*(vmState: BaseVMState, body: untyped) =
  block:
    var db {.inject.} = vmState.stateDB
    body

proc getTracingResult*(vmState: BaseVMState): JsonNode {.inline.} =
  doAssert(EnableTracing in vmState.tracer.flags)
  vmState.tracer.trace

proc getAndClearLogEntries*(vmState: BaseVMState): seq[Log] =
  shallowCopy(result, vmState.logEntries)
  vmState.logEntries = @[]

proc enableTracing*(vmState: BaseVMState) =
  vmState.tracer.flags.incl EnableTracing

proc disableTracing*(vmState: BaseVMState) =
  vmState.tracer.flags.excl EnableTracing

func tracingEnabled*(vmState: BaseVMState): bool =
  EnableTracing in vmState.tracer.flags

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

proc tracerGasUsed*(vmState: BaseVMState, gasUsed: GasInt) =
  vmState.tracer.gasUsed = gasUsed

proc tracerGasUsed*(vmState: BaseVMState): GasInt =
  vmState.tracer.gasUsed

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

proc buildWitness*(vmState: BaseVMState): seq[byte]
    {.raises: [CatchableError].} =
  let rootHash = vmState.stateDB.rootHash
  let mkeys = vmState.stateDB.makeMultiKeys()
  let flags = if vmState.fork >= FkSpurious: {wfEIP170} else: {}

  # build witness from tree
  var wb = initWitnessBuilder(vmState.com.db.db, rootHash, flags)
  safeExecutor("buildWitness"):
    result = wb.buildWitness(mkeys)
