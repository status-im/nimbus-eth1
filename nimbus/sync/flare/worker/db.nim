# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/chronicles,
  pkg/eth/[common, rlp],
  pkg/stew/[interval_set, sorted_set],
  pkg/results,
  ../../../db/[era1_db, storage_types],
  ../../../common,
  ../../sync_desc,
  ../worker_desc,
  "."/[staged, unproc]

logScope:
  topics = "flare db"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

  LhcStateKey = 1.flareStateKey

type
  SavedDbStateSpecs = tuple
    number: BlockNumber
    hash: Hash256
    parent: Hash256

  Era1Specs = tuple
    e1db: Era1DbRef
    maxNum: BlockNumber

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template hasKey(e1db: Era1DbRef; bn: BlockNumber): bool =
  e1db.getEthBlock(bn).isOk

proc newEra1Desc(networkID: NetworkID; era1Dir: string): Opt[Era1Specs] =
  const info = "newEra1Desc"
  var specs: Era1Specs

  case networkID:
  of MainNet:
    specs.e1db = Era1DbRef.init(era1Dir, "mainnet").valueOr:
      when extraTraceMessages:
        trace info & ": no Era1 available", networkID, era1Dir
      return err()
    specs.maxNum = 15_537_393'u64 # Mainnet, copied from `nimbus_import`

  of SepoliaNet:
    specs.e1db = Era1DbRef.init(era1Dir, "sepolia").valueOr:
      when extraTraceMessages:
        trace info & ": no Era1 available", networkID, era1Dir
      return err()
    specs.maxNum = 1_450_408'u64 # Sepolia

  else:
    when extraTraceMessages:
      trace info & ": Era1 unsupported", networkID
    return err()

  # At least block 1 should be supported
  if not specs.e1db.hasKey 1u64:
    specs.e1db.dispose()
    notice info & ": Era1 repo disfunctional", networkID, blockNumber=1
    return err()

  when extraTraceMessages:
    trace info & ": Era1 supported",
      networkID, lastEra1Block=specs.maxNum.bnStr
  ok(specs)


proc fetchLinkedHChainsLayout(ctx: FlareCtxRef): Opt[LinkedHChainsLayout] =
  let data = ctx.db.ctx.getKvt().get(LhcStateKey.toOpenArray).valueOr:
    return err()
  try:
    result = ok(rlp.decode(data, LinkedHChainsLayout))
  except RlpError:
    return err()

# --------------

proc fetchEra1State(ctx: FlareCtxRef): Opt[SavedDbStateSpecs] =
  var val: SavedDbStateSpecs
  val.number = ctx.pool.e1AvailMax
  if 0 < val.number:
    let header = ctx.pool.e1db.getEthBlock(val.number).value.header
    val.parent = header.parentHash
    val.hash = rlp.encode(header).keccakHash
    return ok(val)
  err()

proc fetchSavedState(ctx: FlareCtxRef): Opt[SavedDbStateSpecs] =
  let
    db = ctx.db
    e1Max = ctx.pool.e1AvailMax

  var val: SavedDbStateSpecs
  val.number = db.getSavedStateBlockNumber()

  if e1Max == 0 or e1Max < val.number:
    if db.getBlockHash(val.number, val.hash):
      var header: BlockHeader
      if db.getBlockHeader(val.hash, header):
        val.parent = header.parentHash
        return ok(val)
    return err()

  ctx.fetchEra1State()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc dbStoreLinkedHChainsLayout*(ctx: FlareCtxRef): bool =
  ## Save chain layout to persistent db
  const info = "dbStoreLinkedHChainsLayout"
  if ctx.layout == ctx.lhc.lastLayout:
    when extraTraceMessages:
      trace info & ": no layout change"
    return false

  let data = rlp.encode(ctx.layout)
  ctx.db.ctx.getKvt().put(LhcStateKey.toOpenArray, data).isOkOr:
    raiseAssert info & " put() failed: " & $$error

  # While executing blocks there are frequent save cycles. Otherwise, an
  # extra save request might help to pick up an interrupted sync session.
  if ctx.db.getSavedStateBlockNumber() == 0:
    ctx.db.persistent(0).isOkOr:
      when extraTraceMessages:
        trace info & ": failed to save layout pesistently", error=($$error)
      return false
    when extraTraceMessages:
      trace info & ": layout saved pesistently"
  true


