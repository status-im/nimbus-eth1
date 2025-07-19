# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay runner

{.push raises:[].}

import
  std/[net, tables],
  pkg/[chronos, chronicles, stew/interval_set],
  ../../../../../networking/p2p,
  ../../../../wire_protocol,
   ../../[replay_desc, replay_helpers]

export
  replay_helpers

logScope:
  topics = "replay runner"

# ------------------------------------------------------------------------------
# Private helper(s)
# ------------------------------------------------------------------------------

proc waitForConditionImpl(
    run: ReplayRunnerRef;
    cond: proc(): bool {.gcsafe, raises: [].};
    info: static[string];
      ): Future[Result[void,ReplayWaitError]]
      {.async: (raises: []).} =
  ## Wait until the condition `cond()` becomes`true`. If a `stopRunner` flag
  ## is becomes `true`, this wait function function returns `err(..)`, and
  ## `ok()` otherwise.
  let n = run.instrNumber
  var count = 0

  while true:
    if run.stopRunner:
      trace info & "runner stopped", n, count
      return err((ENoException,"",info & "runner stopped"))

    if cond():
      return ok()

    count.inc
    #trace info & "polling continue", n, count

    try: await sleepAsync replayWaitForCompletion
    except CancelledError as e:
      error info & "cancelled while waiting -- STOP", n
      run.stopRunner = false
      return err((ECancelledError,$e.name,e.msg))
  # notreached


proc newPeerImpl(
    run: ReplayRunnerRef;
    instr: TraceSchedStart|TraceSchedStop|TraceSchedPool|TraceSchedPeerBegin;
    info: static[string];
      ): ReplayBuddyRef =
  ## Register a new peer.
  ##
  run.peers.withValue(instr.peerID, val):
    warn info & "peer exists already", serial=instr.serial, peer=($val.peer),
      nStaged=val.stage.len
    val.isNew = false
    return val[]

  var buddy = ReplayBuddyRef(
    isNew:            true,
    run:              run,
    ctx:              run.ctx,
    only: BeaconBuddyData(
      nRespErrors:   (instr.nHdrErrors,
                      instr.nBlkErrors)),
    peerID:           instr.peerID,
    peer: Peer(
      dispatcher:     run.ethState.capa,
      protocolStates: run.ethState.prots,
      remote: Node(
        node: ENode(
          address: enode.Address(
            ip:       instr.peerIP,
            tcpPort:  instr.peerPort,
            udpPort:  instr.peerPort)))))

  run.peers[instr.peerID] = buddy
  return (move buddy)

# ------------------------------------------------------------------------------
# Private functions, environment checkers
# ------------------------------------------------------------------------------

proc baseStatesDifferImpl(
    desc: ReplayRunnerRef|ReplayDaemonRef|ReplayBuddyRef;
    instr: TraceRecBase;
    info: static[string];
      ): bool =
  when desc is ReplayRunnerRef:
    let (run, peer) = (desc, "n/a")
  when desc is ReplayDaemonRef:
    let (run, peer) = (desc.run, "n/a")
  when desc is ReplayBuddyRef:
    let (run, peer) = (desc.run, desc.peer)

  let
    ctx = run.ctx
    serial = instr.serial
  var
    statesDiffer = false

  if serial != run.instrNumber:
    statesDiffer = true
    info info & "serial numbers differ", peer,
      serial, expected=run.instrNumber

  if ctx.pool.lastState != instr.syncState:
    statesDiffer = true
    info info & "sync states differ", serial, peer,
      state=ctx.pool.lastState, expected=instr.syncState

  if ctx.hdrCache.state != instr.chainMode:
    statesDiffer = true
    info info & "header chain modes differ", serial, peer,
      chainMode=ctx.hdrCache.state, expected=instr.chainMode

  if ctx.pool.nBuddies != instr.nPeers:
    statesDiffer = true
    info info & "number of active peers differs", serial, peer,
      nBuddies=ctx.pool.nBuddies, expected=instr.nPeers

  if ctx.poolMode != instr.poolMode:
    statesDiffer = true
    info info & "pool modes/reorgs differ", serial, peer,
      poolMode=ctx.poolMode, expected=instr.poolMode

  statesDiffer


