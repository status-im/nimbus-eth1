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
  ./skeleton_algo

export
  skeleton_desc,
  skeleton_algo.isLinked,
  skeleton_algo.putBlocks,
  skeleton_algo.fillCanonicalChain

{.push gcsafe, raises: [].}

logScope:
  topics = "skeleton"

# ------------------------------------------------------------------------------
# Constructors
# ------------------------------------------------------------------------------

proc new*(_: type SkeletonRef, chain: ForkedChainRef): SkeletonRef =
  SkeletonRef(
    progress: Progress(),
    pulled  : 0,
    filling : false,
    chain   : chain,
    db      : chain.db,
    started : getTime(),
    logged  : getTime(),
    conf    : SkeletonConfig(
      fillCanonicalBackStep: 100,
      subchainMergeMinimum : 1000,
    ),
  )

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc open*(sk: SkeletonRef): Result[void, string]  =
  if sk.chain.com.ttd.isNone and sk.chain.com.ttdPassed.not:
    return err("Cannot create skeleton as ttd and ttdPassed not set")
  sk.readProgress().isOkOr:
    return err(error)
  sk.started = getTime()
  ok()

proc setHead*(sk: SkeletonRef, head: BlockHeader,
              force = true, init = false,
              reorgthrow = false): Result[StatusAndReorg, string] =
  ## Announce and integrate a new head.
  ## @params head  - The block being attempted as a new head
  ## @params force - Flag to indicate if this is just a check of
  ##                   worthiness or a actually new head
  ## @params init  - Flag this is the first time since the beacon
  ##                   sync start to perform additional tasks
  ## @params reorgthrow - Flag to indicate if we would actually like
  ##                   to throw if there is a reorg
  ##                   instead of just returning the boolean
  ##
  ## @returns True if the head (will) cause a reorg in the
  ##              canonical skeleton subchain

  let
    number = head.u64

  debug "New skeleton head announced",
    number,
    hash=head.blockHashStr,
    force

  let reorg = sk.processNewHead(head, force).valueOr:
    return err(error)

  if force and reorg:
    # It could just be a reorg at this head with previous tail preserved
    let
      subchain = if sk.isEmpty: Segment(nil)
                 else: sk.last
      maybeParent = sk.getHeader(number - 1).valueOr:
        return err(error)
      parentHash = maybeParent.blockHash

    if subchain.isNil or maybeParent.isNone or parentHash != head.parentHash:
      let sub = segment(number, number, head.parentHash)
      sk.push(sub)
      debug "Created new subchain", sub
    else:
      # Only the head differed, tail is preserved
      subchain.head = number
    # Reset the filling of canonical head from tail on reorg
    sk.progress.canonicalHeadReset = true

  # Put this block irrespective of the force
  sk.putHeader(head)

  if init:
    sk.trySubChainsMerge().isOkOr:
      return err(error)

  if (force and reorg) or init:
    sk.progress.linked = sk.isLinked.valueOr:
      return err(error)

  if force or init:
    sk.writeProgress()

  var res = StatusAndReorg(reorg: reorg)
  if force and sk.progress.linked:
    res.status.incl FillCanonical

  # Earlier we were throwing on reorg, essentially for the purposes for
  # killing the reverse fetcher
  # but it can be handled properly in the calling fn without erroring
  if reorg and reorgthrow:
    if force:
      res.status.incl SyncReorged
    else:
      res.status.incl ReorgDenied

  ok(res)

proc initSync*(sk: SkeletonRef, head: BlockHeader,
               reorgthrow = false): Result[StatusAndReorg, string] =
  ## Setup the skeleton to init sync with head
  ## @params head - The block with which we want to init the skeleton head
  ## @params reorgthrow - If we would like the function to throw instead of
  ##         silently return if there is reorg of the skeleton head
  ##
  ## @returns True if the skeleton was reorged trying to init else false

  sk.setHead(head, true, true, reorgthrow)

func bodyRange*(sk: SkeletonRef): Result[BodyRange, string] =
  ## Get range of bodies need to be downloaded by synchronizer
  var canonicalHead = sk.blockHeight
  let subchain = sk.last

  if sk.progress.canonicalHeadReset:
    if subchain.tail > canonicalHead + 1:
      return err("Canonical head should already be on or " &
        "ahead subchain tail canonicalHead=" &
        $canonicalHead & ", tail=" & $subchain.tail)
    let newHead = if subchain.tail > 0: subchain.tail - 1
                  else: 0
    canonicalHead = newHead

  ok(BodyRange(
    min: canonicalHead,
    max: subchain.head,
  ))

# ------------------------------------------------------------------------------
# Getters and setters
# ------------------------------------------------------------------------------

func fillCanonicalBackStep*(sk: SkeletonRef): uint64 =
  sk.conf.fillCanonicalBackStep

func subchainMergeMinimum*(sk: SkeletonRef): uint64 =
  sk.conf.subchainMergeMinimum

proc `fillCanonicalBackStep=`*(sk: SkeletonRef, val: uint64) =
  sk.conf.fillCanonicalBackStep = val

proc `subchainMergeMinimum=`*(sk: SkeletonRef, val: uint64) =
  sk.conf.subchainMergeMinimum = val
