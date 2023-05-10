import
  std/[times],
  eth/[common, rlp],
  eth/trie/db,
  #stew/results,
  stint, chronicles,
  ../db/[db_chain, storage_types],
  ".."/[utils, chain_config],
  ../p2p/chain

{.push raises: [].}

logScope:
  topics = "skeleton"

type
  # Contiguous header chain segment that is backed by the database,
  # but may not be linked to the live chain. The skeleton downloader may produce
  # a new one of these every time it is restarted until the subchain grows large
  # enough to connect with a previous subchain.
  SkeletonSubchain* = object
    head*: UInt256 # Block number of the newest header in the subchain
    tail*: UInt256 # Block number of the oldest header in the subchain
    next*: Hash256 # Block hash of the next oldest header in the subchain

  # Database entry to allow suspending and resuming a chain
  # sync. As the skeleton header chain is downloaded backwards, restarts can and
  # will produce temporarily disjoint subchains. There is no way to restart a
  # suspended skeleton sync without prior knowledge of all prior suspension points.
  SkeletonProgress = seq[SkeletonSubchain]

  # The Skeleton chain class helps support beacon sync by accepting head blocks
  # while backfill syncing the rest of the chain.
  SkeletonRef* = ref object
    subchains: SkeletonProgress
    started  : Time         # Timestamp when the skeleton syncer was created
    logged   : Time         # Timestamp when progress was last logged to user
    pulled   : int64        # Number of headers downloaded in this run
    filling  : bool         # Whether we are actively filling the canonical chain
    chainTTD : DifficultyInt
    chainDB  : ChainDBRef
    chain    : Chain

    # config
    skeletonFillCanonicalBackStep: int
    skeletonSubchainMergeMinimum: int
    syncTargetHeight: int
    ignoreTxs: bool

  SkeletonError*  = object of CatchableError

  # SyncReorged is an internal helper error to signal that the head chain of
  # the current sync cycle was (partially) reorged, thus the skeleton syncer
  # should abort and restart with the new state.
  ErrSyncReorged* = object of SkeletonError

  # ReorgDenied is returned if an attempt is made to extend the beacon chain
  # with a new header, but it does not link up to the existing sync.
  ErrReorgDenied* = object of SkeletonError

  # SyncMerged is an internal helper error to signal that the current sync
  # cycle merged with a previously aborted subchain, thus the skeleton syncer
  # should abort and restart with the new state.
  ErrSyncMerged*  = object of SkeletonError

  ErrHeaderNotFound* = object of SkeletonError

const
  # How often to log sync status (in ms)
  STATUS_LOG_INTERVAL = initDuration(microseconds = 8000)

proc new*(_: type SkeletonRef, chain: Chain): SkeletonRef =
  new(result)
  result.chain   = chain
  result.chainDB = chain.db
  result.started = getTime()
  result.logged  = getTime()
  result.pulled  = 0'i64
  result.filling = false
  result.chainTTD = chain.db.ttd()
  result.skeletonFillCanonicalBackStep = 100
  result.skeletonSubchainMergeMinimum = 1000
  #result.syncTargetHeight = ?
  result.ignoreTxs = false

template get(sk: SkeletonRef, key: untyped): untyped =
  get(sk.chainDB.db, key.toOpenArray)

template put(sk: SkeletonRef, key, val: untyped): untyped =
  put(sk.chainDB.db, key.toOpenArray, val)

template del(sk: SkeletonRef, key: untyped): untyped =
  del(sk.chainDB.db, key.toOpenArray)

template toFork(sk: SkeletonRef, number: untyped): untyped =
  toFork(sk.chainDB.config, number)

template blockHeight(sk: SkeletonRef): untyped =
  sk.chainDB.currentBlock

# Reads the SkeletonProgress from db
proc readSyncProgress(sk: SkeletonRef) {.raises: [RlpError].} =
  let rawProgress = sk.get(skeletonProgressKey())
  if rawProgress.len == 0: return
  sk.subchains = rlp.decode(rawProgress, SkeletonProgress)

# Writes the SkeletonProgress to db
proc writeSyncProgress(sk: SkeletonRef) =
  for x in sk.subchains:
    debug "Writing sync progress subchains",
      head=x.head, tail=x.tail, next=short(x.next)

  let encodedProgress = rlp.encode(sk.subchains)
  sk.put(skeletonProgressKey(), encodedProgress)