proc unprocListsDifferImpl(
    desc: ReplayRunnerRef|ReplayDaemonRef|ReplayBuddyRef;
    instr: TraceRecBase;
    info: static[string];
      ): bool =
  when desc is ReplayRunnerRef:
    let (run, peer) = (desc, "n/a")
  when desc is ReplayDaemonRef:
    let (run, peer) = (desc.run, "n/a")
  when desc is ReplayBuddyRef:
    let (run, peer) = (desc.run, desc.peer)

  let
    ctx = run.ctx
    serial = instr.serial
  var
    statesDiffer = false

  # Unprocessed block numbers for header
  if instr.hdrUnprChunks != ctx.hdr.unprocessed.chunks().uint:
    statesDiffer = true
    info info & "unproc headers lists differ", serial, peer,
      listChunks=ctx.hdr.unprocessed.chunks(), expected=instr.hdrUnprChunks
  elif 0 < instr.hdrUnprChunks:
    if instr.hdrUnprLen != ctx.hdr.unprocessed.total():
      statesDiffer = true
      info info & "unproc headers lists differ", serial, peer,
        listLen=ctx.hdr.unprocessed.total(), expected=instr.hdrUnprLen
    let iv = ctx.hdr.unprocessed.le().expect "valid iv"
    if instr.hdrUnprLastLen != iv.len:
      statesDiffer = true
      info info & "unproc headers lists differ", serial, peer,
        lastIvLen=iv.len, expected=instr.hdrUnprLastLen
    if instr.hdrUnprLast != iv.maxPt:
      statesDiffer = true
      info info & "unproc headers lists differ", serial, peer,
        lastIvMax=iv.maxPt, expected=instr.hdrUnprLast

  # Unprocessed block numbers for blocks
  if instr.blkUnprChunks != ctx.blk.unprocessed.chunks().uint:
    statesDiffer = true
    info info & "unproc blocks lists differ", serial, peer,
      listChunks=ctx.blk.unprocessed.chunks(), expected=instr.blkUnprChunks
  elif 0 < instr.blkUnprChunks:
    if instr.blkUnprLen != ctx.blk.unprocessed.total():
      statesDiffer = true
      info info & "unproc blocks lists differ", serial, peer,
        listLen=ctx.blk.unprocessed.total(), expected=instr.blkUnprLen
    let iv = ctx.blk.unprocessed.ge().expect "valid iv"
    if instr.blkUnprLeastLen != iv.len:
      statesDiffer = true
      info info & "unproc blocks lists differ", serial, peer,
        lastIvLen=iv.len, expected=instr.blkUnprLeastLen
    if instr.blkUnprLeast != iv.minPt:
      statesDiffer = true
      info info & "unproc blocks lists differ", serial, peer,
        lastIvMax=iv.maxPt, expected=instr.blkUnprLeast

  statesDiffer


proc peerStatesDifferImpl(
    desc: ReplayBuddyRef;
    instr: TraceRecBase;
    info: static[string];
      ): bool =
  let
    peer = desc.peer
    serial = instr.serial
  var
    statesDiffer = false

  if desc.ctrl.state != instr.peerCtrl:
    statesDiffer = true
    info info & "peer ctrl states differ", serial, peer,
      ctrl=desc.ctrl.state, expected=instr.peerCtrl

  if instr.nHdrErrors != desc.only.nRespErrors.hdr:
    statesDiffer = true
    info info & "peer header errors differ", serial, peer,
      nHdrErrors=desc.only.nRespErrors.hdr, expected=instr.nHdrErrors

  if instr.nBlkErrors != desc.only.nRespErrors.blk:
    statesDiffer = true
    info info & "peer body errors differ", serial, peer,
      nBlkErrors=desc.only.nRespErrors.blk, expected=instr.nBlkErrors

  statesDiffer


