# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[cmdline, os, streams, strutils],
  pkg/chronicles,
  pkg/beacon_chain/process_state,
  ./replay/replay_reader

let cmdName = getAppFilename().extractFilename()

# ------------------------------------------------------------------------------
# Private helpers, command line parsing tools
# ------------------------------------------------------------------------------

proc argsCheck(q: seq[string]): seq[string] =
  if q.len == 0 or
     q[0] == "-h" or
     q[0] == "--help":
    echo "",
      "Usage: ", cmdName, " [--] <capture-file>\n",
      "       Capture file:\n",
      "           Read from <capture-file> argument and print its contents."
    quit(QuitFailure)
  q

proc argsError(s: string) =
  echo "*** ", cmdName, ": ", s, "\n"
  discard argsCheck(@["-h"]) # usage & quit

# -------------

proc parseCmdLine(): string =
  var args = commandLineParams().argsCheck
  if args[0] == "--":
    if args.len == 1:
      argsError("Missing capture file argument")
    args = args[1 .. ^1]
  if args.len == 0:
    argsError("Missing capture file argiment")
  if 1 < args.len:
    argsError("Extra arguments: " & args[1 .. ^1].join(" ") & ".")
  return args[0]

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

let name = parseCmdLine()
if not name.fileExists:
  argsError("No such capture file: \"" & name & "\"")

ProcessState.setupStopHandlers()
ProcessState.notifyRunning()

let reader = ReplayReaderRef.init(name.newFileStream fmRead)
reader.captureLog(stop = proc: bool =
  ProcessState.stopIt(notice("Terminating", reason = it)))

quit(QuitSuccess)

# End