proc open*(sk: SkeletonRef){.raises: [RlpError].}  =
  sk.readSyncProgress()
  sk.started = getTime()

# Gets a block from the skeleton or canonical db by number.
proc getHeader*(sk: SkeletonRef,
               number: BlockNumber,
               output: var BlockHeader,
               onlySkeleton: bool = false): bool {.raises: [RlpError].} =
  let rawHeader = sk.get(skeletonBlockKey(number))
  if rawHeader.len != 0:
    output = rlp.decode(rawHeader, BlockHeader)
    return true
  else:
   if onlySkeleton: return false
   # As a fallback, try to get the block from the canonical chain in case it is available there
   return sk.chainDB.getBlockHeader(number, output)

# Gets a skeleton block from the db by hash
proc getHeaderByHash*(sk: SkeletonRef,
                      hash: Hash256,
                      output: var BlockHeader): bool {.raises: [RlpError].} =
  let rawNumber = sk.get(skeletonBlockHashToNumberKey(hash))
  if rawNumber.len == 0:
    return false
  return sk.getHeader(rlp.decode(rawNumber, BlockNumber), output)

# Deletes a skeleton block from the db by number
proc deleteBlock(sk: SkeletonRef, header: BlockHeader) =
  sk.del(skeletonBlockKey(header.blockNumber))
  sk.del(skeletonBlockHashToNumberKey(header.blockHash))
  sk.del(skeletonTransactionKey(header.blockNumber))

# Writes a skeeton block to the db by number
proc putHeader*(sk: SkeletonRef, header: BlockHeader) =
  let encodedHeader = rlp.encode(header)
  sk.put(skeletonBlockKey(header.blockNumber), encodedHeader)
  sk.put(
    skeletonBlockHashToNumberKey(header.blockHash),
    rlp.encode(header.blockNumber)
  )

proc putBlock(sk: SkeletonRef, header: BlockHeader, txs: openArray[Transaction]) =
  let encodedHeader = rlp.encode(header)
  sk.put(skeletonBlockKey(header.blockNumber), encodedHeader)
  sk.put(
    skeletonBlockHashToNumberKey(header.blockHash),
    rlp.encode(header.blockNumber)
  )
  sk.put(skeletonTransactionKey(header.blockNumber), rlp.encode(txs))

proc getTxs(
    sk: SkeletonRef, number: BlockNumber,
    output: var seq[Transaction]) {.raises: [CatchableError].} =
  let rawTxs = sk.get(skeletonTransactionKey(number))
  if rawTxs.len > 0:
    output = rlp.decode(rawTxs, seq[Transaction])
  else:
    raise newException(SkeletonError,
      "getTxs: no transactions from block number " & $number)

# Bounds returns the current head and tail tracked by the skeleton syncer.
proc bounds*(sk: SkeletonRef): SkeletonSubchain =
  sk.subchains[0]

# Returns true if the skeleton chain is linked to canonical
proc isLinked*(sk: SkeletonRef): bool {.raises: [CatchableError].} =
  if sk.subchains.len == 0: return false
  let sc = sk.bounds()

  # make check for genesis if tail is 1?
  let head = sk.blockHeight
  if sc.tail > head + 1.toBlockNumber:
    return false

  var nextHeader: BlockHeader
  let number = sc.tail - 1.toBlockNumber
  if sk.getHeader(number, nextHeader):
    return sc.next == nextHeader.blockHash
  else:
    raise newException(ErrHeaderNotFound, "isLinked: No header with number=" & $number)