proc baseOrPeerStatesDifferImpl(
    desc: ReplayRunnerRef|ReplayDaemonRef|ReplayBuddyRef;
    instr: TraceRecBase;
    info: static[string];
      ): bool =
  ## Check syncer states against captured state of the `instr` argument without
  ## checking the `unproc` lists.
  var statesDiffer = false

  if desc.baseStatesDifferImpl(instr, info):
    statesDiffer = true

  when desc is ReplayBuddyRef:
    if desc.peerStatesDifferImpl(instr, info):
      statesDiffer = true

  statesDiffer

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc toStr*(w: BlockHashOrNumber): string =
  if w.isHash: w.hash.short else: w.number.bnStr

# -----------------

proc stopError*(run: ReplayRunnerRef; info: static[string]) =
  error info & " -- STOP", n=run.instrNumber
  run.stopRunner = false

proc stopOk*(run: ReplayRunnerRef; info: static[string]) =
  info info & " -- STOP", n=run.instrNumber
  run.stopRunner = false

# -----------------

proc checkSyncerState*(
    desc: ReplayRunnerRef|ReplayDaemonRef|ReplayBuddyRef;
    instr: TraceRecBase;
    info: static[string];
      ): bool
      {.discardable.} =
  ## Check syncer states against all captured state variables of the
  ## `instr` argument.
  var statesDiffer = false

  if desc.baseStatesDifferImpl(instr, info):
    statesDiffer = true

  if desc.unprocListsDifferImpl(instr, info):
    statesDiffer = true

  when desc is ReplayBuddyRef:
    if desc.peerStatesDifferImpl(instr, info):
      statesDiffer = true

  statesDiffer

# ------------------------------------------------------------------------------
# Public functions, peer/daemon descriptor management
# ------------------------------------------------------------------------------

proc getPeer*(
    run: ReplayRunnerRef;
    instr: TraceRecBase;
    info: static[string];
      ): Opt[ReplayBuddyRef] =
  ## Get peer from peers table (if any)
  let serial = instr.serial
  run.peers.withValue(instr.peerID, buddy):
    let peer = buddy.peer
    if buddy.stage.len == 0:
      warn info & "ctx stack is empty", serial, peer, peerID=buddy.peerID.short
      return err()
    elif buddy.stage[0].recType != TrtSchedPeerBegin:
      warn info & "wrong ctx frame type", serial, peer,
        peerID=buddy.peerID.short,
        frameType=buddy.stage[0].recType, expected=TrtSchedPeerBegin,
        stackSize=buddy.stage.len
      return err()
    else:
      return ok(buddy[])

  trace info & "missing peer ignored", serial, peerID=instr.peerID.short
  err()


proc newPeer*(
    run: ReplayRunnerRef;
    instr: TraceSchedStart;
    info: static[string];
      ): ReplayBuddyRef =
  ## Register a new peer.
  ##
  run.newPeerImpl(instr, info)


proc getOrNewPeerFrame*(
    run: ReplayRunnerRef;
    instr: TraceSchedStop|TraceSchedPool|TraceSchedPeerBegin;
    info: static[string];
      ): ReplayBuddyRef =
  ## Get an existing one or register a new peer and set up `stage[0]`.
  ##
  var buddy: ReplayBuddyRef
  run.peers.withValue(instr.peerID, val):
    val.isNew = false
    buddy = val[]
    if 0 < buddy.stage.len:
      error info & "frame unexpected", serial=instr.serial,
        frameID=ReplayFrameRef(buddy.stage[0]).frameID,
        frameType=buddy.stage[0].recType,
        nStaged=buddy.stage.len
    doAssert buddy.stage.len == 0
  do:
    buddy = run.newPeerImpl(instr, info)

  when instr is TraceSchedPeerBegin:
    const recType = TrtSchedPeerBegin
  when instr is TraceSchedStop:
    const recType = TrtSchedStop
  when instr is TraceSchedPool:
    const recType = TrtSchedPool

  # Push/stage base frame
  buddy.stage.add ReplayFrameRef(
    recType: recType,
    frameID: instr.frameID)
  move(buddy)


