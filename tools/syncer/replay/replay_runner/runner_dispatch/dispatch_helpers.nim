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
  ../runner_desc

export
  trace_helpers.idStr,
  trace_helpers.short,
  worker_helpers

logScope:
  topics = "replay runner"

type
  ReplayWaitResult* = Result[void,ReplayWaitError]

  ReplayInstance = ReplayDaemonRef | ReplayBuddyRef

  ReplayMsgInstrType =   ReplayFetchHeaders | ReplaySyncHeaders |
                         ReplayFetchBodies  | ReplaySyncBodies  |
                         ReplayImportBlock  | ReplaySyncBlock

  ReplayPeerInstrType =  ReplaySchedPeerBegin | ReplaySchedPeerEnd |
                         ReplaySchedStart     | ReplaySchedStop    |
                         ReplaySchedPool

  ReplaySchedInstrType = ReplaySchedDaemonBegin | ReplaySchedDaemonEnd |
                         ReplayPeerInstrType

  ReplayAnyInstrType =   ReplayVersionInfo    |
                         ReplaySyncActivated  | ReplaySyncHibernated |
                         ReplaySchedInstrType |
                         ReplayMsgInstrType

func peerStr*(desc: ReplayInstance): string

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

      if run.failTimeout < Moment.now() - start:
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
    instr: ReplayAnyInstrType;
    info: static[string];
      ): bool =
  ## Condition function for `waitForConditionImpl()` for synchronising state.
  ##
  let ctx = desc.run.ctx

  if instr.bag.hdrUnpr.isSome():
    if instr.bag.hdrUnpr.value.hChunks != ctx.hdr.unprocessed.chunks().uint:
      return false
    if 0 < instr.bag.hdrUnpr.value.hChunks:
      if instr.bag.hdrUnpr.value.hLen != ctx.hdr.unprocessed.total():
        return false
      let iv = ctx.hdr.unprocessed.le().expect "valid iv"
      if instr.bag.hdrUnpr.value.hLastNum != iv.maxPt or
         instr.bag.hdrUnpr.value.hLastLen != iv.len:
        return false
      if instr.bag.anteNum != ctx.hdrCache.antecedent.number:
        return false

  if instr.bag.blkUnpr.isSome():
    if instr.bag.blkUnpr.value.bChunks != ctx.blk.unprocessed.chunks().uint:
      return false
    if 0 < instr.bag.blkUnpr.value.bChunks:
      if instr.bag.blkUnpr.value.bLen != ctx.blk.unprocessed.total():
        return false
      let iv = ctx.blk.unprocessed.ge().expect "valid iv"
      if instr.bag.blkUnpr.value.bLeastNum != iv.minPt or
         instr.bag.blkUnpr.value.bLeastLen != iv.len:
        return false

  return true


proc newPeerImpl(
    run: ReplayRunnerRef;
    instr: ReplayPeerInstrType;
    info: static[string];
      ): Opt[ReplayBuddyRef] =
  ## Register a new peer.
  ##
  if instr.bag.peerCtx.isNone():
    warn info & ": missing peer ctx", n=run.instrNumber, serial=instr.bag.serial
    return err()

  run.peers.withValue(instr.bag.peerCtx.value.peerID, val):
    warn info & ": peer exists already", n=run.instrNumber,
      serial=instr.bag.serial, peer=($val.peer)
    val.isNew = false
    return ok(val[])

  var buddy = ReplayBuddyRef(
    isNew:            true,
    run:              run,
    ctx:              run.ctx,
    only: BeaconBuddyData(
      nErrors:        instr.bag.peerCtx.value.nErrors),
    peerID:           instr.bag.peerCtx.value.peerID,
    peer: Peer(
      dispatcher:     run.ethState.capa,
      peerStates:     run.ethState.prots,
      remote: Node(
        node: ENode(
          address: enode.Address(
            ip:       instr.bag.peerIP,
            tcpPort:  instr.bag.peerPort,
            udpPort:  instr.bag.peerPort)))))

  run.peers[instr.bag.peerCtx.value.peerID] = buddy
  return ok(move buddy)

# ------------------------------------------------------------------------------
# Private functions, environment checkers
# ------------------------------------------------------------------------------