proc trySubChainsMerge(sk: SkeletonRef): bool {.raises: RlpError].} =
  var
    merged = false
    edited = false
    head: BlockHeader

  let subchainMergeMinimum = sk.skeletonSubchainMergeMinimum.u256
  # If the subchain extended into the next subchain, we need to handle
  # the overlap. Since there could be many overlaps, do this in a loop.
  while sk.subchains.len > 1 and
        sk.subchains[1].head >= sk.subchains[0].tail:
    # Extract some stats from the second subchain
    let sc = sk.subchains[1]

    # Since we just overwrote part of the next subchain, we need to trim
    # its head independent of matching or mismatching content
    if sc.tail >= sk.subchains[0].tail:
      # Fully overwritten, get rid of the subchain as a whole
      debug "Previous subchain fully overwritten",
        head=sc.head, tail=sc.tail, next=short(sc.next)
      sk.subchains.delete(1)
      edited = true
      continue
    else:
      # Partially overwritten, trim the head to the overwritten size
      debug "Previous subchain partially overwritten",
        head=sc.head, tail=sc.tail, next=short(sc.next)
      sk.subchains[1].head = sk.subchains[0].tail - 1.toBlockNumber
      edited = true

    # If the old subchain is an extension of the new one, merge the two
    # and let the skeleton syncer restart (to clean internal state)
    if sk.getHeader(sk.subchains[1].head, head) and
       head.blockHash == sk.subchains[0].next:
      # only merge is we can integrate a big progress, as each merge leads
      # to disruption of the block fetcher to start a fresh
      if (sc.head - sc.tail) > subchainMergeMinimum:
        debug "Previous subchain merged head",
          head=sc.head, tail=sc.tail, next=short(sc.next)
        sk.subchains[0].tail = sc.tail
        sk.subchains[0].next = sc.next
        sk.subchains.delete(1)
        # If subchains were merged, all further available headers
        # are invalid since we skipped ahead.
        merged = true
      else:
        debug "Subchain ignored for merge",
          head=sc.head, tail=sc.tail, next=short(sc.next)
        sk.subchains.delete(1)
      edited = true

  if edited: sk.writeSyncProgress()
  return merged

proc backStep(sk: SkeletonRef) {.raises: [RlpError].}=
  if sk.skeletonFillCanonicalBackStep <= 0:
    return

  let sc = sk.bounds()
  var
    hasTail: bool
    tailHeader: BlockHeader
    newTail = sc.tail

  while true:
    newTail = newTail + sk.skeletonFillCanonicalBackStep.u256
    hasTail = sk.getHeader(newTail, tailHeader, true)
    if hasTail or newTail > sc.head: break

  if newTail > sc.head:
    newTail = sc.head
    hasTail = sk.getHeader(newTail, tailHeader, true)

  if hasTail and newTail > 0.toBlockNumber:
    trace "Backstepped skeleton", head=sc.head, tail=newTail
    sk.subchains[0].tail = newTail
    sk.subchains[0].next = tailHeader.parentHash
    sk.writeSyncProgress()
  else:
    # we need a new head, emptying the subchains
    sk.subchains = @[]
    sk.writeSyncProgress()
    warn "Couldn't backStep subchain 0, dropping subchains for new head signal"

# processNewHead does the internal shuffling for a new head marker and either
# accepts and integrates it into the skeleton or requests a reorg. Upon reorg,
# the syncer will tear itself down and restart with a fresh head. It is simpler
# to reconstruct the sync state than to mutate it.
#
# @returns true if the chain was reorged
proc processNewHead(
    sk: SkeletonRef,
    head: BlockHeader,
    force = false): bool {.raises: [RlpError].} =
  # If the header cannot be inserted without interruption, return an error for
  # the outer loop to tear down the skeleton sync and restart it
  let number = head.blockNumber

  if sk.subchains.len == 0:
    warn "Skeleton reorged and cleaned, no current subchain", newHead=number
    return true

  let lastchain = sk.subchains[0]
  if lastchain.tail >= number:
    # If the chain is down to a single beacon header, and it is re-announced
    # once more, ignore it instead of tearing down sync for a noop.
    if lastchain.head == lastchain.tail:
      var header: BlockHeader
      let hasHeader = sk.getHeader(number, header)
      # TODO: what should we do when hasHeader == false?
      if hasHeader and header.blockHash == head.blockHash:
        return false

    # Not a noop / double head announce, abort with a reorg
    if force:
      warn "Beacon chain reorged",
        tail=lastchain.tail, head=lastchain.head, newHead=number
    return true

  if lastchain.head + 1.toBlockNumber < number:
    if force:
      warn "Beacon chain gapped",
        head=lastchain.head, newHead=number
    return true

  var parent: BlockHeader
  let hasParent = sk.getHeader(number - 1.toBlockNumber, parent)
  if hasParent and parent.blockHash != head.parentHash:
    if force:
      warn "Beacon chain forked",
        ancestor=parent.blockNumber, hash=short(parent.blockHash),
        want=short(head.parentHash)
    return true

  # Update the database with the new sync stats and insert the new
  # head header. We won't delete any trimmed skeleton headers since
  # those will be outside the index space of the many subchains and
  # the database space will be reclaimed eventually when processing
  # blocks above the current head.
  sk.putHeader(head)
  sk.subchains[0].head = number
  sk.writeSyncProgress()
  return false

