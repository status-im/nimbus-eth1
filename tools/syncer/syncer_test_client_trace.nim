# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
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
            "suspension)"
      defaultValue: 1
      name: "num-trace-sessions" .}: uint

    nPeersMin {.
      desc: "Minimal number of peers needed for activating the first syncer " &
             "session"
      defaultValue: 0
      name: "num-peers-min" .}: uint

    noSyncTicker {.
      desc: "Disable logging sync status regularly"
      defaultValue: false
      name: "disable-sync-ticker" .}: bool

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
    if conf.nSessions == 0 or
       conf.captureFile.isNone:
      return
    desc.ctx.traceSetup(
               fileName = conf.captureFile.unsafeGet.string,
               nSessions = conf.nSessions.int).isOkOr:
      fatal "Cannot set up trace handlers", error
      quit(QuitFailure)

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
    beaconSyncRef: BeaconSyncRef.init rightConf.beaconSyncConfig)

# Run execution client
leftConf.main(nodeConf)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