proc baseStatesDifferImpl(
    desc: ReplayRunnerRef|ReplayInstance;
    instr: ReplayAnyInstrType;
    rlxBaseNum: static[bool];
    ignLatestNum: static[bool];
    info: static[string];
      ): bool =
  when desc is ReplayRunnerRef:
    let (run, peer) = (desc, "n/a")
  else:
    let (run, peer) = (desc.run, desc.peerStr)

  let
    ctx = run.ctx
    n = run.instrNumber
    serial = instr.bag.serial
  var
    statesDiffer = false

  if serial != n:
    statesDiffer = true
    info info & ": serial numbers differ", n, peer, serial, expected=n

  when rlxBaseNum:
    if ctx.chain.baseNumber != instr.bag.baseNum:
      debug info & ": base blocks differ", n, serial, peer,
        base=ctx.chain.baseNumber, expected=instr.bag.baseNum
  else:
    if ctx.chain.baseNumber != instr.bag.baseNum:
      statesDiffer = true
      info info & ": base blocks differ", n, serial, peer,
        base=ctx.chain.baseNumber, expected=instr.bag.baseNum

  when not ignLatestNum:
    if ctx.chain.latestNumber != instr.bag.latestNum:
      statesDiffer = true
      info info & ": latest blocks differ", n, serial, peer,
        latest=ctx.chain.latestNumber, expected=instr.bag.latestNum

  if ctx.pool.syncState != instr.bag.syncState:
    statesDiffer = true
    info info & ": sync states differ", n, serial, peer,
      state=ctx.pool.syncState, expected=instr.bag.syncState

  if ctx.hdrCache.state != instr.bag.chainMode:
    statesDiffer = true
    info info & ": header chain modes differ", n, serial, peer,
      chainMode=ctx.hdrCache.state, expected=instr.bag.chainMode
  elif instr.bag.chainMode in {collecting,ready,orphan} and
       instr.bag.anteNum != ctx.hdrCache.antecedent.number:
    statesDiffer = true
    info info & ": header chain antecedents differ", n, serial, peer,
      antecedent=ctx.hdrCache.antecedent.number,
      expected=instr.bag.anteNum

  if run.nSyncPeers != instr.bag.nSyncPeers.int:
    statesDiffer = true
    info info & ": number of active peers differs", n, serial, peer,
      nSyncPeers=run.nSyncPeers, expected=instr.bag.nSyncPeers

  if ctx.poolMode != instr.bag.poolMode:
    statesDiffer = true
    info info & ": pool modes/reorgs differ", n, serial, peer,
      poolMode=ctx.poolMode, expected=instr.bag.poolMode

  return statesDiffer


proc unprocListsDifferImpl(
    desc: ReplayRunnerRef|ReplayInstance;
    instr: ReplayAnyInstrType;
    info: static[string];
      ): bool =
  when desc is ReplayRunnerRef:
    let (run, peer) = (desc, "n/a")
  else:
    let (run, peer) = (desc.run, desc.peerStr)

  let
    ctx = run.ctx
    n = run.instrNumber
    serial = instr.bag.serial
  var
    statesDiffer = false

  # Unprocessed block numbers for header
  if instr.bag.hdrUnpr.isSome():
    if instr.bag.hdrUnpr.value.hChunks != ctx.hdr.unprocessed.chunks().uint:
      statesDiffer = true
      info info & ": unproc headers lists differ", n, serial, peer,
        listChunks=ctx.hdr.unprocessed.chunks(),
        expected=instr.bag.hdrUnpr.value.hChunks
    if 0 < instr.bag.hdrUnpr.value.hChunks:
      if instr.bag.hdrUnpr.value.hLen != ctx.hdr.unprocessed.total():
        statesDiffer = true
        info info & ": unproc headers lists differ", n, serial, peer,
          listLen=ctx.hdr.unprocessed.total(),
          expected=instr.bag.hdrUnpr.value.hLen
      let iv = ctx.hdr.unprocessed.le().expect "valid iv"
      if instr.bag.hdrUnpr.value.hLastLen != iv.len:
        statesDiffer = true
        info info & ": unproc headers lists differ", n, serial, peer,
          lastIvLen=iv.len, expected=instr.bag.hdrUnpr.value.hLastLen
      if instr.bag.hdrUnpr.value.hLastNum != iv.maxPt:
        statesDiffer = true
        info info & ": unproc headers lists differ", n, serial, peer,
          lastIvMax=iv.maxPt, expected=instr.bag.hdrUnpr.value.hLastNum

  # Unprocessed block numbers for blocks
  if instr.bag.blkUnpr.isSome():
    if instr.bag.blkUnpr.value.bChunks != ctx.blk.unprocessed.chunks().uint:
      statesDiffer = true
      info info & ": unproc blocks lists differ", n, serial, peer,
        listChunks=ctx.blk.unprocessed.chunks(),
        expected=instr.bag.blkUnpr.value.bChunks
    if 0 < instr.bag.blkUnpr.value.bChunks:
      if instr.bag.blkUnpr.value.bLen != ctx.blk.unprocessed.total():
        statesDiffer = true
        info info & ": unproc blocks lists differ", n, serial, peer,
          listLen=ctx.blk.unprocessed.total(),
          expected=instr.bag.blkUnpr.value.bLen
      let iv = ctx.blk.unprocessed.ge().expect "valid iv"
      if instr.bag.blkUnpr.value.bLeastLen != iv.len:
        statesDiffer = true
        info info & ": unproc blocks lists differ", n, serial, peer,
          lastIvLen=iv.len, expected=instr.bag.blkUnpr.value.bLeastLen
      if instr.bag.blkUnpr.value.bLeastNum != iv.minPt:
        statesDiffer = true
        info info & ": unproc blocks lists differ", n, serial, peer,
          lastIvMax=iv.maxPt, expected=instr.bag.blkUnpr.value.bLeastNum

  return statesDiffer