# Inserts skeleton blocks into canonical chain and runs execution.
proc fillCanonicalChain*(sk: SkeletonRef) {.raises: [CatchableError].} =
  if sk.filling: return
  sk.filling = true

  var canonicalHead = sk.blockHeight
  let start = canonicalHead
  let sc = sk.bounds()
  debug "Starting canonical chain fill",
    canonicalHead=canonicalHead, subchainHead=sc.head

  var fillLogIndex = 0
  while sk.filling and canonicalHead < sc.head:
    # Get next block
    let number = canonicalHead + 1.toBlockNumber
    var header: BlockHeader
    let hasHeader = sk.getHeader(number, header)
    if not hasHeader:
      # This shouldn't happen, but if it does because of some issues, we should back step
      # and fetch again
      debug "fillCanonicalChain block number not found, backStepping",
        number=number
      sk.backStep()
      break

    # Insert into chain
    var body: BlockBody
    if not sk.ignoreTxs:
      sk.getTxs(header.blockNumber, body.transactions)
    let res = sk.chain.persistBlocks([header], [body])
    if res != ValidationResult.OK:
      let hardFork = sk.toFork(number)
      error "Failed to put block from skeleton chain to canonical",
        number=number,
        fork=hardFork,
        hash=short(header.blockHash)

      sk.backStep()
      break

    # Delete skeleton block to clean up as we go
    sk.deleteBlock(header)
    canonicalHead += 1.toBlockNumber
    inc fillLogIndex # num block inserted
    if fillLogIndex > 50:
      trace "Skeleton canonical chain fill status",
        canonicalHead=canonicalHead,
        chainHead=sk.blockHeight,
        subchainHead=sc.head
      fillLogIndex = 0

  sk.filling = false
  trace "Successfully put blocks from skeleton chain to canonical target",
    start=start, stop=canonicalHead, skeletonHead=sc.head,
    syncTargetHeight=sk.syncTargetHeight

# Announce and integrate a new head.
# throws if the new head causes a reorg.
proc setHead*(
    sk: SkeletonRef, head: BlockHeader,
    force = false) {.raises: [CatchableError].} =
  debug "New skeleton head announced",
    number=head.blockNumber,
    hash=short(head.blockHash),
    force=force

  let reorged = sk.processNewHead(head, force)

  # If linked, fill the canonical chain.
  if force and sk.isLinked():
    sk.fillCanonicalChain()

  if reorged:
    if force:
      raise newException(ErrSyncReorged, "setHead: sync reorg")
    else:
      raise newException(ErrReorgDenied, "setHead: reorg denied")

# Attempts to get the skeleton sync into a consistent state wrt any
# past state on disk and the newly requested head to sync to.
proc initSync*(
    sk: SkeletonRef, head: BlockHeader) {.raises: [CatchableError].} =
  let number = head.blockNumber

  if sk.subchains.len == 0:
    # Start a fresh sync with a single subchain represented by the currently sent
    # chain head.
    sk.subchains.add(SkeletonSubchain(
      head: number,
      tail: number,
      next: head.parentHash
    ))
    debug "Created initial skeleton subchain",
      head=number, tail=number
  else:
    # Print some continuation logs
    for x in sk.subchains:
      debug "Restarting skeleton subchain",
        head=x.head, tail=x.tail, next=short(x.next)

    # Create a new subchain for the head (unless the last can be extended),
    # trimming anything it would overwrite
    let headchain = SkeletonSubchain(
      head: number,
      tail: number,
      next: head.parentHash
    )

    while sk.subchains.len > 0:
      # If the last chain is above the new head, delete altogether
      let lastchain = addr sk.subchains[0]
      if lastchain.tail >= headchain.tail:
        debug "Dropping skeleton subchain",
          head=lastchain.head, tail=lastchain.tail
        sk.subchains.delete(0) # remove `lastchain`
        continue
      # Otherwise truncate the last chain if needed and abort trimming
      if lastchain.head >= headchain.tail:
        debug "Trimming skeleton subchain",
          oldHead=lastchain.head, newHead=headchain.tail - 1.toBlockNumber,
          tail=lastchain.tail
        lastchain.head = headchain.tail - 1.toBlockNumber
      break

    # If the last subchain can be extended, we're lucky. Otherwise create
    # a new subchain sync task.
    var extended = false
    if sk.subchains.len > 0:
      let lastchain = addr sk.subchains[0]
      if lastchain.head == headchain.tail - 1.toBlockNumber:
        var header: BlockHeader
        let lasthead = sk.getHeader(lastchain.head, header)
        if lasthead and header.blockHash == head.parentHash:
          debug "Extended skeleton subchain with new",
            head=headchain.tail, tail=lastchain.tail
          lastchain.head = headchain.tail
          extended = true
    if not extended:
      debug "Created new skeleton subchain",
        head=number, tail=number
      sk.subchains.insert(headchain)

  sk.putHeader(head)
  sk.writeSyncProgress()

  # If the sync is finished, start filling the canonical chain.
  if sk.isLinked():
    sk.fillCanonicalChain()

