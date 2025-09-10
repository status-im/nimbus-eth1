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
  TraceVersionID* = 20250915

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
    TrtRecBase = 0
    TrtVersionInfo = 1

    TrtSyncActvFailed
    TrtSyncActivated
    TrtSyncHibernated

    TrtSchedDaemonBegin
    TrtSchedDaemonEnd
    TrtSchedStart
    TrtSchedStop
    TrtSchedPool
    TrtSchedPeerBegin
    TrtSchedPeerEnd

    TrtFetchHeaders
    TrtSyncHeaders

    TrtFetchBodies
    TrtSyncBodies

    TrtImportBlock
    TrtSyncBlock

  TraceRecBase* = object of RootObj
    ## Trace context applicable with and without known peer
    time*: Duration                   ## Relative to `TraceRef.started`
    serial*: uint                     ## Increasing serial number
    frameID*: uint                    ## Begin/end frame
    nPeers*: uint
    syncState*: SyncState
    chainMode*: HeaderChainMode
    poolMode*: bool

    baseNum*: BlockNumber             ## Max finalised number from `FC` module
    latestNum*: BlockNumber           ## Number of latest branch head
    antecedent*: BlockNumber          ## Lower end of header chain cache

    hdrUnprLen*: uint64               ## # unprocessed header entries
    hdrUnprChunks*: uint              ## # unprocessed header iv segments
    hdrUnprLast*: BlockNumber         ## last avail block number
    hdrUnprLastLen*: uint64           ## size of last block number interval

    blkUnprLen*: uint64               ## # unprocessed block entries
    blkUnprChunks*: uint              ## # unprocessed block iv segments
    blkUnprLeast*: BlockNumber        ## least avail block number
    blkUnprLeastLen*: uint64          ## size of first interval

    stateAvail*: int                  ## Bitmask: 1=peerCtrl, 2=peerID, etc.
    peerCtrl*: BuddyRunState          ##  1) Rlp encoded `Opt[seq[xxx]]` would
    peerID*: Hash                     ##  2) .. need manual decoder/reader
    nHdrErrors*: uint8                ##  4) # header comm. errors
    nBlkErrors*: uint8                ##  8) # body comm. errors
    slowPeer*: Hash                   ## 16) Registered slow peer

  TraceVersionInfo* = object of TraceRecBase
    version*: uint
    networkId*: NetworkId

  # -------------

  TraceSyncActvFailed* = object of TraceRecBase

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
    peerPort*: Port                   ## Descriptor argument

  TraceSchedPeerEnd* = object of TraceRecBase
    ## Environment is captured when leaving peer handler.
    idleTime*: Duration               ## Suggested idle time

  # -------------

  TraceFetchHeaders* = object of TraceRecBase
    ## Environment is captured after the `getBlockHeaders()` handler is run.
    req*: BlockHeadersRequest         ## Fetch request
    ivReq*: BnRange                   ## Request as interval of block numbers
    fieldAvail*: uint                 ## Bitmask: 1=fetched, 2=error
    fetched*: FetchHeadersData        ## If dowloaded successfully
    error*: BeaconError

  TraceSyncHeaders* = object of TraceRecBase
    ## Environment is captured when the `syncBlockHeaders()` handler is run.


  TraceFetchBodies* = object of TraceRecBase
    ## Environment is captured after the `getBlockBodies()` handler is run.
    req*: BlockBodiesRequest          ## Fetch request
    ivReq*: BnRange                   ## Request as interval of block numbers
    fieldAvail*: uint                 ## Bitmask: 1=fetchd, 2=error
    fetched*: FetchBodiesData         ## If dowloaded successfully
    error*: BeaconError

  TraceSyncBodies* = object of TraceRecBase
    ## Environment is captured when the `syncBlockBodies()` handler is run.


  TraceImportBlock* = object of TraceRecBase
    ## Environment is captured after the `importBlock()` handler is run.
    ethBlock*: EthBlock               ## Request argument
    effPeerID*: Hash                  ## Request argument
    fieldAvail*: uint                 ## Bitmask: 1=elapsed, 2=error
    elapsed*: Duration                ## Processing time on success
    error*: BeaconError

  TraceSyncBlock* = object of TraceRecBase
    ## Environment is captured after the `syncImportBlock()` handler is run.

  # -------------

  JTraceRecord*[T] = object
    ## Json writer record format
    kind*: TraceRecType
    bag*: T

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
    TrtVersionInfo
  elif T is TraceSyncActvFailed:
    TrtSyncActvFailed
  elif T is TraceSyncActivated:
    TrtSyncActivated
  elif T is TraceSyncHibernated:
    TrtSyncHibernated
  elif T is TraceSchedDaemonBegin:
    TrtSchedDaemonBegin
  elif T is TraceSchedDaemonEnd:
    TrtSchedDaemonEnd
  elif T is TraceSchedStart:
    TrtSchedStart
  elif T is TraceSchedStop:
    TrtSchedStop
  elif T is TraceSchedPool:
    TrtSchedPool
  elif T is TraceSchedPeerBegin:
    TrtSchedPeerBegin
  elif T is TraceSchedPeerEnd:
    TrtSchedPeerEnd
  elif T is TraceFetchHeaders:
    TrtFetchHeaders
  elif T is TraceSyncHeaders:
    TrtSyncHeaders
  elif T is TraceFetchBodies:
    TrtFetchBodies
  elif T is TraceSyncBodies:
    TrtSyncBodies
  elif T is TraceImportBlock:
    TrtImportBlock
  elif T is TraceSyncBlock:
    TrtSyncBlock
  else:
    {.error: "Unsupported trace capture record type".}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