proc peerStatesDifferImpl(
    buddy: ReplayBuddyRef;
    instr: ReplayAnyInstrType;
    info: static[string];
      ): bool =
  let
    peer = buddy.peer
    n = buddy.run.instrNumber
    serial = instr.bag.serial
  var
    statesDiffer = false

  if instr.bag.peerCtx.isNone():
    statesDiffer = true
    info info & ": peer ctx values differ", n, serial, peer, ctx="n/a"
  else:
    if instr.bag.peerCtx.value.peerCtrl != buddy.ctrl.state:
      statesDiffer = true
      info info & ": peer ctrl states differ", n, serial, peer,
        ctrl=buddy.ctrl.state, expected=instr.bag.peerCtx.value.peerCtrl

    if instr.bag.peerCtx.value.nErrors.fetch != buddy.nErrors.fetch:
      statesDiffer = true
      info info & ": peer fetch errors differ", n, serial, peer,
        nHdrErrors=buddy.nErrors.fetch,
        expected=instr.bag.peerCtx.value.nErrors

    if instr.bag.peerCtx.value.nErrors.apply != buddy.only.nErrors.apply:
      statesDiffer = true
      info info & ": peer apply errors differ", n, serial, peer,
        nHdrErrors=buddy.nErrors.apply,
        expected=instr.bag.peerCtx.value.nErrors.apply

  return statesDiffer

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func iNum*(desc: ReplayInstance|ReplayRunnerRef): uint =
  when desc is ReplayRunnerRef:
    desc.instrNumber
  else:
    desc.run.instrNumber

func toStr*(w: BlockHashOrNumber): string =
  if w.isHash: w.hash.short else: $w.number

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

func frameIdStr*(instr: ReplaySchedInstrType): string =
  if instr.bag.frameID.isSome():
    instr.bag.frameID.value.idStr
  else:
    "n/a"

func frameIdStr*(desc: ReplayBuddyRef|ReplayDaemonRef): string =
  if desc.frameID.isSome():
    desc.frameID.value.idStr
  else:
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
    desc: ReplayRunnerRef|ReplayInstance;
    instr: ReplayAnyInstrType;
    rlxBaseNum: static[bool];
    ignLatestNum: static[bool];
    info: static[string];
      ): bool
      {.discardable.} =
  ## Check syncer states against all captured state variables of the
  ## `instr` argument.
  var statesDiffer = false

  if desc.baseStatesDifferImpl(instr, rlxBaseNum, ignLatestNum, info):
    statesDiffer = true

  if desc.unprocListsDifferImpl(instr, info):
    statesDiffer = true

  when desc is ReplayBuddyRef:
    if desc.peerStatesDifferImpl(instr, info):
      statesDiffer = true

  return statesDiffer

proc checkSyncerState*(
    desc: ReplayRunnerRef|ReplayInstance;
    instr: ReplayAnyInstrType;
    ignLatestNum: static[bool];
    info: static[string];
      ): bool
      {.discardable.} =
  desc.checkSyncerState(instr, false, ignLatestNum, info)

proc checkSyncerState*(
    desc: ReplayRunnerRef|ReplayInstance;
    instr: ReplayAnyInstrType;
    info: static[string];
      ): bool
      {.discardable.} =
  desc.checkSyncerState(instr, false, false, info)

# ------------------------------------------------------------------------------
# Public functions, peer/daemon descriptor management
# ------------------------------------------------------------------------------