proc delPeer*(
    buddy: ReplayBuddyRef;
    info: static[string];
      ) =
  ## Delete peer ID from registry and return the environment for the
  ## deleted peer ID.
  ##
  if buddy.run.peers.hasKey(buddy.peerID):
    buddy.run.peers.del buddy.peerID
  else:
    trace info & "stale peer ignored", n=buddy.run.instrNumber,
      peer=($buddy.peer), peerID=buddy.peerID.short

# -----------------

proc getDaemon*(
    run: ReplayRunnerRef;
    info: static[string];
      ): Opt[ReplayDaemonRef] =
  ## Similar to `getPeer()` for daemon
  let n = run.instrNumber
  if run.daemon.isNil:
    trace info & "missing daemon ignored", n
    err()
  elif run.daemon.stage.len == 0:
    warn info & "ctx stack is empty", n
    err()
  elif run.daemon.stage[0].recType != TrtSchedDaemonBegin:
    warn info & "wrong frame type on stack", n,
      frameType=run.daemon.stage[0].recType, expected=TrtSchedDaemonBegin,
      nStaged=run.daemon.stage.len
    err()
  else:
    ok(run.daemon)


proc newDaemonFrame*(
    run: ReplayRunnerRef;
    instr: TraceSchedDaemonBegin;
    info: static[string];
      ): Opt[ReplayDaemonRef] =
  ## Similar to `getOrNewPeerFrame()` for daemon.
  if run.daemon.isNil:
    var daemon = ReplayDaemonRef(run: run)
    daemon.stage.add ReplayDaemonFrameRef(
      recType: TrtSchedDaemonBegin,
      frameID: instr.frameID)
    run.daemon = daemon
    return ok(move daemon)

  warn info & "daemon already registered", n=run.instrNumber,
    nStaged=run.daemon.stage.len
  err()


proc delDaemon*(
    daemon: ReplayDaemonRef;
    info: static[string];
      ) =
  ## Similar to `delPeer()` for daemon
  if daemon.run.daemon.isNil:
    trace info & "stale daemon ignored", n=daemon.run.instrNumber
  else:
    daemon.run.daemon = ReplayDaemonRef(nil)

# ------------------------------------------------------------------------------
# Public functions, process/handler synchronisation
# ------------------------------------------------------------------------------

proc waitForSyncedEnv*(
    desc: ReplayDaemonRef|ReplayBuddyRef;
    instr: TraceSchedDaemonBegin |
           TraceSchedDaemonEnd   |
           TraceSchedPeerBegin   |
           TraceSchedPeerEnd     |
           TraceBeginHeaders     |
           TraceGetBlockHeaders  |
           TraceBeginBlocks      |
           TraceGetBlockBodies   |
           TraceImportBlock      ;
    info: static[string];
      ): Future[Result[void,ReplayWaitError]]
      {.async: (raises: []).} =
  ## ..
  ##
  let
    ctx = desc.run.ctx
    run = desc.run
    serial = instr.serial

  when desc is ReplayBuddyRef:                  # for logging/debugging only
    let peer {.used.} = desc.peer               # for logging/debugging only
  else:                                         # for logging/debugging only
    let peer {.used.} = "n/a"                   # for logging/debugging only
  var count = 0                                 # for logging/debugging only
  #trace info & "process to be synced", n=run.instrNumber, serial, peer

  (await desc.run.waitForConditionImpl(
    cond = proc(): bool =
      count.inc                                 # for logging/debugging only
      block noiseCtrl:                          # for logging/debugging only
        if count < 100:                         # for logging/debugging only
          break noiseCtrl                       # for logging/debugging only
        elif count < 1000:                      # for logging/debugging only
          if (count mod 111) != 0:              # for logging/debugging only
            break noiseCtrl                     # for logging/debugging only
        else:                                   # for logging/debugging only
          if (count mod 1111) != 0:             # for logging/debugging only
            break noiseCtrl                     # for logging/debugging only
          trace info & "polling for sync", n=run.instrNumber, serial, peer, count
          desc.checkSyncerState(instr, info)

      if serial != run.instrNumber:
        return false

      if instr.hdrUnprChunks != ctx.hdr.unprocessed.chunks().uint:
        return false
      if 0 < instr.hdrUnprChunks:
        if instr.hdrUnprLen != ctx.hdr.unprocessed.total():
          return false
        let iv = ctx.hdr.unprocessed.le().expect "valid iv"
        if instr.hdrUnprLast != iv.maxPt or
           instr.hdrUnprLastLen != iv.len:
          return false

      if instr.blkUnprChunks != ctx.blk.unprocessed.chunks().uint:
        return false
      if 0 < instr.blkUnprChunks:
        if instr.blkUnprLen != ctx.blk.unprocessed.total():
          return false
        let iv = ctx.blk.unprocessed.ge().expect "valid iv"
        if instr.blkUnprLeast != iv.minPt or
           instr.blkUnprLeastLen != iv.len:
          return false

      return true,

    info)).isOkOr:
      trace info & "process sync error", n=run.instrNumber, serial, peer,
        name=error.name, msg=error.msg
      return err(error)

  when desc is ReplayBuddyRef:
    # At this point, the scheduler (see `sync_sched.nim`)  might have
    # disconnected the peer already as is captured in the instruction
    # environment. This does not apply to `zombie` settings which will be
    # done by the application.
    if instr.peerCtrl == Stopped and not desc.ctrl.stopped:
      desc.ctrl.stopped = true

  desc.checkSyncerState(instr, info)

  #trace info & "process synced", serial, peer
  return ok()

