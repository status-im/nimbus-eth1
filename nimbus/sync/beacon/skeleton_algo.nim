# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  ./skeleton_desc,
  ./skeleton_utils,
  ./skeleton_db,
  ../../utils/utils

{.push gcsafe, raises: [].}

logScope:
  topics = "skeleton"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc fastForwardHead(sk: SkeletonRef, last: Segment, target: uint64): Result[void, string] =
  # Try fast forwarding the chain head to the number
  let
    head = last.head
    maybeHead = sk.getHeader(head, true).valueOr:
      return err(error)

  if maybeHead.isNone:
    return ok()

  var
    headBlock = maybeHead.get
    headBlockHash = headBlock.blockHash

  for newHead in head + 1 .. target:
    let maybeHead = sk.getHeader(newHead, true).valueOr:
      return err(error)

    if maybeHead.isNone:
      break

    let newBlock = maybeHead.get
    if newBlock.parentHash != headBlockHash:
      # Head can't be updated forward
      break

    headBlock = newBlock
    headBlockHash = headBlock.blockHash

  last.head = headBlock.u64
  debug "lastchain head fast forwarded",
    `from`=head, to=last.head, tail=last.tail
  ok()

proc backStep(sk: SkeletonRef): Result[uint64, string] =
  if sk.conf.fillCanonicalBackStep <= 0:
    return ok(0)

  let sc = sk.last
  var
    newTail = sc.tail
    maybeTailHeader: Opt[BlockHeader]

  while true:
    newTail = newTail + sk.conf.fillCanonicalBackStep
    maybeTailHeader = sk.getHeader(newTail, true).valueOr:
      return err(error)
    if maybeTailHeader.isSome or newTail > sc.head: break

  if newTail > sc.head:
    newTail = sc.head
    maybeTailHeader = sk.getHeader(newTail, true).valueOr:
      return err(error)

  if maybeTailHeader.isSome and newTail > 0:
    debug "Backstepped skeleton", head=sc.head, tail=newTail
    let tailHeader = maybeTailHeader.get
    sk.last.tail = tailHeader.u64
    sk.last.next = tailHeader.parentHash
    sk.writeProgress()
    return ok(newTail)

  # we need a new head, emptying the subchains
  sk.clear()
  sk.writeProgress()
  debug "Couldn't backStep subchain 0, dropping subchains for new head signal"
  return ok(0)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc isLinked*(sk: SkeletonRef): Result[bool, string] =
  ## Returns true if the skeleton chain is linked to canonical
  if sk.isEmpty:
    return ok(false)

  let sc = sk.last

  # if its genesis we are linked
  if sc.tail == 0:
    return ok(true)

  let head = sk.blockHeight
  if sc.tail > head + 1:
    return ok(false)

  let number = sc.tail - 1
  let maybeHeader = sk.getHeader(number).valueOr:
    return err("isLinked: " & error)

  # The above sc.tail > head - 1
  # assure maybeHeader.isSome
  doAssert maybeHeader.isSome

  let nextHeader = maybeHeader.get
  let linked = sc.next == nextHeader.blockHash
  if linked and sk.len > 1:
    # Remove all other subchains as no more relevant
    sk.removeAllButLast()
    sk.writeProgress()

  return ok(linked)

proc trySubChainsMerge*(sk: SkeletonRef): Result[bool, string] =
  var
    merged = false
    edited = false

  # If the subchain extended into the next subchain, we need to handle
  # the overlap. Since there could be many overlaps, do this in a loop.
  while sk.len > 1 and sk.second.head >= sk.last.tail:
    # Extract some stats from the second subchain
    let sc = sk.second

    # Since we just overwrote part of the next subchain, we need to trim
    # its head independent of matching or mismatching content
    if sc.tail >= sk.last.tail:
      # Fully overwritten, get rid of the subchain as a whole
      debug "Previous subchain fully overwritten", sub=sc
      sk.removeSecond()
      edited = true
      continue
    else:
      # Partially overwritten, trim the head to the overwritten size
      debug "Previous subchain partially overwritten", sub=sc
      sc.head = sk.last.tail - 1
      edited = true

    # If the old subchain is an extension of the new one, merge the two
    # and let the skeleton syncer restart (to clean internal state)
    let
      maybeSecondHead = sk.getHeader(sk.second.head).valueOr:
        return err(error)
      secondHeadHash = maybeSecondHead.blockHash

    if maybeSecondHead.isSome and secondHeadHash == sk.last.next:
      # only merge if we can integrate a big progress, as each merge leads
      # to disruption of the block fetcher to start a fresh
      if (sc.head - sc.tail) > sk.conf.subchainMergeMinimum:
        debug "Previous subchain merged head", sub=sc
        sk.last.tail = sc.tail
        sk.last.next = sc.next
        sk.removeSecond()
        # If subchains were merged, all further available headers
        # are invalid since we skipped ahead.
        merged = true
      else:
        debug "Subchain ignored for merge", sub=sc
        sk.removeSecond()
      edited = true

  if edited: sk.writeProgress()
  ok(merged)