proc getPeer*(
    run: ReplayRunnerRef;
    instr: ReplayPeerInstrType|ReplayMsgInstrType;
    info: static[string];
      ): Opt[ReplayBuddyRef] =
  ## Get peer from peers table (if any)
  if instr.bag.peerCtx.isNone():
    warn info & ": missing peer ctx", n=run.iNum, serial=instr.bag.serial
  else:
    run.peers.withValue(instr.bag.peerCtx.value.peerID, buddy):
      return ok(buddy[])
    debug info & ": no peer", n=run.iNum, serial=instr.bag.serial,
      peerID=instr.bag.peerCtx.value.peerID.short
  return err()


proc newPeer*(
    run: ReplayRunnerRef;
    instr: ReplaySchedStart;
    info: static[string];
      ): Opt[ReplayBuddyRef] =
  ## Register a new peer.
  ##
  return run.newPeerImpl(instr, info)


proc getOrNewPeerFrame*(
    run: ReplayRunnerRef;
    instr: ReplayPeerInstrType;
    info: static[string];
      ): Opt[ReplayBuddyRef] =
  ## Get an existing one or register a new peer and set up `stage[0]`.
  ##
  if instr.bag.peerCtx.isNone():
    return err()

  var buddy: ReplayBuddyRef
  run.peers.withValue(instr.bag.peerCtx.value.peerID, val):
    buddy = val[]
    buddy.isNew = false
  do:
    buddy = run.newPeerImpl(instr, info).expect "valid peer"

  if buddy.frameID.isSome():
    warn info & ": peer frameID unexpected", n=buddy.iNum,
      serial=instr.bag.serial, frameID=buddy.frameIdStr, expected="n/a"
  if instr.bag.frameID.isNone():
    warn info & ": peer instr frameID missing", n=buddy.iNum,
      serial=instr.bag.serial, frameID="n/a"

  buddy.frameID = instr.bag.frameID
  return ok(move buddy)


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
    instr: ReplaySchedDaemonBegin;
    info: static[string];
      ): Opt[ReplayDaemonRef] =
  ## Similar to `getOrNewPeerFrame()` for daemon.
  if run.daemon.isNil:
    if instr.bag.frameID.isNone():
      warn info & ": daemon instr frameID missing", n=run.iNum,
        serial=instr.bag.serial, frameID="n/a"
    run.daemon = ReplayDaemonRef(
      run:     run,
      frameID: instr.bag.frameID)
    return ok(run.daemon)

  warn info & ": daemon already registered", n=run.iNum,
    serial=instr.bag.serial, frameID=instr.frameIdStr
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
    instr: ReplaySchedInstrType ;
    info: static[string];
      ): Future[ReplayWaitResult]
      {.async: (raises: []).} =
  ## ..
  ##
  when desc is ReplayBuddyRef:
    # The scheduler (see `sync_sched.nim`)  might have disconnected the peer
    # already as is captured in the instruction environment. This does not
    # apply to `zombie` settings which will be done by the application.
    if instr.bag.peerCtx.isNone():
      warn info & ": missing peer ctx", n=desc.iNum, serial=instr.bag.serial
      return err((ENoException,"",info&": missing peer ctx"))
    if instr.bag.peerCtx.value.peerCtrl == Stopped and not desc.ctrl.stopped:
      desc.ctrl.stopped = true

  let
    serial {.inject,used.} = instr.bag.serial
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

proc processFinishedClearFrame*(
    desc: ReplayInstance;
    instr: ReplaySchedDaemonBegin|ReplaySchedPeerBegin|ReplaySchedPool;
    info: static[string];
      ) =
  ## Register that the process has finished
  ##
  # Verify that sub-processes did not change the environment
  if desc.frameID != instr.bag.frameID:
    warn info & ": frameIDs differ", n=desc.iNum, serial=instr.bag.serial,
      peer=desc.peerStr, frameID=desc.frameIdStr, expected=instr.frameIdStr

  # Mark the pocess `done`
  desc.frameID = Opt.none(uint)

  trace info & ": terminating", n=desc.iNum,
    serial=instr.bag.serial, frameID=instr.frameIdStr, peer=desc.peerStr


