# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Trace environment descriptor and helpers
##
## TODO:
## * n/a
##

{.push raises:[].}

import
  std/[net, streams],
  pkg/[chronos, eth/common],
  ../../../execution_chain/sync/wire_protocol,
  ../../../execution_chain/sync/beacon/beacon_desc,
  ../../../execution_chain/sync/beacon/worker/worker_desc

export
  beacon_desc,
  worker_desc

const
  TraceVersionID* = 20251119

  TraceSetupID* = 1                   ## Phase 1 layout ID, prepare
  TraceRunnerID* = 10                 ## Phase 2 layout ID, full execution

type
  StopIfEosHdl* = proc(trc: TraceRef) {.gcsafe, raises: [].}
    ## Terminate trace if the number of sessions is exhausted

  TraceRef* = ref object of BeaconHandlersSyncRef
    ## Overlay handlers extended by descriptor data
    ctx*: BeaconCtxRef                ## Parent context
    outStream*: Stream                ## Output file with capture records
    backup*: BeaconHandlersRef        ## Can restore previous handlers
    started*: Moment                  ## Start time
    sessions*: int                    ## Initial number of sessions
    remaining*: int                   ## Number of sessions left to run
    stopIfEos*: StopIfEosHdl          ## Auto-disable trace when needed
    serial: uint                      ## Unique record ID

  # -------------

  TraceRecType* = enum
    RecBase = 0
    VersionInfo = 1
    SyncActivated
    SyncHibernated

    SchedDaemonBegin
    SchedDaemonEnd
    SchedStart
    SchedStop
    SchedPool
    SchedPeerBegin
    SchedPeerEnd

    FetchHeaders
    SyncHeaders

    FetchBodies
    SyncBodies

    ImportBlock
    SyncBlock

  TraceHdrUnproc* = object
    ## Optional sub-object for `TraceRecBase`
    hLen*: uint64                     ## # unprocessed header entries
    hChunks*: uint                    ## # unprocessed header iv segments
    hLastNum*: BlockNumber            ## last avail block number
    hLastLen*: uint64                 ## size of last block number interval

  TraceBlkUnproc* = object
    ## Optional sub-object for `TraceRecBase`
    bLen*: uint64                     ## # unprocessed block entries
    bChunks*: uint                    ## # unprocessed block iv segments
    bLeastNum*: BlockNumber           ## least avail block number
    bLeastLen*: uint64                ## size of first interval

  TracePeerCtx* = object
    ## Optional sub-object for `TraceRecBase`
    peerCtrl*: BuddyRunState          ## Sync peer run state
    peerID*: Hash                     ## Sync peer ID (if any)
    nErrors*: BuddyErrors             ## Peer errors

  TraceRecBase* = object of RootObj
    ## Trace context applicable with and without known peer
    time*: Duration                   ## Relative to `TraceRef.started`
    serial*: uint                     ## Capture record ID
    frameID*: Opt[uint]               ## Begin/end frame for scheduler tasks

    nSyncPeers*: uint                 ## Number of sync peers
    syncState*: SyncState             ## Headers/bodies preocessing state
    chainMode*: HeaderChainMode       ## Headers cache/DB state
    poolMode*: bool                   ## Mostly implied by `syncState`
    baseNum*: BlockNumber             ## Max finalised number from `FC` module
    latestNum*: BlockNumber           ## Number of latest branch head
    anteNum*: BlockNumber             ## Lower end of header chain cache

    hdrUnpr*: Opt[TraceHdrUnproc]     ## Optional unprocessed headers state
    blkUnpr*: Opt[TraceBlkUnproc]     ## Optional unprocessed blocks state
    peerCtx*: Opt[TracePeerCtx]       ## Sync peer specific ctx
    slowPeer*: Opt[Hash]              ## Registered slow peer

  TraceVersionInfo* = object of TraceRecBase
    version*: uint
    networkId*: NetworkId

  # -------------

  TraceSyncActivated* = object of TraceRecBase
    head*: Header                     ## Part of environment
    finHash*: Hash32                  ## Part of environment

  TraceSyncHibernated* = object of TraceRecBase

  # -------------

  TraceSchedDaemonBegin* = object of TraceRecBase
    ## Environment is captured before the daemon handler body is executed.

  TraceSchedDaemonEnd* = object of TraceRecBase
    ## Environment is captured when leaving the daemon handler.
    idleTime*: Duration               ## Suggested idle time

  TraceSchedStart* = object of TraceRecBase
    ## Environment is captured when leaving sched the start handler.
    peerIP*: IpAddress                ## Descriptor argument
    peerPort*: Port                   ## Descriptor argument
    accept*: bool                     ## Result/return code

  TraceSchedStop* = object of TraceRecBase
    ## Environment is captured when leaving the sched stop handler.
    peerIP*: IpAddress                ## Descriptor argument
    peerPort*: Port                   ## Descriptor argument

  TraceSchedPool* = object of TraceRecBase
    ## Environment is captured leaving the pool handler.
    peerIP*: IpAddress                ## Descriptor argument
    peerPort*: Port                   ## Descriptor argument
    last*: bool                       ## Request argument
    laps*: uint                       ## Request argument
    stop*: bool                       ## Result/return code

  TraceSchedPeerBegin* = object of TraceRecBase
    ## Environment is captured before the peer handler body is executed.
    peerIP*: IpAddress                ## Descriptor argument
    peerPort*: Port                   ## Ditto
    rank*: PeerRanking                ## Prototype argument

  TraceSchedPeerEnd* = object of TraceRecBase
    ## Environment is captured when leaving peer handler.
    idleTime*: Duration               ## Suggested idle time

  # -------------

  TraceFetchHeaders* = object of TraceRecBase
    ## Environment is captured after the `getBlockHeaders()` handler is run.
    req*: BlockHeadersRequest         ## Fetch request
    ivReq*: BnRange                   ## Request as interval of block numbers
    bn*: BlockNumber                  ## Ditto
    fetched*: Opt[FetchHeadersData]   ## If dowloaded successfully
    error*: Opt[BeaconError]

  TraceSyncHeaders* = object of TraceRecBase
    ## Environment is captured when the `syncBlockHeaders()` handler is run.


  TraceFetchBodies* = object of TraceRecBase
    ## Environment is captured after the `getBlockBodies()` handler is run.
    req*: BlockBodiesRequest          ## Fetch request
    ivReq*: BnRange                   ## Request as interval of block numbers
    fetched*: Opt[FetchBodiesData]    ## If dowloaded successfully
    error*: Opt[BeaconError]

  TraceSyncBodies* = object of TraceRecBase
    ## Environment is captured when the `syncBlockBodies()` handler is run.


  TraceImportBlock* = object of TraceRecBase
    ## Environment is captured after the `importBlock()` handler is run.
    ethBlock*: EthBlock               ## Request argument
    effPeerID*: Hash                  ## Request argument
    elapsed*: Opt[Duration]           ## Processing time on success
    error*: Opt[BeaconError]

  TraceSyncBlock* = object of TraceRecBase
    ## Environment is captured after the `syncImportBlock()` handler is run.

  # -------------

  JTraceRecord*[T] = object
    ## Json writer record format
    kind*: TraceRecType
    bag*: T

