# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/deques,
  stew/interval_set,
  eth/p2p,
  chronos,
  ../sync_desc,
  ./skeleton_desc

export
  deques,
  interval_set

type
  BeaconMode* = enum
    bmNone            ## Do nothing
    bmResumeSync      ## Resume sync if the client stopped
    bmAppendTarget    ## Put new sync target into queue
    bmShiftTarget     ## Get sync target from queue

  BeaconJobGetBody* = object
    headerHash*: Hash256      ## request body using this hash
    sumHash*   : Hash256      ## compare downloaded body to this hash
    header*    : BlockHeader  ## downloaded header
    body*      : BlockBody    ## downloaded body
    setHead*   : bool         ## true: setHead, false: putBlocks

  BeaconJobGetBlocks* = object
    number*    : uint64           ## starting number of blocks
    maxResults*: uint64           ## number of blocks we want to download
    headers*   : seq[BlockHeader] ## downloaded headers
    bodies*    : seq[BlockBody]   ## downloaded bodies

  BeaconJobGetBodies* = object
    headers*   : seq[BlockHeader] ## downloaded headers
    bodies*    : seq[BlockBody]   ## downloaded bodies
    headerHash*: seq[Hash256]     ## request to download bodies using this hashes
    reqBodies* : seq[bool]        ## skip downloading body if header has no body

  BeaconJobMode* = enum
    bjmGetBody      ## when setSyncTarget done, download the body
    bjmGetBlocks    ## download blocks to fill skeleton gaps
    bjmGetBodies    ## if bjmGetBlocks failed to download bodies, give it to other peer

  BeaconJob* = ref object
    case mode*: BeaconJobMode
    of bjmGetBody:
      getBodyJob*: BeaconJobGetBody
    of bjmGetBlocks:
      getBlocksJob*: BeaconJobGetBlocks
    of bjmGetBodies:
      getBodiesJob*: BeaconJobGetBodies

  BeaconBuddyData* = object
    ## Local descriptor data extension
    job*    : BeaconJob
    requeue*: seq[BeaconJob]

  BeaconCtxData* = object
    ## Globally shared data extension
    rng*     : ref HmacDrbgContext            ## Random generator, pre-initialised
    id*      : int                            ## Instance id, for debugging purpose
    skeleton*: SkeletonRef                    ## Core algorithm, tracking both canonical and side chain
    mode*    : set[BeaconMode]                ## Do one thing at a time
    target*  : Deque[BlockHeader]             ## Sync target list
    jobs*    : Deque[BeaconJob]               ## Each buddy can get a job from here
    mask*    : IntervalSetRef[uint64, uint64] ## Skeleton gaps need to be downloaded
    pulled*  : IntervalSetRef[uint64, uint64] ## Downloaded skeleton blocks
    tallyOk* : bool

  BeaconBuddyRef* = BuddyRef[BeaconCtxData,BeaconBuddyData]
    ## Extended worker peer descriptor

  BeaconCtxRef* = CtxRef[BeaconCtxData]
    ## Extended global descriptor

const
  MaxGetBlocks* = 64
  MaxJobsQueue* = 32
  MissingBody* = -1

# End
