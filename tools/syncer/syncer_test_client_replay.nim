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
  pkg/[chronicles, results],
  ../../execution_chain/[conf, nimbus_desc, nimbus_execution_client],
  ../../execution_chain/sync/beacon,
  ./helpers/sync_ticker,
  ./replay/replay_setup

const
  fgSection = fgYellow
  fgOption = fgBlue

type
  ToolConfig* = object of RootObj
    captureFile {.
      separator: "REPLAY TOOL OPTIONS:"
      desc: "Read from trace capture file <capture-file> and replay the " &
            " syncer session"
      name: "capture-file" .}: InputFile

    syncFailTimeout {.
      desc: "Maximal time in seconds waiting for internal event to happen," &
            " e.g. waiting for block fetch or import to complete. This" &
            " timeout should cover the maximum time needed to import a block"
      defaultValue: 50
      name: "sync-fail-timeout" .}: uint

    noStopQuit {.
      desc: "Continue as normal after the captured replay states are " &
            "exhausted. If the option is given, the program will terminate"
      defaultValue: false
      name: "no-stop-quit" .}: bool

    fakeImport {.
      desc: "The tool will not import blocks while replaying"
      defaultValue: false
      name: "enable-sync-ticker" .}: bool

    noSyncTicker {.
      desc: "Disable logging sync status regularly"
      defaultValue: false
      name: "disable-sync-ticker" .}: bool

  SplitCmdLine = tuple
    leftArgs: seq[string]  # split command line: left to "--" marker (nimbus)
    rightArgs: seq[string] # split command line: right to "--" marker (tool)

# ------------------------------------------------------------------------------
# Private helpers, command line parsing tools
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
    desc.ctx.replaySetup(
      fileName = conf.captureFile.string,
      failTimeout = min(conf.syncFailTimeout,high(int).uint).int,
      noStopQuit = conf.noStopQuit,
      fakeImport = conf.fakeImport).isOkOr:
        fatal "Cannot set up replay handlers", error
        quit(QuitFailure)

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

let
  (leftOpts, rightOpts) = splitCmdLine()

  rightConf = ToolConfig.load(
    cmdLine = rightOpts,
    copyrightBanner = ansiForegroundColorCode(fgSection) &
      "\pNimbus execution layer with replay extension.\p" &
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
