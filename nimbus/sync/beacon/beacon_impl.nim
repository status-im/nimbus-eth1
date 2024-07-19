# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[tables, options],
  chronicles,
  chronos,
  chronos/timer,
  ./worker_desc,
  ./skeleton_main,
  ./skeleton_utils,
  ./skeleton_db,
  ../../utils/utils,
  ../protocol,
  ../types

logScope:
  topics = "beacon-impl"

{.push gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func makeGetBodyJob(header: BlockHeader, setHead: bool): BeaconJob =
  BeaconJob(
    mode: bjmGetBody,
    getBodyJob: BeaconJobGetBody(
      headerHash: header.blockHash,
      sumHash: header.sumHash,
      header: header,
      setHead: setHead,
    ),
  )

func makeGetBlocksJob(number, maxResults: uint64): BeaconJob =
  BeaconJob(
    mode: bjmGetBlocks,
    getBlocksJob: BeaconJobGetBlocks(number: number, maxResults: maxResults),
  )

func makeHeaderRequest(number: uint64, maxResults: uint64): BlocksRequest =
  BlocksRequest(
    startBlock: HashOrNum(isHash: false, number: number),
    maxResults: maxResults.uint,
    skip: 0,
    reverse: true,
  )

func makeGetBodiesJob(
    headers: sink seq[BlockHeader],
    headerHash: sink seq[Hash256],
    reqBodies: sink seq[bool],
): BeaconJob =
  BeaconJob(
    mode: bjmGetBodies,
    getBodiesJob: BeaconJobGetBodies(
      headers: system.move(headers),
      headerHash: system.move(headerHash),
      reqBodies: system.move(reqBodies),
    ),
  )

proc requeue(buddy: BeaconBuddyRef, job: BeaconJob) =
  buddy.ctx.poolMode = true
  buddy.only.requeue.add job

proc jobDone(buddy: BeaconBuddyRef) =
  buddy.only.job = nil

proc mapBodiesToHeader(
    buddy: BeaconBuddyRef,
    job: BeaconJob,
    bodies: openArray[BlockBody],
    reqBodies: openArray[bool],
) {.raises: [].} =
  doAssert(
    job.mode == bjmGetBlocks or job.mode == bjmGetBodies,
    "mapBodiesToHeader doesn't allow this job: " & $job.mode,
  )
  var
    headers =
      if job.mode == bjmGetBlocks:
        system.move(job.getBlocksJob.headers)
      else:
        system.move(job.getBodiesJob.headers)
    map = Table[Hash256, int]()

  for i, x in bodies:
    let bodyHash = sumHash(x)
    map[bodyHash] = i

  for i, req in reqBodies:
    if not req:
      if job.mode == bjmGetBlocks:
        job.getBlocksJob.headers.add headers[i]
        job.getBlocksJob.bodies.add BlockBody()
      else:
        job.getBodiesJob.headers.add headers[i]
        job.getBodiesJob.bodies.add BlockBody()
      continue

    let bodyHash = sumHash(headers[i])
    let z = map.getOrDefault(bodyHash, MissingBody)
    if z == MissingBody:
      # missing or invalid body, request again
      buddy.requeue makeGetBodyJob(headers[i], setHead = false)
      continue

    if job.mode == bjmGetBlocks:
      job.getBlocksJob.headers.add headers[i]
      job.getBlocksJob.bodies.add bodies[z]
    else:
      job.getBodiesJob.headers.add headers[i]
      job.getBodiesJob.bodies.add bodies[z]

proc putBlocks(
    ctx: BeaconCtxRef,
    skel: SkeletonRef,
    headers: openArray[BlockHeader],
    bodies: openArray[BlockBody],
) =
  for i, body in bodies:
    let r = skel.putBody(headers[i], body)
    doAssert(r.isOk)

  let res = skel.putBlocks(headers)
  if res.isErr:
    error "putBlocks->putBlocks", msg = res.error
    return

  let z = res.get
  if FillCanonical in z.status:
    let rr = skel.fillCanonicalChain()
    if rr.isErr:
      error "putBlocks->fillCanonicalChain", msg = rr.error
      return

proc setupTally*(ctx: BeaconCtxRef) =
  let
    skel = ctx.pool.skeleton
    last = skel.last

  discard ctx.pool.mask.merge(1'u64, last.head)
  for x in skel.subchains:
    discard ctx.pool.mask.reduce(x.tail, x.head)
    discard ctx.pool.pulled.merge(x.tail, x.head)

proc mergeTally*(ctx: BeaconCtxRef, least: uint64, last: uint64) =
  discard ctx.pool.mask.merge(least, last)

proc reduceTally*(ctx: BeaconCtxRef, least: uint64, last: uint64) =
  discard ctx.pool.mask.reduce(least, last)
  discard ctx.pool.pulled.merge(least, last)

proc downloaded*(ctx: BeaconCtxRef, head: uint64): bool =
  ctx.pool.pulled.covered(head, head) > 0'u64

proc headTally(ctx: BeaconCtxRef, head: uint64) =
  discard ctx.pool.pulled.merge(head, head)
  let rc = ctx.pool.mask.le()
  if rc.isSome:
    let maxPt = rc.get().maxPt
    if head > maxPt:
      # new head
      discard ctx.pool.mask.merge(maxPt + 1, head - 1)
  else:
    # initialize
    discard ctx.pool.mask.merge(1'u64, head)
  discard ctx.pool.mask.reduce(head, head)

proc popFirst(x: var TargetQueue): BlockHeader =
  # assume we already check len > 0
  x.shift().get().data

proc addLast(x: var TargetQueue, h: BlockHeader) =
  discard x.prepend(h.blockHash, h)

# ------------------------------------------------------------------------------
# Synchronizer will produce jobs for workers
# ------------------------------------------------------------------------------

proc resumeSync*(ctx: BeaconCtxRef): Future[bool] {.async.} =
  let skel = ctx.pool.skeleton
  if skel.len == 0:
    return true

  let last = skel.last
  let res = skel.getHeader(last.head)
  if res.isErr:
    error "resumeSync->getHeader", msg = res.error
    return false

  let maybeHeader = res.get
  if maybeHeader.isNone:
    return true

  let header = maybeHeader.get
  let r = skel.initSync(header)
  if r.isErr:
    error "resumeSync->initSync", msg = r.error
    return false

  let z = r.get
  if FillCanonical in z.status:
    let rr = skel.fillCanonicalChain()
    if rr.isErr:
      error "resumeSync->fillCanonicalChain", msg = rr.error
      return false

  # collect gaps of skeleton, excluding genesis
  ctx.setupTally()

  return true

proc appendSyncTarget*(ctx: BeaconCtxRef, h: BlockHeader): Future[void] {.async.} =
  while bmShiftTarget in ctx.pool.mode:
    await sleepAsync timer.milliseconds(10)

  let number = h.u64
  ctx.pool.mode.incl bmAppendTarget

  if not ctx.downloaded(number):
    ctx.headTally(number)
    ctx.pool.target.addLast(h)

  ctx.pool.mode.excl bmAppendTarget
  ctx.daemon = true

proc shiftSyncTarget*(ctx: BeaconCtxRef): Future[BlockHeader] {.async.} =
  doAssert(ctx.pool.target.len > 0)
  while bmAppendTarget in ctx.pool.mode:
    await sleepAsync timer.milliseconds(10)

  ctx.pool.mode.incl bmShiftTarget
  let h = ctx.pool.target.popFirst()
  ctx.pool.mode.excl bmShiftTarget
  return h

proc setSyncTarget*(ctx: BeaconCtxRef): Future[void] {.async.} =
  let header = await ctx.shiftSyncTarget()
  let res = ctx.pool.skeleton.setHead(header, force = true)
  if res.isOk:
    let job = makeGetBodyJob(header, setHead = true)
    ctx.pool.jobs.addLast(job)
  else:
    error "setSyncTarget.setHead", msg = res.error

proc fillBlocksGaps*(ctx: BeaconCtxRef, least: uint64, last: uint64) =
  if last - least < MaxGetBlocks:
    ctx.reduceTally(last - least, last)
    let job = makeGetBlocksJob(last, last - least + 1)
    ctx.pool.jobs.addLast(job)
    return

  var max = last

  while true:
    ctx.reduceTally(max - MaxGetBlocks, max)
    let job = makeGetBlocksJob(max, MaxGetBlocks)
    ctx.pool.jobs.addLast(job)
    if ctx.pool.jobs.len > MaxJobsQueue:
      return
    max = max - MaxGetBlocks
    if max <= MaxGetBlocks:
      break

  if max > 1:
    ctx.reduceTally(1, max)
    let job = makeGetBlocksJob(max, max)
    ctx.pool.jobs.addLast(job)

# ------------------------------------------------------------------------------
# Worker will consume available jobs
# ------------------------------------------------------------------------------

proc executeGetBodyJob*(buddy: BeaconBuddyRef, job: BeaconJob): Future[void] {.async.} =
  let
    ctx = buddy.ctx
    peer = buddy.peer
    skel = ctx.pool.skeleton

  let b = await peer.getBlockBodies([job.getBodyJob.headerHash])
  if b.isNone:
    debug "executeGetBodyJob->getBodies none",
      hash = job.getBodyJob.headerHash.short, number = job.getBodyJob.header.number
    # retry with other peer
    buddy.requeue job
    return

  let bodies = b.get
  if bodies.blocks.len == 0:
    debug "executeGetBodyJob->getBodies isZero",
      hash = job.getBodyJob.headerHash.short, number = job.getBodyJob.header.number
    # retry with other peer
    buddy.requeue job
    return

  job.getBodyJob.body = bodies.blocks[0]
  let bodySumHash = sumHash(job.getBodyJob.body)
  if bodySumHash != job.getBodyJob.sumHash:
    # retry with other peer
    debug "executeGetBodyJob->sumHash",
      expect = job.getBodyJob.sumHash.short, get = bodySumHash.short
    buddy.requeue job
    return

  var status: set[SkeletonStatus]

  if job.getBodyJob.setHead:
    let res = skel.setHead(job.getBodyJob.header)
    if res.isErr:
      error "executeGetBodyJob->setHead", msg = res.error
      # something wrong
      return
    status = res.get().status
  else:
    let res = skel.putBlocks([job.getBodyJob.header])
    if res.isErr:
      error "executeGetBodyJob->putBlocks", msg = res.error
      return
    status = res.get().status

  let r = skel.putBody(job.getBodyJob.header, job.getBodyJob.body)
  doAssert(r.isOk)
  if FillCanonical in status:
    let rr = skel.fillCanonicalChain()
    if rr.isErr:
      error "executeGetBodyJob->fillCanonicalChain", msg = rr.error
      return

  buddy.jobDone()

proc executeGetBlocksJob*(
    buddy: BeaconBuddyRef, job: BeaconJob
): Future[void] {.async.} =
  let
    ctx = buddy.ctx
    peer = buddy.peer
    skel = ctx.pool.skeleton
    request = makeHeaderRequest(job.getBlocksJob.number, job.getBlocksJob.maxResults)

  let res = await peer.getBlockHeaders(request)
  if res.isNone:
    # retry with other peer
    error "executeGetBlocksJob->getBlockHeaders none"
    buddy.requeue job
    return

  job.getBlocksJob.headers = res.get().headers
  let numHeaders = job.getBlocksJob.headers.len

  var
    headerHashes = newSeqOfCap[Hash256](numHeaders)
    reqBodies = newSeqOfCap[bool](numHeaders)
    numRequest = 0

  for i, x in job.getBlocksJob.headers:
    if not x.hasBody:
      reqBodies.add false
      continue
    reqBodies.add true
    headerHashes.add x.blockHash
    inc numRequest

  if numRequest == 0:
    # all bodies are empty
    for _ in 0 ..< numHeaders:
      job.getBlocksJob.bodies.add BlockBody()
  else:
    let b = await peer.getBlockBodies(headerHashes)
    if b.isNone:
      debug "executeGetBlocksJob->getBodies none"
      # retry with other peer
      buddy.requeue makeGetBodiesJob(job.getBlocksJob.headers, headerHashes, reqBodies)
      return
    buddy.mapBodiesToHeader(job, b.get().blocks, reqBodies)

  ctx.putBlocks(skel, job.getBlocksJob.headers, job.getBlocksJob.bodies)
  buddy.jobDone()

proc executeGetBodiesJob*(
    buddy: BeaconBuddyRef, job: BeaconJob
): Future[void] {.async.} =
  let
    ctx = buddy.ctx
    peer = buddy.peer
    skel = ctx.pool.skeleton

  let b = await peer.getBlockBodies(job.getBodiesJob.headerHash)
  if b.isNone:
    debug "executeGetBodiesJob->getBodies none"
    # retry with other peer
    buddy.requeue job
    return
  buddy.mapBodiesToHeader(job, b.get().blocks, job.getBodiesJob.reqBodies)
  ctx.putBlocks(skel, job.getBodiesJob.headers, job.getBodiesJob.bodies)
  buddy.jobDone()

proc executeJob*(buddy: BeaconBuddyRef, job: BeaconJob): Future[void] {.async.} =
  try:
    case job.mode
    of bjmGetBody:
      await executeGetBodyJob(buddy, job)
    of bjmGetBlocks:
      await executeGetBlocksJob(buddy, job)
    of bjmGetBodies:
      await executeGetBodiesJob(buddy, job)
  except TransportError as ex:
    error "executeJob->TransportError", msg = ex.msg
  except CatchableError as ex:
    error "executeJob->OtherError", msg = ex.msg
    # retry with other peer
    buddy.requeue job