template whenProcessFinished*(
    desc: ReplayInstance;
    instr: ReplaySchedDaemonEnd|ReplaySchedPeerEnd;
    info: static[string];
      ): ReplayWaitResult =
  ## Async/template
  ##
  var bodyRc = ReplayWaitResult.ok()
  block body:
    let
      peer {.inject,used.} = desc.peerStr
      peerID {.inject,used.} = desc.peerIdStr
      serial {.inject,used.} = instr.bag.serial

    if desc.frameID.isSome():
      doAssert desc.frameID == instr.bag.frameID

    trace info & ": wait for terminated", n=desc.iNum, serial,
      frameID=instr.frameIdStr, peer, peerID

    bodyRc = desc.run.waitForConditionImpl(info):
      if tmoPending:
        debug info & ": wait for terminated", n, serial, peer, count
      desc.frameID.isNone()

    if bodyRc.isErr:
      break body

    trace info & ": terminated OK", n=desc.iNum, serial,
      frameID=instr.frameIdStr, peer
    desc.checkSyncerState(instr, rlxBaseNum=true, ignLatestNum=true, info)

    # Synchronise against captured environment
    bodyRc = desc.run.waitForConditionImpl(info):
      if tmoPending:
        debug info & ": syncing", n=desc.iNum, serial, peer, peerID, count
        desc.checkSyncerState(instr, info & ", syncing")
      desc.syncedEnvCondImpl(instr, info) # cond result

    if bodyRc.isErr:
      break body

    trace info & ": finished", n=desc.iNum, serial,
      frameID=instr.frameIdStr, peer, peerID
    # End body

  bodyRc # result

# ------------------

template pushInstr*(
    desc: ReplayInstance;
    instr: ReplayMsgInstrType;
    info: static[string];
      ): ReplayWaitResult =
  ## Async/template
  ##
  ## Stage session data, then wait for the background process to consume the
  ## session data using `withInstr()`.
  ##
  var bodyRc = ReplayWaitResult.ok()
  block:
    # Verify that the stage is based on a proper environment
    doAssert desc.frameID.isSome() # this is not `instr.bag.frameID`

    let
      peer {.inject,used.} = desc.peerStr
      peerID {.inject,used.} = desc.peerIdStr
      dataType {.inject.} = instr.recType
      serial {.inject.} = instr.bag.serial

    doAssert serial == desc.iNum
    doAssert desc.message.isNil

    # Stage/push session data
    desc.message = instr

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
    R: type ReplayMsgInstrType;
    rlxBaseNum: static[bool];
    ignLatestNum: static[bool];
    info: static[string];
    code: untyped;
      ) =
  ## Async/template
  ##
  ## Execude the argument `code` with the data sent by a feeder. The variables
  ## and functions available for `code` are:
  ## * `instr`  -- instr data, available if `instr.isAvailable()` is `true`
  ## * `iError` -- error data, initialised if `instr.isAvailable()` is `false`
  ##
  block:
    const dataType {.inject.} = (typeof R().bag).toTraceRecType

    let
      run = desc.run
      peer {.inject,used.} = desc.peerStr
      peerID {.inject,used.} = desc.peerIdStr

    trace info & ": get data", n=desc.iNum, serial="n/a", peer, dataType

    # Reset flag and wait for staged data to disappear from stack
    let rc = run.waitForConditionImpl(info):
      if tmoPending:
        debug info & ": expecting data", n, serial="n/a",
          peer, peerID, dataType, count
      not desc.message.isNil # cond result

    var
      iError {.inject.}: ReplayWaitError
      instr {.inject.}: R

    if rc.isOk():
      instr = R(desc.message)
      doAssert desc.message.recType == dataType
      doAssert instr.bag.serial == desc.iNum

      when desc is ReplayBuddyRef:
        # The scheduler (see `sync_sched.nim`)  might have disconnected the
        # peer already which would be captured in the instruction environment.
        # This does not apply to `zombie` settings which will be handled by
        # the application `code`.
        if instr.bag.peerCtx.isNone():
          warn info & ": missing peer ctx", n=desc.iNum,
            serial=instr.bag.serial, peer, peerID, dataType
          desc.ctrl.stopped = true
        elif instr.bag.peerCtx.value.peerCtrl == Stopped and
             not desc.ctrl.stopped:
          desc.ctrl.stopped = true
    else:
      iError = rc.error

    template isAvailable(_: R): bool {.used.} = rc.isOk()

    code

    if rc.isOk():
      doAssert not desc.message.isNil
      doAssert desc.message.recType == dataType
      doAssert instr.bag.serial == desc.iNum

      desc.checkSyncerState(instr, rlxBaseNum, ignLatestNum, info)

      debug info & ": got data", n=desc.iNum, serial=instr.bag.serial,
        peer, peerID, dataType

    desc.message = ReplayPayloadRef(nil)

  discard # no-op, visual alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
