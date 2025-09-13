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
  ../../../../../execution_chain/networking/[p2p, p2p_peers],
  ../../../../../execution_chain/sync/wire_protocol,
  ../../../../../execution_chain/sync/beacon/worker/helpers as worker_helpers,
  ../../../trace/trace_setup/setup_helpers as trace_helpers,
  ../../replay_desc

export
  trace_helpers.idStr,
  trace_helpers.short,
  worker_helpers

logScope:
  topics = "replay runner"

type
  ReplayWaitResult* = Result[void,ReplayWaitError]

  ReplayInstance = ReplayDaemonRef | ReplayBuddyRef

  SubInstrType = TraceFetchHeaders | TraceSyncHeaders |
                 TraceFetchBodies  | TraceSyncBodies  |
                 TraceImportBlock  | TraceSyncBlock

  InstrType = TraceSchedDaemonBegin  | TraceSchedDaemonEnd  |
              TraceSchedPeerBegin    | TraceSchedPeerEnd    |
              SubInstrType

# ------------------------------------------------------------------------------
# Private helper(s)
# ------------------------------------------------------------------------------

template waitForConditionImpl(
    run: ReplayRunnerRef;
    info: static[string];
    cond: untyped;
      ): ReplayWaitResult =
  ## Async/template
  ##
  ## Wait until the condition `cond()` becomes`true`. If a `stopRunner` flag
  ## is becomes `true`, this wait function function returns `err(..)`, and
  ## `ok()` otherwise.
  ##
  var bodyRc = ReplayWaitResult.ok()
  block body:
    let
      start = Moment.now()
      n {.inject.} = run.instrNumber
    var
      tmoPending {.inject.} = false
      count {.inject.} = 0

    while true:
      count.inc

      if run.stopRunner:
        chronicles.info info & ": runner stopped", n
        bodyRc = ReplayWaitResult.err((ENoException,"",info&": runner stopped"))
        break body # no timeout logging

      if cond:
        break

      if tmoPending:
        error info & ": timeout -- STOP", n, elapsed=(Moment.now()-start).toStr
        run.stopRunner = true
        bodyRc = ReplayWaitResult.err((ECancelledError,"",info&": timeout"))
        break

      try:
        await sleepAsync replayWaitForCompletion
      except CancelledError as e:
        chronicles.info info & ": cancelled -- STOP", n
        run.stopRunner = true
        bodyRc = ReplayWaitResult.err((ECancelledError,$e.name,e.msg))
        break

      if replayFailTimeout < Moment.now() - start:
        tmoPending = true

      # End `while()`

    # Log maximum waiting time
    let ela = Moment.now() - start
    if run.failTmoMax < ela:
      if replayFailTmoMinLog <= ela:
        debug info & ": max waiting time", n,
          elaMax=ela.toStr, lastElaMax=run.failTmoMax.toStr
      run.failTmoMax = ela

    # End block: `body`

  bodyRc # result


func syncedEnvCondImpl(
    desc: ReplayInstance;
    instr: InstrType;
    info: static[string];
      ): bool =
  ## Condition function for `waitForConditionImpl()` for synchronising state.
  ##
  let ctx = desc.run.ctx

  #if serial != run.instrNumber:
  #  return false

  if instr.hdrUnprChunks != ctx.hdr.unprocessed.chunks().uint:
    return false
  if 0 < instr.hdrUnprChunks:
    if instr.hdrUnprLen != ctx.hdr.unprocessed.total():
      return false
    let iv = ctx.hdr.unprocessed.le().expect "valid iv"
    if instr.hdrUnprLast != iv.maxPt or
       instr.hdrUnprLastLen != iv.len:
      return false
    if instr.antecedent != ctx.hdrCache.antecedent.number:
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

  return true