# Writes skeleton blocks to the db by number
# @returns number of blocks saved
proc putBlocks*(
    sk: SkeletonRef, headers: openArray[BlockHeader]):
    int {.raises: [CatchableError].} =
  var merged = false

  if headers.len > 0:
    let first {.used.} = headers[0]
    let last  {.used.} = headers[^1]
    let sc    {.used.} = if sk.subchains.len > 0:
                           sk.subchains[0]
                         else:
                           SkeletonSubchain()
    debug "Skeleton putBlocks start",
      count = headers.len,
      first = first.blockNumber,
      hash  = short(first.blockHash),
      fork  = sk.toFork(first.blockNumber),
      last  = last.blockNumber,
      hash  = short(last.blockHash),
      fork  = sk.toFork(last.blockNumber),
      head  = sc.head,
      tail  = sc.tail,
      next  = short(sc.next)

  for header in headers:
    let number = header.blockNumber
    if number >= sk.subchains[0].tail:
      # These blocks should already be in skeleton, and might be coming in
      # from previous events especially if the previous subchains merge
      continue

    # Extend subchain or create new segment if necessary
    if sk.subchains[0].next == header.blockHash:
      sk.putHeader(header)
      sk.pulled += 1'i64
      sk.subchains[0].tail -= 1.toBlockNumber
      sk.subchains[0].next = header.parentHash
    else:
      # Critical error, we expect new incoming blocks to extend the canonical
      # subchain which is the [0]'th
      let fork = sk.toFork(number)
      warn "Blocks don't extend canonical subchain",
        head=sk.subchains[0].head,
        tail=sk.subchains[0].tail,
        next=short(sk.subchains[0].next),
        number=number,
        hash=short(header.blockHash),
        fork=fork
      raise newException(SkeletonError, "Blocks don't extend canonical subchain")

    merged = sk.trySubChainsMerge()
    # If its merged, we need to break as the new tail could be quite ahead
    # so we need to clear out and run the reverse block fetcher again
    if merged: break

  sk.writeSyncProgress()

  # Print a progress report making the UX a bit nicer
  if getTime() - sk.logged > STATUS_LOG_INTERVAL:
    var left = sk.bounds().tail - 1.toBlockNumber - sk.blockHeight
    if sk.isLinked(): left = 0.toBlockNumber
    if left > 0.toBlockNumber:
      sk.logged = getTime()
      if sk.pulled == 0:
        info "Beacon sync starting", left=left
      else:
        let sinceStarted = getTime() - sk.started
        let eta = (sinceStarted div sk.pulled) * left.truncate(int64)
        info "Syncing beacon headers",
          downloaded=sk.pulled, left=left, eta=eta

  # If the sync is finished, start filling the canonical chain.
  if sk.isLinked():
    sk.fillCanonicalChain()

  if merged:
    raise newException(ErrSyncMerged, "putBlocks: sync merged")

  return headers.len

proc `subchains=`*(sk: SkeletonRef, subchains: openArray[SkeletonSubchain]) =
  sk.subchains = @subchains

proc len*(sk: SkeletonRef): int =
  sk.subchains.len

iterator items*(sk: SkeletonRef): SkeletonSubChain =
  for x in sk.subchains:
    yield x

iterator pairs*(sk: SkeletonRef): tuple[key: int, val: SkeletonSubChain] =
  for i, x in sk.subchains:
    yield (i, x)

proc ignoreTxs*(sk: SkeletonRef): bool =
  sk.ignoreTxs

proc `ignoreTxs=`*(sk: SkeletonRef, val: bool) =
  sk.ignoreTxs = val
