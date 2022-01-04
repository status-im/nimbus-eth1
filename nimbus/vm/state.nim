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
  ../chain_config,
  ../constants,
  ../db/[db_chain, accounts_cache],
  ../errors,
  ../forks,
  ../utils/[difficulty, ec_recover],
  ./interpreter/gas_costs,
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

proc getMinerAddress(chainDB: BaseChainDB; header: BlockHeader): EthAddress
    {.gcsafe, raises: [Defect,CatchableError].} =
  if not chainDB.config.poaEngine:
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
      fee:         Option[Uint256];
      miner:       EthAddress;
      chainDB:     BaseChainDB;
      tracerFlags: set[TracerFlags])
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Initialisation helper
  self.prevHeaders = @[]
  self.name = "BaseVM"
  self.parent = parent
  self.timestamp = timestamp
  self.gasLimit = gasLimit
  self.fee = fee
  self.chaindb = chainDB
  self.tracer.initTracer(tracerFlags)
  self.logEntries = @[]
  self.stateDB = ac
  self.touchedAccounts = initHashSet[EthAddress]()
  self.minerAddress = miner

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
      fee:         Option[Uint256]; ## tx env: optional base fee
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
  ## with the `parent` block header. It is to be preferred over the legacy
  ## `newBaseVMState()` function where there is no provision made that the
  ## account state cache is in sync with the parent of the `header` argument.
  ##
  ## Moreover, the `header` might not even exist when it is to be constructed
  ## by running transactions which leads to guessing what kind of made up
  ## header might do.
  new result
  result.init(
    ac          = AccountsCache.init(chainDB.db, parent.stateRoot, pruneTrie),
    parent      = parent,
    timestamp   = timestamp,
    gasLimit    = gasLimit,
    fee         = fee,
    miner       = miner,
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
  BaseVMState.new(
    parent      = parent,
    timestamp   = header.timestamp,
    gasLimit    = header.gasLimit,
    fee         = header.fee,
    miner       = chainDB.getMinerAddress(header),
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

proc legacyInit*(
      self:        BaseVMState;
      ac:          AccountsCache;   ## accounts db synced with header's parent
      header:      BlockHeader;     ## header with tx environment data fields
      chainDB:     BaseChainDB;     ## block chain database
      tracerFlags: set[TracerFlags] = {})
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Legacy function for initialising the result of `newBaseVMState()`.
  ##
  ## If the `header` argument implies sort of a parent header, it is
  ## initialised. On PoA networks, the miner address must be retrievable
  ## from the `header` argument via `ecRecover()`.
  var parent: BlockHeader
  if header.parentHash != nilHash:
    if not chainDB.getBlockHeader(header.parentHash, parent):
      parent.blockNumber = header.blockNumber - 1
  elif 1.u256 < header.blockNumber:
    if not chainDB.getBlockHeader(header.blockNumber - 1.u256, parent):
      parent.blockNumber = header.blockNumber - 1

  self.init(ac,
            parent,
            header.timestamp,
            header.gasLimit,
            header.fee,
            chainDB.getMinerAddress(header),
            chainDB,
            tracerFlags)


proc setupTxContext*(vmState: BaseVMState, origin: EthAddress, gasPrice: GasInt, forkOverride=none(Fork)) =
  ## this proc will be called each time a new transaction
  ## is going to be executed
  vmState.txOrigin = origin
  vmState.txGasPrice = gasPrice
  vmState.fork =
    if forkOverride.isSome:
      forkOverride.get
    else:
      vmState.chainDB.config.toFork(vmState.parent.blockNumber + 1)
  vmState.gasCosts = vmState.fork.forkToSchedule

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
  vmState.chainDB.config.calcDifficulty(vmState.timestamp, vmState.parent)

method baseFee*(vmState: BaseVMState): UInt256 {.base, gcsafe.} =
  if vmState.fee.isSome:
    vmState.fee.get
  else:
    0.u256

when defined(geth):
  import db/geth_db

method getAncestorHash*(vmState: BaseVMState, blockNumber: BlockNumber): Hash256 {.base, gcsafe, raises: [Defect,CatchableError].} =
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
  let flags = if vmState.fork >= FKSpurious: {wfEIP170} else: {}

  # build witness from tree
  var wb = initWitnessBuilder(vmState.chainDB.db, rootHash, flags)
  safeExecutor("buildWitness"):
    result = wb.buildWitness(mkeys)
