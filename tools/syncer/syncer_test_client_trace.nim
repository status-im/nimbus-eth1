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
  ./trace/trace_setup

type
  ArgsDigest = tuple
    elArgs: seq[string] # split command line: left to "--" marker
    fileName: string    # capture file name
    nSessions: int      # capture modifier argument
    nPeersMin: int      # ditto
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
      "           Run a trace session and store captured states in the\n",
      "           <capture-file> argument.\n",
      "       Attributes:\n",
      "           nSessions=[0-9]+  Run a trace for this many sessions (i.e. from\n",
      "                             activation to suspension). If set to 0, the\n",
      "                             <capture-file> is ignored and will not be written.\n",
      "                             However, other modifiers still have effcet.\n",
      "           nPeersMin=[0-9]+  Minimal number of peers needed for activating\n",
      "                             the first syncer session.\n",
      "           syncTicker        Log sync state regularly.\n"
    quit(QuitFailure)
  return q

proc argsError(s: string) =
  echo "*** ", cmdName, ": ", s, "\n"
  discard argsCheck(@["-h"]) # usage & quit

# -------------

proc parseCmdLine(): ArgsDigest =
  ## Parse command line:
  ## ::
  ##    [<el-args>.. --] <filename> [nSessions=[0-9]+] ..
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
  result.nSessions = -1
  result.nPeersMin = -1
  for n in 1 ..< exArgs.len:
    let w = exArgs[n].split('=',2)

    block:
      # nSessions=[0-9]+
      const token = "nSessions"
      if toLowerAscii(w[0]) == toLowerAscii(token):
        if w.len < 2:
          argsError("Sub-argument incomplete: " & token & "=[0-9]+")
        try:
          result.nSessions = int(w[1].parseBiggestUInt)
        except ValueError as e:
          argsError("Sub-argument value error: " & token & "=[0-9]+" &
                    ", error=" & e.msg)
        continue

    block:
      # nPeersMin=[0-9]+
      const token = "nPeersMin"
      if toLowerAscii(w[0]) == toLowerAscii(token):
        if w.len < 2:
          argsError("Sub-argument incomplete: " & token & "=[0-9]+")
        try:
          result.nPeersMin = int(w[1].parseBiggestUInt)
        except ValueError as e:
          argsError("Sub-argument value error: " & token & "=[0-9]+" &
                    ", error=" & e.msg)
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
    if 1 < args.nPeersMin:
      desc.ctx.pool.minInitBuddies = args.nPeersMin
    if args.nSessions == 0:
      return
    desc.ctx.traceSetup(
               fileName = args.fileName,
               nSessions = max(0, args.nSessions)).isOkOr:
      fatal "Cannot set up trace handlers", error
      quit(QuitFailure)

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

# Pre-parse command line
let argsDigest = parseCmdLine()

# Early plausibility check
if argsDigest.fileName.fileExists:
  argsError("Must not overwrite file: \"" & argsDigest.fileName & "\"")

# Processing left part command line arguments
let conf = makeConfig(cmdLine = argsDigest.elArgs)

# Run execution client
conf.runNimbusExeClient(argsDigest.beaconSyncConfig)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
