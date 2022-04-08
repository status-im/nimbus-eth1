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
  ../constants,
  ../db/[db_chain, accounts_cache],
  ../errors,
  ../forks,
  ../utils/[difficulty, ec_recover],
  ./transaction_tracer,
  ./types,
  eth/[common, keys]

{.push raises: [Defect].}

const
  nilHash = block:
    var rc: Hash256
    rc

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

proc isTtdReached(db: BaseChainDB; blockHash: Hash256): bool
    {.gcsafe, raises: [Defect,RlpError].} =
  ## Returns `true` iff the stored sum of difficulties has reached the
  ## terminal total difficulty, see EIP3675.
  if db.config.terminalTotalDifficulty.isSome:
    return db.config.terminalTotalDifficulty.get <= db.getScore(blockHash)

proc getMinerAddress(chainDB: BaseChainDB; header: BlockHeader): EthAddress
    {.gcsafe, raises: [Defect,CatchableError].} =
  if not chainDB.config.poaEngine or chainDB.isTtdReached(header.parentHash):
    return header.coinbase

  let account = header.ecRecover
  if account.isErr:
    let msg = "Could not recover account address: " & $account.error
    raise newException(ValidationError, msg)

  account.value

proc init(
      self:        BaseVMState;
      ac:          AccountsCache;
      parent:      BlockHeader;
      timestamp:   EthTime;
      gasLimit:    GasInt;
      fee:         Option[UInt256];
      prevRandao:  Hash256;
      miner:       EthAddress;
      chainDB:     BaseChainDB;
      ttdReached:  bool;
      tracer:      TransactionTracer)
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Initialisation helper
  self.prevHeaders = @[]
  self.name = "BaseVM"
  self.parent = parent
  self.timestamp = timestamp
  self.gasLimit = gasLimit
  self.fee = fee
  self.prevRandao = prevRandao
  self.chainDB = chainDB
  self.ttdReached = ttdReached
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
      miner:       EthAddress;
      chainDB:     BaseChainDB;
      tracerFlags: set[TracerFlags])
    {.gcsafe, raises: [Defect,CatchableError].} =
  var tracer: TransactionTracer
  tracer.initTracer(tracerFlags)
  self.init(
    ac        = ac,
    parent    = parent,
    timestamp = timestamp,
    gasLimit  = gasLimit,
    fee       = fee,
    prevRandao= prevRandao,
    miner     = miner,
    chainDB   = chainDB,
    ttdReached= chainDB.isTtdReached(parent.blockHash),
    tracer    = tracer)

# --------------

proc `$`*(vmState: BaseVMState): string
    {.gcsafe, raises: [Defect,ValueError].} =
  if vmState.isNil:
    result = "nil"
  else:
    result = &"VMState {vmState.name}:"&
             &"\n  blockNumber: {vmState.parent.blockNumber + 1}"&
             &"\n  chaindb:  {vmState.chaindb}"

proc new*(
      T:           type BaseVMState;
      parent:      BlockHeader;     ## parent header, account sync position
      timestamp:   EthTime;         ## tx env: time stamp
      gasLimit:    GasInt;          ## tx env: gas limit
      fee:         Option[UInt256]; ## tx env: optional base fee
      prevRandao:  Hash256;         ## tx env: POS block randomness
      miner:       EthAddress;      ## tx env: coinbase(PoW) or signer(PoA)
      chainDB:     BaseChainDB;     ## block chain database
      tracerFlags: set[TracerFlags] = {};
      pruneTrie:   bool = true): T
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Create a new `BaseVMState` descriptor from a parent block header. This
  ## function internally constructs a new account state cache rooted at
  ## `parent.stateRoot`
  ##
  ## This `new()` constructor and its variants (see below) provide a save
  ## `BaseVMState` environment where the account state cache is synchronised
  ## with the `parent` block header.
  new result
  result.init(
    ac          = AccountsCache.init(chainDB.db, parent.stateRoot, pruneTrie),
    parent      = parent,
    timestamp   = timestamp,
    gasLimit    = gasLimit,
    fee         = fee,
    prevRandao  = prevRandao,
    miner       = miner,
    chainDB     = chainDB,
    tracerFlags = tracerFlags)

proc reinit*(self:      BaseVMState;     ## Object descriptor
             parent:    BlockHeader;     ## parent header, account sync pos.
             timestamp: EthTime;         ## tx env: time stamp
             gasLimit:  GasInt;          ## tx env: gas limit
             fee:       Option[UInt256]; ## tx env: optional base fee
             prevRandao:Hash256;         ## tx env: POS block randomness
             miner:     EthAddress;      ## tx env: coinbase(PoW) or signer(PoA)
             pruneTrie: bool = true): bool
    {.gcsafe, raises: [Defect,CatchableError].} =
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
      db     = self.chainDB
      ac     = if self.stateDB.rootHash == parent.stateRoot: self.stateDB
               else: AccountsCache.init(db.db, parent.stateRoot, pruneTrie)
    self[].reset
    self.init(
      ac          = ac,
      parent      = parent,
      timestamp   = timestamp,
      gasLimit    = gasLimit,
      fee         = fee,
      prevRandao  = prevRandao,
      miner       = miner,
      chainDB     = db,
      ttdReached  = db.isTtdReached(parent.blockHash),
      tracer      = tracer)
    return true
  # else: false

