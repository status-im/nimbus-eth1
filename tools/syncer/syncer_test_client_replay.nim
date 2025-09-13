# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[cmdline, os, strutils],
  pkg/[chronicles, results],
  ../../execution_chain/config,
  ../../execution_chain/sync/beacon,
  ./helpers/[nimbus_el_wrapper, sync_ticker],
  ./replay/replay_setup

type
  ArgsDigest = tuple
    elArgs: seq[string] # split command line: left to "--" marker
    fileName: string    # capture file name
    noStopQuit: bool    # capture modifier argument
    fakeImport: bool    # ditto
    syncTicker: bool    # ..

let
  cmdName = getAppFilename().extractFilename()

# ------------------------------------------------------------------------------
# Private helpers, command line parsing tools
# ------------------------------------------------------------------------------

proc argsCheck(q: seq[string]): seq[string] =
  if q.len == 0 or
     q[0] == "-h" or
     q[0] == "--help":
    echo "",
      "Usage: ", cmdName,
      " [<execution-layer-args>.. --] <capture-file> [<attributes>..]\n",
      "       Capture file:\n",
      "           Read from trace capture file <capture-file> and replay the\n",
      "           syncer session.",
      "           <capture-file> argument.\n",
      "       Attributes:\n",
      "           noStopQuit    Continue as normal after the captured replay\n",
      "                         states are exhausted. Otherwise the program\n",
      "                         will terminate.\n",
      "           fakeImport    Will not import blocks while replaying\n.",
      "           syncTicker    Log sync state regularly.\n"
    quit(QuitFailure)
  return q

proc argsError(s: string) =
  echo "*** ", cmdName, ": ", s, "\n"
  discard argsCheck(@["-h"]) # usage & quit

# -------------

proc parseCmdLine(): ArgsDigest =
  ## Parse command line:
  ## ::
  ##    [<el-args>.. --] <filename> [noStopQuit] ..
  ##
  var exArgs: seq[string]

  # Split command line by "--" into `exArgs[]` and `elArgs[]`
  let args = commandLineParams().argsCheck()
  for n in 0 ..< args.len:
    if args[n] == "--":
      if 0 < n:
        result.elArgs = args[0 .. n-1]
      if n < args.len:
        exArgs = args[n+1 .. ^1].argsCheck()
      break

  # Case: no <el-options> delimiter "--" given
  if exArgs.len == 0 and result.elArgs.len == 0:
    exArgs = args

  result.fileName = exArgs[0]
  for n in 1 ..< exArgs.len:
    let w = exArgs[n].split('=',2)

    block:
      # noStopQuit
      const token = "noStopQuit"
      if toLowerAscii(w[0]) == toLowerAscii(token):
        if 1 < w.len:
          argsError("Sub-argument has no value: " & token)
        result.noStopQuit = true
        continue

    block:
      # fakeImport
      const token = "fakeImport"
      if toLowerAscii(w[0]) == toLowerAscii(token):
        if 1 < w.len:
          argsError("Sub-argument has no value: " & token)
        result.fakeImport = true
        continue

    block:
      # syncTicker
      const token = "syncTicker"
      if toLowerAscii(w[0]) == toLowerAscii(token):
        if 1 < w.len:
          argsError("Sub-argument has no value: " & token)
        result.syncTicker = true
        continue

    argsError("Sub-argument unknown: " & exArgs[n])

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc beaconSyncConfig(args: ArgsDigest): BeaconSyncConfigHook =
  return proc(desc: BeaconSyncRef) =
    if args.syncTicker:
      desc.ctx.pool.ticker = syncTicker()
    desc.ctx.replaySetup(
               fileName = args.fileName,
               noStopQuit = args.noStopQuit,
               fakeImport = args.fakeImport).isOkOr:
      fatal "Cannot set up replay handlers", error
      quit(QuitFailure)

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

# Pre-parse command line
let argsDigest = parseCmdLine()

# Early plausibility check
if not argsDigest.fileName.fileExists:
  argsError("No such capture file: \"" & argsDigest.fileName & "\"")

# Processing left part command line arguments
let conf = makeConfig(cmdLine = argsDigest.elArgs)

# Run execution client
conf.runNimbusExeClient(argsDigest.beaconSyncConfig)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