proc putBlocks*(sk: SkeletonRef, headers: openArray[BlockHeader]):
                  Result[StatusAndNumber, string] =
  ## Writes skeleton blocks to the db by number
  ## @returns number of blocks saved
  var
    merged = false
    tailUpdated = false

  if sk.len == 0:
    return err("no subchain set")

  # best place to debug beacon downloader
  when false:
    var numbers: seq[uint64]
    for header in headers:
      numbers.add header.u64
    debugEcho numbers

  for header in headers:
    let
      number = header.u64
      headerHash = header.blockHash

    if number >= sk.last.tail:
      # These blocks should already be in skeleton, and might be coming in
      # from previous events especially if the previous subchains merge
      continue
    elif number == 0:
      let genesisHash = sk.genesisHash
      if headerHash == genesisHash:
        return err("Skeleton pubBlocks with invalid genesis block " &
          "number=" & $number &
          ", hash=" & headerHash.short &
          ", genesisHash=" & genesisHash.short)
      continue

    # Extend subchain or create new segment if necessary
    if sk.last.next == headerHash:
      sk.putHeader(header)
      sk.pulled += 1
      sk.last.tail = number
      sk.last.next = header.parentHash
      tailUpdated = true
    else:
      # Critical error, we expect new incoming blocks to extend the canonical
      # subchain which is the [0]'th
      debug "Blocks don't extend canonical subchain",
        sub=sk.last,
        number,
        hash=headerHash.short
      return err("Blocks don't extend canonical subchain")

    merged = sk.trySubChainsMerge().valueOr:
      return err(error)

    if tailUpdated or merged:
      sk.progress.canonicalHeadReset = true

    # If its merged, we need to break as the new tail could be quite ahead
    # so we need to clear out and run the reverse block fetcher again
    if merged: break

  sk.writeProgress()

  # Print a progress report making the UX a bit nicer
  #if getTime() - sk.logged > STATUS_LOG_INTERVAL:
  #  var left = sk.last.tail - 1 - sk.blockHeight
  #  if sk.progress.linked: left = 0
  #  if left > 0:
  #    sk.logged = getTime()
  #    if sk.pulled == 0:
  #      info "Beacon sync starting", left=left
  #    else:
  #      let sinceStarted = getTime() - sk.started
  #      let eta = (sinceStarted div sk.pulled.int64) * left.int64
  #      info "Syncing beacon headers",
  #        downloaded=sk.pulled, left=left, eta=eta.short

  sk.progress.linked = sk.isLinked().valueOr:
    return err(error)

  var res = StatusAndNumber(number: headers.len.uint64)
  # If the sync is finished, start filling the canonical chain.
  if sk.progress.linked:
    res.status.incl FillCanonical

  if merged:
    res.status.incl SyncMerged
  ok(res)

# Inserts skeleton blocks into canonical chain and runs execution.
proc fillCanonicalChain*(sk: SkeletonRef): Result[void, string] =
  if sk.filling: return ok()
  sk.filling = true

  var
    canonicalHead = sk.blockHeight
    maybeOldHead = Opt.none BlockHeader

  let subchain = sk.last
  if sk.progress.canonicalHeadReset:
    # Grab previous head block in case of resettng canonical head
    let oldHead = sk.canonicalHead().valueOr:
      return err(error)
    maybeOldHead = Opt.some oldHead

    if subchain.tail > canonicalHead + 1:
      return err("Canonical head should already be on or " &
        "ahead subchain tail canonicalHead=" &
        $canonicalHead & ", tail=" & $subchain.tail)

    let newHead = if subchain.tail > 0: subchain.tail - 1
                  else: 0
    debug "Resetting canonicalHead for fillCanonicalChain",
      `from`=canonicalHead, to=newHead

    canonicalHead = newHead
    sk.resetCanonicalHead(canonicalHead, oldHead.u64)
    sk.progress.canonicalHeadReset = false

  let start {.used.} = canonicalHead
  # This subchain is a reference to update the tail for
  # the very subchain we are filling the data for

  debug "Starting canonical chain fill",
    canonicalHead, subchainHead=subchain.head

  while sk.filling and canonicalHead < subchain.head:
    # Get next block
    let
      number = canonicalHead + 1
      maybeHeader = sk.getHeader(number).valueOr:
        return err(error)

    if maybeHeader.isNone:
      # This shouldn't happen, but if it does because of some issues,
      # we should back step and fetch again
      debug "fillCanonicalChain block not found, backStepping", number
      sk.backStep().isOkOr:
        return err(error)
      break

    # Insert into chain
    let header = maybeHeader.get
    let res = sk.insertBlock(header, true)
    if res.isErr:
      let maybeHead = sk.getHeader(subchain.head).valueOr:
        return err(error)

      # In post-merge, notify the engine API of encountered bad chains
      if maybeHead.isSome:
        sk.com.notifyBadBlock(header, maybeHead.get)

      debug "fillCanonicalChain putBlock", msg=res.error
      if maybeOldHead.isSome:
        let oldHead = maybeOldHead.get
        if oldHead.u64 >= number:
          # Put original canonical head block back if reorg fails
          sk.insertBlock(oldHead, true).isOkOr:
            return err(error)

    let numBlocksInserted = res.valueOr: 0
    if numBlocksInserted != 1:
      debug "Failed to put block from skeleton chain to canonical",
        number=number,
        hash=header.blockHashStr,
        parentHash=header.parentHash.short

      # Lets log some parent by number and parent by hash, that may help to understand whats going on
      let parent {.used.} = sk.getHeader(number - 1).valueOr:
        return err(error)
      debug "ParentByNumber", number=parent.numberStr, hash=parent.blockHashStr

      let parentWithHash {.used.} = sk.getHeader(header.parentHash).valueOr:
        return err(error)

      debug "parentByHash",
        number=parentWithHash.numberStr,
        hash=parentWithHash.blockHashStr

      sk.backStep().isOkOr:
        return err(error)
      break

    canonicalHead += numBlocksInserted
    sk.fillLogIndex += numBlocksInserted

    # Delete skeleton block to clean up as we go, if block is fetched and chain is linked
    # it will be fetched from the chain without any issues
    sk.deleteHeaderAndBody(header)
    if sk.fillLogIndex >= 20:
      debug "Skeleton canonical chain fill status",
        canonicalHead,
        chainHead=sk.blockHeight,
        subchainHead=subchain.head
      sk.fillLogIndex = 0

  sk.filling = false
  debug "Successfully put blocks from skeleton chain to canonical",
    start, `end`=canonicalHead,
    skeletonHead=subchain.head
  ok()