# ------------------

proc processFinished*(
    desc: ReplayDaemonRef|ReplayBuddyRef;
    instr: TraceSchedDaemonBegin|TraceSchedPeerBegin;
    info: static[string];
      ) =
  ## Register that the process has finished
  ##
  when desc is ReplayBuddyRef:
    const recType = TrtSchedPeerBegin
  else:
    const recType = TrtSchedDaemonBegin

  # Verify that sub-processes did not change the environment
  doAssert desc.stage.len == 1
  doAssert desc.stage[0].recType == recType
  doAssert ReplayFrameRef(desc.stage[0]).done == false
  doAssert ReplayFrameRef(desc.stage[0]).frameID == instr.frameID

  # Mark the pocess `done`
  ReplayFrameRef(desc.stage[0]).done = true

  when desc is ReplayBuddyRef:                  # for logging/debugging only
    let peer {.used.} = desc.peer               # for logging/debugging only
  else:                                         # for logging/debugging only
    let peer {.used.} = "n/a"                   # for logging/debugging only
  trace info & "process terminated", peer, recType


proc waitForProcessFinished*(
    desc: ReplayDaemonRef|ReplayBuddyRef;
    instr: TraceSchedDaemonEnd|TraceSchedPeerEnd;
    info: static[string];
      ): Future[Result[void,ReplayWaitError]]
      {.async: (raises: []).} =
  ## Wait until the `done` flag is set true on the base frame `stage[0]`.
  ##
  when instr is TraceSchedPeerEnd:
    const recType = TrtSchedPeerBegin
  when instr is TraceSchedDaemonEnd:
    const recType = TrtSchedDaemonBegin

  when desc is ReplayBuddyRef:                  # for logging/debugging only
    let peer {.used.} = desc.peer               # for logging/debugging only
  else:                                         # for logging/debugging only
    let peer {.used.} = "n/a"                   # for logging/debugging only
  let serial {.used.} = instr.serial            # for logging/debugging only

  doAssert 0 < desc.stage.len
  doAssert desc.stage[0].recType == recType
  doAssert ReplayFrameRef(desc.stage[0]).frameID == instr.frameID

  (await desc.run.waitForConditionImpl(
    cond = proc(): bool =
      return ReplayFrameRef(desc.stage[0]).done,
    info)).isOkOr:
      return err(error)
  trace info & "process ackn", serial, peer, recType

  # Pop frame data from stack
  desc.stage.setLen(0)

  # Synchronise against captured environment
  (await desc.waitForSyncedEnv(instr, info)).isOkOr:
    return err(error)

  trace info & "process finished", serial, peer, recType
  return ok()

# ------------------