const
  TraceTypeLabel* = block:
    var a: array[TraceRecType,string]
    a[TraceRecType(0)] =  "=Oops"
    a[VersionInfo] =      "=Version"
    a[SyncActivated] =    "=Activated"
    a[SyncHibernated] =   "=Suspended"
    a[SchedStart] =       "=StartPeer"
    a[SchedStop] =        "=StopPeer"
    a[SchedPool] =        "=Pool"
    a[SchedDaemonBegin] = "+Daemon"
    a[SchedDaemonEnd] =   "-Daemon"
    a[SchedPeerBegin] =   "+Peer"
    a[SchedPeerEnd] =     "-Peer"
    a[FetchHeaders] =     "=HeadersFetch"
    a[SyncHeaders] =      "=HeadersSync"
    a[FetchBodies] =      "=BodiesFetch"
    a[SyncBodies] =       "=BodiesSync"
    a[ImportBlock] =      "=BlockImport"
    a[SyncBlock] =        "=BlockSync"
    for w in a:
      doAssert 0 < w.len
    a
# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func trace*(ctx: BeaconCtxRef): TraceRef =
  ## Getter, get trace descriptor (if any)
  if ctx.handler.version == TraceRunnerID:
    return ctx.handler.TraceRef

func newSerial*(trc: TraceRef): uint64 =
  trc.serial.inc
  if trc.serial == 0:
    trc.serial.inc
  trc.serial

func toTraceRecType*(T: type): TraceRecType =
  ## Derive capture type from record layout
  when T is TraceVersionInfo:
    VersionInfo
  elif T is TraceSyncActivated:
    SyncActivated
  elif T is TraceSyncHibernated:
    SyncHibernated
  elif T is TraceSchedDaemonBegin:
    SchedDaemonBegin
  elif T is TraceSchedDaemonEnd:
    SchedDaemonEnd
  elif T is TraceSchedStart:
    SchedStart
  elif T is TraceSchedStop:
    SchedStop
  elif T is TraceSchedPool:
    SchedPool
  elif T is TraceSchedPeerBegin:
    SchedPeerBegin
  elif T is TraceSchedPeerEnd:
    SchedPeerEnd
  elif T is TraceFetchHeaders:
    FetchHeaders
  elif T is TraceSyncHeaders:
    SyncHeaders
  elif T is TraceFetchBodies:
    FetchBodies
  elif T is TraceSyncBodies:
    SyncBodies
  elif T is TraceImportBlock:
    ImportBlock
  elif T is TraceSyncBlock:
    SyncBlock
  else:
    {.error: "Unsupported trace capture record type".}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