proc dbLoadLinkedHChainsLayout*(ctx: FlareCtxRef) =
  ## Restore chain layout from persistent db
  const info = "dbLoadLinkedHChainsLayout"
  ctx.stagedInit()
  ctx.unprocInit()

  let rc = ctx.fetchLinkedHChainsLayout()
  if rc.isOk:
    ctx.lhc.layout = rc.value
    let (uMin,uMax) = (rc.value.base+1, rc.value.least-1)
    if uMin <= uMax:
      # Add interval of unprocessed block range `(B,L)` from README
      ctx.unprocMerge(uMin, uMax)
    when extraTraceMessages:
      trace info & ": restored layout"
  else:
    let val = ctx.fetchSavedState().expect "saved states"
    ctx.lhc.layout = LinkedHChainsLayout(
      base:        val.number,
      baseHash:    val.hash,
      least:       val.number,
      leastParent: val.parent,
      final:       val.number,
      finalHash:   val.hash)
    when extraTraceMessages:
      trace info & ": new layout"

  ctx.lhc.lastLayout = ctx.layout


proc dbInitEra1*(ctx: FlareCtxRef): bool =
  ## Initialise Era1 repo.
  const info = "dbInitEra1"
  var specs = ctx.chain.com.networkId.newEra1Desc(ctx.pool.e1Dir).valueOr:
    return false

  ctx.pool.e1db = specs.e1db

  # Verify that last available block number is available
  if specs.e1db.hasKey specs.maxNum:
    ctx.pool.e1AvailMax = specs.maxNum
    when extraTraceMessages:
      trace info, lastEra1Block=specs.maxNum.bnStr
    return true

  # This is a truncated repo. Use bisect for finding the top number assuming
  # that block numbers availability is contiguous.
  #
  # BlockNumber(1) is the least supported block number (was checked
  # in function `newEra1Desc()`)
  var
    minNum = BlockNumber(1)
    middle = (specs.maxNum + minNum) div 2
    delta = specs.maxNum - minNum
  while 1 < delta:
    if specs.e1db.hasKey middle:
      minNum = middle
    else:
      specs.maxNum = middle
    middle = (specs.maxNum + minNum) div 2
    delta = specs.maxNum - minNum

  ctx.pool.e1AvailMax = minNum
  when extraTraceMessages:
    trace info, e1AvailMax=minNum.bnStr
  true

# ------------------

proc dbStashHeaders*(
    ctx: FlareCtxRef;
    first: BlockNumber;
    revBlobs: openArray[Blob];
      ) =
  ## Temporarily store header chain to persistent db (oblivious of the chain
  ## layout.) The headers should not be stashed if they are available on the
  ## `Era1` repo, i.e. if the corresponding block number is at most
  ## `ctx.pool.e1AvailMax`.
  ##
  ## The `revBlobs[]` arguments are passed in reverse order so that block
  ## numbers apply as
  ## ::
  ##    #first     -- revBlobs[^1]
  ##    #(first+1) -- revBlobs[^2]
  ##    ..
  ##
  const info = "dbStashHeaders"
  let
    kvt = ctx.db.ctx.getKvt()
    last = first + revBlobs.len.uint - 1
  for n,data in revBlobs:
    let key = flareHeaderKey(last - n.uint)
    kvt.put(key.toOpenArray, data).isOkOr:
      raiseAssert info & ": put() failed: " & $$error
  when extraTraceMessages:
    trace info & ": headers stashed",
      iv=BnRange.new(first, last), nHeaders=revBlobs.len

proc dbPeekHeader*(ctx: FlareCtxRef; num: BlockNumber): Opt[BlockHeader] =
  ## Retrieve some stashed header.
  if num <= ctx.pool.e1AvailMax:
    return ok(ctx.pool.e1db.getEthBlock(num).value.header)
  let
    key = flareHeaderKey(num)
    rc = ctx.db.ctx.getKvt().get(key.toOpenArray)
  if rc.isOk:
    try:
      return ok(rlp.decode(rc.value, BlockHeader))
    except RlpError:
      discard
  err()

proc dbPeekParentHash*(ctx: FlareCtxRef; num: BlockNumber): Opt[Hash256] =
  ## Retrieve some stashed parent hash.
  ok (? ctx.dbPeekHeader num).parentHash

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