proc newPeerImpl(
    run: ReplayRunnerRef;
    instr: TraceSchedStart|TraceSchedStop|TraceSchedPool|TraceSchedPeerBegin;
    info: static[string];
      ): ReplayBuddyRef =
  ## Register a new peer.
  ##
  run.peers.withValue(instr.peerID, val):
    warn info & ": peer exists already", n=run.instrNumber,
      serial=instr.serial, peer=($val.peer)
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
      peerStates:     run.ethState.prots,
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
    desc: ReplayRunnerRef | ReplayInstance;
    instr: TraceRecBase;
    ignLatestNum: static[bool];
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
    n = run.instrNumber
    serial = instr.serial
  var
    statesDiffer = false

  if serial != n:
    statesDiffer = true
    info info & ": serial numbers differ", n, peer, serial, expected=n

  if ctx.chain.baseNumber != instr.baseNum:
    statesDiffer = true
    info info & ": base blocks differ", n, serial, peer,
      base=instr.baseNum.bnStr, expected=ctx.chain.baseNumber.bnStr

  when not ignLatestNum:
    if ctx.chain.latestNumber != instr.latestNum:
      statesDiffer = true
      info info & ": latest blocks differ", n, serial, peer,
        latest=instr.latestNum.bnStr, expected=ctx.chain.latestNumber.bnStr

  if ctx.pool.lastState != instr.syncState:
    statesDiffer = true
    info info & ": sync states differ", n, serial, peer,
      state=ctx.pool.lastState, expected=instr.syncState

  if ctx.hdrCache.state != instr.chainMode:
    statesDiffer = true
    info info & ": header chain modes differ", n, serial, peer,
      chainMode=ctx.hdrCache.state, expected=instr.chainMode
  elif instr.chainMode in {collecting,ready,orphan} and
       instr.antecedent != ctx.hdrCache.antecedent.number:
    statesDiffer = true
    info info & ": header chain antecedents differ", n, serial, peer,
      antecedent=ctx.hdrCache.antecedent.bnStr, expected=instr.antecedent.bnStr

  if ctx.pool.nBuddies != instr.nPeers.int:
    statesDiffer = true
    info info & ": number of active peers differs", n, serial, peer,
      nBuddies=ctx.pool.nBuddies, expected=instr.nPeers

  if ctx.poolMode != instr.poolMode:
    statesDiffer = true
    info info & ": pool modes/reorgs differ", n, serial, peer,
      poolMode=ctx.poolMode, expected=instr.poolMode

  return statesDiffer


