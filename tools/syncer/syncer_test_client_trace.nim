# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[cmdline, os, strutils, terminal],
  pkg/[chronicles, confutils, results],
  ../../execution_chain/[conf, nimbus_desc, nimbus_execution_client],
  ../../execution_chain/sync/beacon,
  ./helpers/sync_ticker,
  ./trace/trace_setup

const
  fgSection = fgYellow
  fgOption = fgBlue

type
  ToolConfig* = object of RootObj
    captureFile {.
      separator: "TRACE TOOL OPTIONS:"
      desc: "Store captured states in the <capture-file> argument. If this " &
            "option is missing, no capture file is written"
      name: "capture-file" .}: Option[OutFile]

    nSessions {.
      desc: "Run a trace for this many sessions (i.e. from activation to " &
            "suspension) rather than a single one"
      name: "num-trace-sessions" .}: Option[uint16]

    nPeersMin {.
      desc: "Minimal number of peers needed for activating the first syncer " &
             "session"
      defaultValue: 0
      name: "num-peers-min" .}: uint16

    noSyncTicker {.
      desc: "Disable logging sync status regularly"
      defaultValue: false
      name: "disable-sync-ticker" .}: bool

    snapSyncTarget {.
      desc: "Manually set the initial block hash to derive the sync target" &
            " state root from. The block hash is specified its 32 byte" &
            " hash represented by a hex string"
      name: "snap-sync-target" .}: Option[string]

    snapSyncUpdateFile {.
      desc: "Provide a file that contains the block hash or block number" &
            " to derive the current state root from. This file might not" &
            " exist yet and can be updated over time to direct to a new" &
            " state root for a block with increased height/number"
      name: "snap-sync-update-file" .}: Option[string]

  SplitCmdLine = tuple
    leftArgs: seq[string]  # split command line: left to "--" marker (nimbus)
    rightArgs: seq[string] # split command line: right to "--" marker (tool)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc splitCmdLine(): SplitCmdLine =
  ## Split commans line options
  ## ::
  ##   [<nimbus-options> --] [<tool-options]
  ##
  let args = commandLineParams()
  for n in 0 ..< args.len:
    if args[n] == "--":
      if 0 < n:
        result.leftArgs = args[0 .. n-1]
      if n < args.len:
        result.rightArgs = args[n+1 .. ^1]
      return
  result.rightArgs = args


proc beaconSyncConfig(conf: ToolConfig): BeaconSyncConfigHook =
  return proc(desc: BeaconSyncRef) =
    if not conf.noSyncTicker:
      desc.ctx.pool.ticker = syncTicker()
    if 1 < conf.nPeersMin:
      desc.ctx.pool.minInitBuddies = conf.nPeersMin.int
    var nSessions = 1
    if conf.nSessions.isSome():
      nSessions = conf.nSessions.unsafeGet.int
      if nSessions == 0:
        return
      if conf.captureFile.isNone():
        fatal "Capture file missing for explicit mumber of sessions", nSessions
        quit QuitFailure
    elif conf.captureFile.isNone():
      return
    desc.ctx.traceSetup(
               fileName = conf.captureFile.unsafeGet.string,
               nSessions = nSessions).isOkOr:
      fatal "Cannot set up trace handlers", error
      quit(QuitFailure)

proc snapSyncConfig(conf: ToolConfig): SnapSyncConfigHook =
  return proc(desc: SnapSyncRef) =
    if conf.snapSyncTarget.isSome():
      let hash32 = conf.snapSyncTarget.unsafeGet
      if not desc.configTarget(hash32):
        fatal "Error parsing hash32 argument for --snap-sync-target", hash32
        quit QuitFailure
    if conf.snapSyncUpdateFile.isSome():
      let fileName = conf.snapSyncUpdateFile.unsafeGet
      if not desc.configUpdateFile(fileName):
        fatal "Error parsing file name for --snap-sync-update-file", fileName
        quit QuitFailure

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

let
  (leftOpts, rightOpts) = splitCmdLine()

  rightConf = ToolConfig.load(
    cmdLine = rightOpts,
    copyrightBanner = ansiForegroundColorCode(fgSection) &
      "\pNimbus execution layer with trace extension.\p" &
      "Extended command line options:\p" &
      ansiForegroundColorCode(fgOption) &
      "  [<nimbus-options> --] [<tool-options>]")

  leftConf = makeConfig(cmdLine = leftOpts)

  # Update node config for lazy beacon sync update
  nodeConf = NimbusNode(
    beaconSyncRef: BeaconSyncRef.init rightConf.beaconSyncConfig,
    snapSyncRef:   SnapSyncRef.init rightConf.snapSyncConfig)

# Run execution client
leftConf.main(nodeConf)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