proc reinit*(self:      BaseVMState; ## Object descriptor
             parent:    BlockHeader; ## parent header, account sync pos.
             header:    BlockHeader; ## header with tx environment data fields
             pruneTrie: bool = true): bool
    {.gcsafe, raises: [Defect,CatchableError].} =
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
    miner     = self.chainDB.getMinerAddress(header),
    pruneTrie = pruneTrie)

proc reinit*(self:      BaseVMState; ## Object descriptor
             header:    BlockHeader; ## header with tx environment data fields
             pruneTrie: bool = true): bool
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## This is a variant of the `reinit()` function above where the field
  ## `header.parentHash`, is used to fetch the `parent` BlockHeader to be
  ## used in the `update()` variant, above.
  self.reinit(
    parent    = self.chainDB.getBlockHeader(header.parentHash),
    header    = header,
    pruneTrie = pruneTrie)


proc init*(
      self:        BaseVMState;     ## Object descriptor
      parent:      BlockHeader;     ## parent header, account sync position
      header:      BlockHeader;     ## header with tx environment data fields
      chainDB:     BaseChainDB;     ## block chain database
      tracerFlags: set[TracerFlags] = {},
      pruneTrie:   bool = true)
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Variant of `new()` constructor above for in-place initalisation. The
  ## `parent` argument is used to sync the accounts cache and the `header`
  ## is used as a container to pass the `timestamp`, `gasLimit`, and `fee`
  ## values.
  ##
  ## It requires the `header` argument properly initalised so that for PoA
  ## networks, the miner address is retrievable via `ecRecover()`.
  self.init(
    ac          = AccountsCache.init(chainDB.db, parent.stateRoot, pruneTrie),
    parent      = parent,
    timestamp   = header.timestamp,
    gasLimit    = header.gasLimit,
    fee         = header.fee,
    prevRandao  = header.prevRandao,
    miner       = chainDB.getMinerAddress(header),
    chainDB     = chainDB,
    tracerFlags = tracerFlags)

proc new*(
      T:           type BaseVMState;
      parent:      BlockHeader;     ## parent header, account sync position
      header:      BlockHeader;     ## header with tx environment data fields
      chainDB:     BaseChainDB;     ## block chain database
      tracerFlags: set[TracerFlags] = {},
      pruneTrie:   bool = true): T
    {.gcsafe, raises: [Defect,CatchableError].} =
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
    chainDB     = chainDB,
    tracerFlags = tracerFlags,
    pruneTrie   = pruneTrie)

proc new*(
      T:           type BaseVMState;
      header:      BlockHeader;     ## header with tx environment data fields
      chainDB:     BaseChainDB;     ## block chain database
      tracerFlags: set[TracerFlags] = {};
      pruneTrie:   bool = true): T
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## This is a variant of the `new()` constructor above where the field
  ## `header.parentHash`, is used to fetch the `parent` BlockHeader to be
  ## used in the `new()` variant, above.
  BaseVMState.new(
    parent      = chainDB.getBlockHeader(header.parentHash),
    header      = header,
    chainDB     = chainDB,
    tracerFlags = tracerFlags,
    pruneTrie   = pruneTrie)


proc consensusEnginePoA*(vmState: BaseVMState): bool =
  # PoA consensus engine have no reward for miner
  # TODO: this need to be fixed somehow
  # using `real` engine configuration
  vmState.chainDB.config.poaEngine

method coinbase*(vmState: BaseVMState): EthAddress {.base, gcsafe.} =
  vmState.minerAddress

method blockNumber*(vmState: BaseVMState): BlockNumber {.base, gcsafe.} =
  # it should return current block number
  # and not head.blockNumber
  vmState.parent.blockNumber + 1

method difficulty*(vmState: BaseVMState): UInt256 {.base, gcsafe.} =
  if vmState.ttdReached:
    # EIP-4399/EIP-3675
    UInt256.fromBytesBE(vmState.prevRandao.data, allowPadding = false)
  else:
    vmState.chainDB.config.calcDifficulty(vmState.timestamp, vmState.parent)

method baseFee*(vmState: BaseVMState): UInt256 {.base, gcsafe.} =
  if vmState.fee.isSome:
    vmState.fee.get
  else:
    0.u256

when defined(geth):
  import db/geth_db

method getAncestorHash*(vmState: BaseVMState, blockNumber: BlockNumber): Hash256 {.base, gcsafe, raises: [Defect,CatchableError,Exception].} =
  var ancestorDepth = vmState.blockNumber - blockNumber - 1
  if ancestorDepth >= constants.MAX_PREV_HEADER_DEPTH:
    return
  if blockNumber >= vmState.blockNumber:
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
    {.raises: [Defect, CatchableError].} =
  let rootHash = vmState.stateDB.rootHash
  let mkeys = vmState.stateDB.makeMultiKeys()
  let flags = if vmState.fork >= FkSpurious: {wfEIP170} else: {}

  # build witness from tree
  var wb = initWitnessBuilder(vmState.chainDB.db, rootHash, flags)
  safeExecutor("buildWitness"):
    result = wb.buildWitness(mkeys)