proc unprocListsDifferImpl(
    desc: ReplayRunnerRef | ReplayInstance;
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
    n = run.instrNumber
    serial = instr.serial
  var
    statesDiffer = false

  # Unprocessed block numbers for header
  if instr.hdrUnprChunks != ctx.hdr.unprocessed.chunks().uint:
    statesDiffer = true
    info info & ": unproc headers lists differ", n, serial, peer,
      listChunks=ctx.hdr.unprocessed.chunks(), expected=instr.hdrUnprChunks
  if 0 < instr.hdrUnprChunks:
    if instr.hdrUnprLen != ctx.hdr.unprocessed.total():
      statesDiffer = true
      info info & ": unproc headers lists differ", n, serial, peer,
        listLen=ctx.hdr.unprocessed.total(), expected=instr.hdrUnprLen
    let iv = ctx.hdr.unprocessed.le().expect "valid iv"
    if instr.hdrUnprLastLen != iv.len:
      statesDiffer = true
      info info & ": unproc headers lists differ", n, serial, peer,
        lastIvLen=iv.len, expected=instr.hdrUnprLastLen
    if instr.hdrUnprLast != iv.maxPt:
      statesDiffer = true
      info info & ": unproc headers lists differ", n, serial, peer,
        lastIvMax=iv.maxPt, expected=instr.hdrUnprLast

  # Unprocessed block numbers for blocks
  if instr.blkUnprChunks != ctx.blk.unprocessed.chunks().uint:
    statesDiffer = true
    info info & ": unproc blocks lists differ", n, serial, peer,
      listChunks=ctx.blk.unprocessed.chunks(), expected=instr.blkUnprChunks
  if 0 < instr.blkUnprChunks:
    if instr.blkUnprLen != ctx.blk.unprocessed.total():
      statesDiffer = true
      info info & ": unproc blocks lists differ", n, serial, peer,
        listLen=ctx.blk.unprocessed.total(), expected=instr.blkUnprLen
    let iv = ctx.blk.unprocessed.ge().expect "valid iv"
    if instr.blkUnprLeastLen != iv.len:
      statesDiffer = true
      info info & ": unproc blocks lists differ", n, serial, peer,
        lastIvLen=iv.len, expected=instr.blkUnprLeastLen
    if instr.blkUnprLeast != iv.minPt:
      statesDiffer = true
      info info & ": unproc blocks lists differ", n, serial, peer,
        lastIvMax=iv.maxPt, expected=instr.blkUnprLeast

  return statesDiffer


proc peerStatesDifferImpl(
    desc: ReplayBuddyRef;
    instr: TraceRecBase;
    info: static[string];
      ): bool =
  let
    peer = desc.peer
    n = desc.run.instrNumber
    serial = instr.serial
  var
    statesDiffer = false

  if desc.ctrl.state != instr.peerCtrl:
    statesDiffer = true
    info info & ": peer ctrl states differ", n, serial, peer,
      ctrl=desc.ctrl.state, expected=instr.peerCtrl

  if instr.nHdrErrors != desc.only.nRespErrors.hdr:
    statesDiffer = true
    info info & ": peer header errors differ", n, serial, peer,
      nHdrErrors=desc.only.nRespErrors.hdr, expected=instr.nHdrErrors

  if instr.nBlkErrors != desc.only.nRespErrors.blk:
    statesDiffer = true
    info info & ": peer body errors differ", n, serial, peer,
      nBlkErrors=desc.only.nRespErrors.blk, expected=instr.nBlkErrors

  return statesDiffer

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func iNum*(desc: ReplayInstance|ReplayRunnerRef|BeaconCtxRef): uint =
  when desc is ReplayRunnerRef:
    desc.instrNumber
  elif desc is BeaconCtxRef:
    desc.replay.runner.instrNumber
  else:
    desc.run.instrNumber

func toStr*(w: BlockHashOrNumber): string =
  if w.isHash: w.hash.short else: w.number.bnStr

func peerStr*(desc: ReplayInstance): string =
  when desc is ReplayBuddyRef:
    $desc.peer
  elif desc is ReplayDaemonRef:
    "n/a"

func peerIdStr*(desc: ReplayInstance): string =
  when desc is ReplayBuddyRef:
    desc.peerID.short
  elif desc is ReplayDaemonRef:
    "n/a"

# -----------------

proc stopError*(run: ReplayRunnerRef; info: static[string]) =
  error info & " -- STOP", n=run.instrNumber
  run.stopRunner = false

proc stopOk*(run: ReplayRunnerRef; info: static[string]) =
  info info & " -- STOP", n=run.instrNumber
  run.stopRunner = false

# -----------------

proc checkSyncerState*(
    desc: ReplayRunnerRef | ReplayInstance;
    instr: TraceRecBase;
    ignLatestNum: static[bool];
    info: static[string];
      ): bool
      {.discardable.} =
  ## Check syncer states against all captured state variables of the
  ## `instr` argument.
  var statesDiffer = false

  if desc.baseStatesDifferImpl(instr, ignLatestNum, info):
    statesDiffer = true

  if desc.unprocListsDifferImpl(instr, info):
    statesDiffer = true

  when desc is ReplayBuddyRef:
    if desc.peerStatesDifferImpl(instr, info):
      statesDiffer = true

  return statesDiffer

proc checkSyncerState*(
    desc: ReplayRunnerRef | ReplayInstance;
    instr: TraceRecBase;
    info: static[string];
      ): bool
      {.discardable.} =
  desc.checkSyncerState(instr, false, info)

# ------------------------------------------------------------------------------
# Public functions, peer/daemon descriptor management
# ------------------------------------------------------------------------------

proc getPeer*(
    run: ReplayRunnerRef;
    instr: TraceRecBase;
    info: static[string];
      ): Opt[ReplayBuddyRef] =
  ## Get peer from peers table (if any)
  run.peers.withValue(instr.peerID, buddy):
    return ok(buddy[])

  debug info & ": no peer", n=run.iNum, serial=instr.serial,
    peerID=instr.peerID.short
  return err()


proc newPeer*(
    run: ReplayRunnerRef;
    instr: TraceSchedStart;
    info: static[string];
      ): ReplayBuddyRef =
  ## Register a new peer.
  ##
  return run.newPeerImpl(instr, info)


proc getOrNewPeerFrame*(
    run: ReplayRunnerRef;
    instr: TraceSchedStop|TraceSchedPool|TraceSchedPeerBegin;
    info: static[string];
      ): ReplayBuddyRef =
  ## Get an existing one or register a new peer and set up `stage[0]`.
  ##
  var buddy: ReplayBuddyRef
  run.peers.withValue(instr.peerID, val):
    buddy = val[]
    buddy.isNew = false
  do:
    buddy = run.newPeerImpl(instr, info)

  if buddy.frameID == 0:
    buddy.frameID = instr.frameID
  elif buddy.frameID != instr.frameID:
    error info & ": frame unexpected", n=buddy.iNum, serial=instr.serial,
      frameID=buddy.frameID.idStr, expected=instr.frameID.idStr
  return move(buddy)


proc delPeer*(
    buddy: ReplayBuddyRef;
    info: static[string];
      ) =
  ## Delete peer ID from registry and return the environment for the
  ## deleted peer ID.
  ##
  let run = buddy.run
  if run.peers.hasKey(buddy.peerID):
    run.peers.del buddy.peerID
  else:
    trace info & ": stale peer ignored", n=buddy.iNum,
      peer=($buddy.peer), peerID=buddy.peerID.short

# -----------------

proc getDaemon*(
    run: ReplayRunnerRef;
    info: static[string];
      ): Opt[ReplayDaemonRef] =
  ## Similar to `getPeer()` for daemon
  if not run.daemon.isNil:
    return ok(run.daemon)

  warn info & ": no daemon", n=run.instrNumber
  return err()


proc newDaemonFrame*(
    run: ReplayRunnerRef;
    instr: TraceSchedDaemonBegin;
    info: static[string];
      ): Opt[ReplayDaemonRef] =
  ## Similar to `getOrNewPeerFrame()` for daemon.
  if run.daemon.isNil:
    run.daemon = ReplayDaemonRef(
      run:     run,
      frameID: instr.frameID)
    return ok(run.daemon)

  warn info & ": daemon already registered", n=run.iNum, serial=instr.serial,
    frameID=instr.frameID.idStr
  return err()


proc delDaemon*(
    daemon: ReplayDaemonRef;
    info: static[string];
      ) =
  ## Similar to `delPeer()` for daemon
  let run = daemon.run
  if run.daemon.isNil:
    trace info & ": stale daemon ignored", n=run.instrNumber
  else:
    run.daemon = ReplayDaemonRef(nil)

# ------------------------------------------------------------------------------
# Public functions, process/handler synchronisation
# ------------------------------------------------------------------------------

proc waitForSyncedEnv*(
    desc: ReplayInstance;
    instr: InstrType;
    info: static[string];
      ): Future[ReplayWaitResult]
      {.async: (raises: []).} =
  ## ..
  ##
  when desc is ReplayBuddyRef:
    # The scheduler (see `sync_sched.nim`)  might have disconnected the peer
    # already as is captured in the instruction environment. This does not
    # apply to `zombie` settings which will be done by the application.
    if instr.peerCtrl == Stopped and not desc.ctrl.stopped:
      desc.ctrl.stopped = true

  let
    serial {.inject,used.} = instr.serial
    peer {.inject,used.} = desc.peerStr
    peerID {.inject,used.} = desc.peerIdStr
    
  trace info & ": process to be synced", n=desc.iNum, serial, peer, peerID

  let rc = desc.run.waitForConditionImpl(info):
    if tmoPending:
      debug info & ": syncing", n=desc.iNum, serial, peer, count
      desc.checkSyncerState(instr, info & ", syncing")
    desc.syncedEnvCondImpl(instr, info) # cond result

  if rc.isErr():
    # Shutdown?
    trace info & ": process sync error", n=desc.iNum,
      serial, peer, peerID, name=rc.error.name, msg=rc.error.msg
    return err(rc.error)

  trace info & ": process synced ok", n=desc.iNum, serial, peer, peerID
  desc.checkSyncerState(instr, ignLatestNum=true, info) # relaxed check

  return ok()

# ------------------

proc processFinished*(
    desc: ReplayInstance;
    instr: TraceSchedDaemonBegin|TraceSchedPeerBegin;
    info: static[string];
      ) =
  ## Register that the process has finished
  ##
  # Verify that sub-processes did not change the environment
  doAssert desc.frameID == instr.frameID

  # Mark the pocess `done`
  desc.frameID = 0

  trace info & ": terminating", n=desc.iNum,
    serial=instr.serial, frameID=instr.frameID.idStr, peer=desc.peerStr


template whenProcessFinished*(
    desc: ReplayInstance;
    instr: TraceSchedDaemonEnd|TraceSchedPeerEnd;
    info: static[string];
      ): ReplayWaitResult =
  ## Async/template
  ##
  ## Execude the argument `code` when the process related to the `instr`
  ## argument flag has finished. The variables and functions available for
  ## `code` are:
  ## * `error` -- error data, initialised if `instr.isAvailable()` is `false`
  ##
  var bodyRc = ReplayWaitResult.ok()
  block body:
    let
      peer {.inject,used.} = desc.peerStr
      peerID {.inject,used.} = desc.peerIdStr
      serial {.inject,used.} = instr.serial

    if desc.frameID != 0:
      doAssert desc.frameID == instr.frameID

    trace info & ": wait for terminated", n=desc.iNum, serial,
      frameID=instr.frameID.idStr, peer, peerID

    bodyRc = desc.run.waitForConditionImpl(info):
      if tmoPending:
        debug info & ": wait for terminated", n, serial, peer, count
      desc.frameID == 0

    if bodyRc.isErr:
      break body

    trace info & ": terminated OK", n=desc.iNum, serial,
      frameID=instr.frameID.idStr, peer
    desc.checkSyncerState(instr, ignLatestNum=true, info) # relaxed check

    # Synchronise against captured environment
    bodyRc = desc.run.waitForConditionImpl(info):
      if tmoPending:
        debug info & ": syncing", n=desc.iNum, serial, peer, peerID, count
        desc.checkSyncerState(instr, info & ", syncing")
      desc.syncedEnvCondImpl(instr, info) # cond result

    if bodyRc.isErr:
      break body

    trace info & ": finished", n=desc.iNum, serial,
      frameID=instr.frameID.idStr, peer, peerID
    # End body

  bodyRc # result

# ------------------

template pushInstr*(
    desc: ReplayInstance;
    instr: SubInstrType;
    info: static[string];
      ): ReplayWaitResult =
  ## Async/template
  ##
  ## Stage session data, then wait for the background process to consume the
  ## session data using `withInstr()`.
  ##
  var bodyRc = ReplayWaitResult.ok()
  block:
    when instr is TraceFetchHeaders:
      type T = ReplayFetchHeadersMsgRef
      const dataType {.inject.} = TrtFetchHeaders
    elif instr is TraceSyncHeaders:
      type T = ReplaySyncHeadersMsgRef
      const dataType {.inject.} = TrtSyncHeaders

    elif instr is TraceFetchBodies:
      type T = ReplayFetchBodiesMsgRef
      const dataType {.inject.} = TrtFetchBodies
    elif instr is TraceSyncBodies:
      type T = ReplaySyncBodiesMsgRef
      const dataType {.inject.} = TrtSyncBodies

    elif instr is TraceImportBlock:
      type T = ReplayImportBlockMsgRef
      const dataType {.inject.} = TrtImportBlock
    elif instr is TraceSyncBlock:
      type T = ReplaySyncBlockMsgRef
      const dataType {.inject.} = TrtSyncBlock

    # Verify that the stage is based on a proper environment
    doAssert desc.frameID != 0 # this is not `instr.frameID`

    let
      peer {.inject,used.} = desc.peerStr
      peerID {.inject,used.} = desc.peerIdStr
      serial {.inject.} = instr.serial

    doAssert serial == desc.iNum
    doAssert desc.message.isNil

    # Stage/push session data
    desc.message = T(
      recType: dataType,
      instr:   instr)

    block body:
      # Wait for sync                               # FIXME, really needed?
      bodyRc = desc.run.waitForConditionImpl(info): # FIXME, really needed?
        if tmoPending:
          debug info & ": syncing", n, serial, peer, peerID, dataType, count
          desc.checkSyncerState(instr, info & ", syncing")
        desc.syncedEnvCondImpl(instr, info) # cond result

      if bodyRc.isErr():
        break body

      doAssert serial == desc.iNum

      trace info & ": sent data", n=desc.iNum, serial, peer, peerID, dataType

      # Wait for message to be swallowed
      bodyRc = desc.run.waitForConditionImpl(info):
        if tmoPending:
          debug info & ": wait ackn", n, serial, peer, peerID, dataType, count
        desc.message.isNil # cond result

      if bodyRc.isErr():
        break body
      # End body

      trace info & ": done", n=desc.iNum, serial, peer, peerID, dataType
      doAssert desc.iNum == serial

  bodyRc # result


template withInstr*(
    desc: ReplayInstance;
    I: type SubInstrType;
    info: static[string];
    code: untyped;
      ) =
  ## Async/template
  ##
  ## Execude the argument `code` with the data sent by a feeder. The variables
  ## and functions available for `code` are:
  ## * `instr` -- instruction data, available if `instr.isAvailable()` is `true`
  ## * `iError` -- error data, initialised if `instr.isAvailable()` is `false`
  ##
  block:
    when I is TraceFetchHeaders:
      const dataType {.inject.} = TrtFetchHeaders
      type M = ReplayFetchHeadersMsgRef
      const ignLatestNum = false
    elif I is TraceSyncHeaders:
      const dataType {.inject.} = TrtSyncHeaders
      type M = ReplaySyncHeadersMsgRef
      const ignLatestNum = false

    elif I is TraceFetchBodies:
      const dataType {.inject.} = TrtFetchBodies
      type M = ReplayFetchBodiesMsgRef
      const ignLatestNum = true # relax, de-noise
    elif I is TraceSyncBodies:
      const dataType {.inject.} = TrtSyncBodies
      type M = ReplaySyncBodiesMsgRef
      const ignLatestNum = true # relax, de-noise

    elif I is TraceImportBlock:
      const dataType {.inject.} = TrtImportBlock
      type M = ReplayImportBlockMsgRef
      const ignLatestNum = true # relax, de-noise
    elif I is TraceSyncBlock:
      const dataType {.inject.} = TrtSyncBlock
      type M = ReplaySyncBlockMsgRef
      const ignLatestNum = false

    let
      run = desc.run
      peer {.inject,used.} = desc.peerStr
      peerID {.inject,used.} = desc.peerIdStr

    trace info & ": get data", n=desc.iNum, serial="n/a",
      frameID="n/a", peer, dataType

    # Reset flag and wait for staged data to disappear from stack
    let rc = run.waitForConditionImpl(info):
      if tmoPending:
        debug info & ": expecting data", n, serial="n/a", frameID="n/a",
          peer, peerID, dataType, count
      not desc.message.isNil # cond result

    var
      iError {.inject.}: ReplayWaitError
      instr {.inject.}: I

    if rc.isOk():
      instr = M(desc.message).instr
      doAssert desc.message.recType == dataType
      doAssert instr.serial == desc.iNum

      when desc is ReplayBuddyRef:
        # The scheduler (see `sync_sched.nim`)  might have disconnected the
        # peer already which would be captured in the instruction environment.
        # This does not apply to `zombie` settings which will be handled by
        # the application `code`.
        if instr.peerCtrl == Stopped and not desc.ctrl.stopped:
          desc.ctrl.stopped = true
    else:
      iError = rc.error

    template isAvailable(_: typeof instr): bool {.used.} = rc.isOk()

    code

    if rc.isOk():
      doAssert not desc.message.isNil
      doAssert desc.message.recType == dataType
      doAssert instr.serial == desc.iNum

      desc.checkSyncerState(instr, ignLatestNum, info)

      debug info & ": got data", n=desc.iNum, serial=instr.serial,
        frameID=instr.frameID.idStr, peer, peerID, dataType

    desc.message = M(nil)

  discard # no-op, visual alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