proc provideSessionData*(
    desc: ReplayDaemonRef|ReplayBuddyRef;
    instr: TraceBeginHeaders    |
           TraceGetBlockHeaders |
           TraceBeginBlocks     |
           TraceGetBlockBodies  |
           TraceImportBlock     ;
    info: static[string];
      ): Future[Result[void,ReplayWaitError]]
      {.async: (raises: []).} =
  ## Stage session data on `desc.stage[0]`. Then wait for the background
  ## process to consume the session datea. And then clean up when done.
  ##
  when instr is TraceBeginHeaders:
    type T = ReplayHdrBeginSubCtxRef
    const dataType = TrtBeginHeaders
  when instr is TraceGetBlockHeaders:
    type T = ReplayHeadersSubCtxRef
    const dataType = TrtGetBlockHeaders
  when instr is TraceBeginBlocks:
    type T = ReplayBlkBeginSubCtxRef
    const dataType = TrtBeginBlocks
  when instr is TraceGetBlockBodies:
    type T = ReplayBodiesSubCtxRef
    const dataType = TrtGetBlockBodies
  when instr is TraceImportBlock:
    type T = ReplayImportSubCtxRef
    const dataType = TrtImportBlock

  when desc is ReplayBuddyRef:                  # for logging/debugging only
    let peer {.used.} = desc.peer               # for logging/debugging only
  else:                                         # for logging/debugging only
    let peer {.used.} = "n/a"                   # for logging/debugging only
  let serial {.used.} = instr.serial            # for logging/debugging only
  var count = 0                                 # for logging/debugging only
  trace info & "wait for data request", serial, peer, dataType

  # Wait for the `recType` type flag to appear on `desc.stage[0]`.
  (await desc.run.waitForConditionImpl(
    cond = proc(): bool =
      count.inc                                 # for logging/debugging only
      block noiseCtrl:                          # for logging/debugging only
        if count < 100:                         # for logging/debugging only
          break noiseCtrl                       # for logging/debugging only
        elif count < 1000:                      # for logging/debugging only
          if (count mod 111) != 0:              # for logging/debugging only
            break noiseCtrl                     # for logging/debugging only
        else:                                   # for logging/debugging only
          if (count mod 1111) != 0:             # for logging/debugging only
            break noiseCtrl                     # for logging/debugging only
        trace info & "polling for request", serial, peer, dataType, count
      return ReplayFrameRef(desc.stage[0]).subSync == dataType,
    info)).isOkOr:
      return err(error)

  # Stage/push session data
  desc.stage.add T(
    recType: dataType,
    instr:   instr)

  count = 0                                     # for logging/debugging only

  # Wait for the `desc.stage[0].subSync` type flag to disappear.
  (await desc.run.waitForConditionImpl(
    cond = proc(): bool =
      count.inc                                 # for logging/debugging only
      block noiseCtrl:                          # for logging/debugging only
        if count < 100:                         # for logging/debugging only
          break noiseCtrl                       # for logging/debugging only
        elif count < 1000:                      # for logging/debugging only
          if (count mod 111) != 0:              # for logging/debugging only
            break noiseCtrl                     # for logging/debugging only
        else:                                   # for logging/debugging only
          if (count mod 1111) != 0:             # for logging/debugging only
            break noiseCtrl                     # for logging/debugging only
        trace info & "polling for ackn", serial, peer, dataType, count
      return ReplayFrameRef(desc.stage[0]).subSync != dataType,
    info)).isOkOr:
      return err(error)

  # Pop session data from stack
  desc.stage.setLen(1)

  trace info & "done", serial, peer, dataType
  return ok()