proc processNewHead*(sk: SkeletonRef, head: BlockHeader,
                     force = false): Result[bool, string] =
  ## processNewHead does the internal shuffling for a new head marker and either
  ## accepts and integrates it into the skeleton or requests a reorg. Upon reorg,
  ## the syncer will tear itself down and restart with a fresh head. It is simpler
  ## to reconstruct the sync state than to mutate it.
  ## @returns true if the chain was reorged

  # If the header cannot be inserted without interruption, return an error for
  # the outer loop to tear down the skeleton sync and restart it
  let
    number = head.u64
    headHash = head.blockHash
    genesisHash = sk.genesisHash

  if number == 0:
    if headHash != genesisHash:
      return err("Invalid genesis setHead announcement " &
        "number=" & $number &
        ", hash=" & headHash.short &
        ", genesisHash=" & genesisHash.short
      )
    # genesis announcement
    return ok(false)


  let last = if sk.isEmpty:
               debug "Skeleton empty, comparing against genesis head=0 tail=0",
                 newHead=number
               # set the lastchain to genesis for comparison in
               # following conditions
               segment(0, 0, zeroBlockHash)
             else:
               sk.last

  if last.tail > number:
    # Not a noop / double head announce, abort with a reorg
    if force:
      debug "Skeleton setHead before tail, resetting skeleton",
        tail=last.tail, head=last.head, newHead=number
      last.head = number
      last.tail = number
      last.next = head.parentHash
    else:
      debug "Skeleton announcement before tail, will reset skeleton",
        tail=last.tail, head=last.head, newHead=number
    return ok(true)

  elif last.head >= number:
    # Check if its duplicate announcement, if not trim the head and
    # let the match run after this if block
    let maybeDupBlock = sk.getHeader(number).valueOr:
      return err(error)

    let maybeDupHash = maybeDupBlock.blockHash
    if maybeDupBlock.isSome and maybeDupHash == headHash:
      debug "Skeleton duplicate announcement",
        tail=last.tail, head=last.head, number, hash=headHash.short
      return ok(false)
    else:
      # Since its not a dup block, so there is reorg in the chain or at least
      # in the head which we will let it get addressed after this if else block
      if force:
        debug "Skeleton differing announcement",
          tail=last.tail,
          head=last.head,
          number=number,
          expected=maybeDupHash.short,
          actual=headHash.short
      else:
        debug "Skeleton stale announcement",
          tail=last.tail,
          head=last.head,
          number
      return ok(true)

  elif last.head + 1 < number:
    if force:
      sk.fastForwardHead(last, number - 1).isOkOr:
        return err(error)

      # If its still less than number then its gapped head
      if last.head + 1 < number:
        debug "Beacon chain gapped setHead",
          head=last.head, newHead=number
        return ok(true)
    else:
      debug "Beacon chain gapped announcement",
        head=last.head, newHead=number
      return ok(true)

  let maybeParent = sk.getHeader(number - 1).valueOr:
    return err(error)

  let parentHash = maybeParent.blockHash
  if maybeParent.isNone or parentHash != head.parentHash:
    if force:
      debug "Beacon chain forked",
        ancestor=maybeParent.numberStr,
        hash=maybeParent.blockHashStr,
        want=head.parentHash.short
    return ok(true)

  if force:
    last.head = number
    if sk.isEmpty:
      # If there was no subchain to being with i.e. initialized from genesis
      # and no reorg then push in subchains else the reorg handling will
      # push the new chain
      sk.push(last)
      sk.progress.linked = sk.isLinked.valueOr:
        return err(error)

    debug "Beacon chain extended new", last
  return ok(false)