proc getSessionData*[T: TraceBeginHeaders    |
                        TraceGetBlockHeaders |
                        TraceBeginBlocks     |
                        TraceGetBlockBodies  |
                        TraceImportBlock     ](
    desc: ReplayDaemonRef|ReplayBuddyRef;
    info: static[string];
      ): Future[Result[T,ReplayWaitError]]
      {.async: (raises: []).} =
  ## Collect session data staged with `provideSessionData()`
  ##
  when desc is ReplayBuddyRef:
    const frameType = TrtSchedPeerBegin
  when desc is ReplayDaemonRef:
    const frameType = TrtSchedDaemonBegin

  when T is TraceBeginHeaders:
    type C = ReplayHdrBeginSubCtxRef
    const dataType = TrtBeginHeaders
  when T is TraceGetBlockHeaders:
    type C = ReplayHeadersSubCtxRef
    const dataType = TrtGetBlockHeaders
  when T is TraceBeginBlocks:
    type C = ReplayBlkBeginSubCtxRef
    const dataType = TrtBeginBlocks
  when T is TraceGetBlockBodies:
    type C = ReplayBodiesSubCtxRef
    const dataType = TrtGetBlockBodies
  when T is TraceImportBlock:
    type C = ReplayImportSubCtxRef
    const dataType = TrtImportBlock

  when desc is ReplayBuddyRef:                  # for logging/debugging only
    let peer {.used.} = desc.peer               # for logging/debugging only
  when desc is ReplayDaemonRef:                 # for logging/debugging only
    let peer {.used.} = "n/a"                   # for logging/debugging only
  var count = 0                                 # for logging/debugging only
  trace info & "request session data", serial="n/a", peer, dataType

  # Verify that the stage is based on a proper environment
  doAssert desc.stage.len == 1
  doAssert ReplayFrameRef(desc.stage[0]).recType == frameType
  doAssert ReplayFrameRef(desc.stage[0]).subSync == TraceRecType(0)

  # Request data input by setting the type flag and wait for data.
  ReplayFrameRef(desc.stage[0]).subSync = dataType
  (await desc.run.waitForConditionImpl(
    cond = proc(): bool =
      count.inc                                 # for logging/debugging only
      block noiseCtrl:                          # for logging/debugging only
        if count < 100:                         # for logging/debugging only
          break noiseCtrl                       # for logging/debugging only
        elif count < 1000:                      # for logging/debugging only
          if (count mod 111) != 0:              # for logging/debugging only
            break noiseCtrl                     # for logging/debugging only
        else:                                   # for logging/debugging only
          if (count mod 1111) != 0:             # for logging/debugging only
            break noiseCtrl                     # for logging/debugging only
        trace info & "polling for data", serial="n/a", peer, dataType, count
      return 1 < desc.stage.len and
             desc.stage[1].recType == dataType,
    info)).isOkOr:
      return err(error)

  # Verify that the stage has not been tampered with by other processes
  doAssert desc.stage.len == 2
  doAssert ReplayFrameRef(desc.stage[0]).subSync == dataType

  # Capture session data `instr` to be returned later.
  let instr = C(desc.stage[1]).instr

  let serial {.used.} = instr.serial            # for logging/debugging only
  count = 0                                     # for logging/debugging only

  # Reset flag and wait for staged data to disappear from stack
  ReplayFrameRef(desc.stage[0]).subSync = TraceRecType(0)
  (await desc.run.waitForConditionImpl(
    cond = proc(): bool =
      count.inc                                 # for logging/debugging only
      block noiseCtrl:                          # for logging/debugging only
        if count < 100:                         # for logging/debugging only
          break noiseCtrl                       # for logging/debugging only
        elif count < 1000:                      # for logging/debugging only
          if (count mod 111) != 0:              # for logging/debugging only
            break noiseCtrl                     # for logging/debugging only
        else:                                   # for logging/debugging only
          if (count mod 1111) != 0:             # for logging/debugging only
            break noiseCtrl                     # for logging/debugging only
        trace info & "polling for release", serial, peer, dataType, count
      return desc.stage.len < 2 or
             desc.stage[1].recType != dataType,
    info)).isOkOr:
      return err(error)
  trace info & "released session data", serial, peer, dataType

  # Wait for the environment to get synchronised.
  (await desc.waitForSyncedEnv(instr, info)).isOkOr:
    return err(error)

  # The syncer state was captured after the corresponding handler was run.
  # The `unproc` list were already checked with `waitForSyncedEnv()`.
  discard desc.baseOrPeerStatesDifferImpl(instr, info)

  trace info & "done with session data", serial, peer, dataType
  return ok(instr)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
