# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[cmdline, os, streams, strutils, terminal],
  pkg/[chronicles, confutils],
  pkg/beacon_chain/process_state,
  ./replay/replay_reader

const
  fgSection = fgYellow

type
  ToolConfig* = object of RootObj
    captureFile {.
      separator: "INSPECT TOOL OPTIONS:"
      desc: "Read from <capture-file> argument and print its contents"
      name: "capture-file" .}: InputFile

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

let
  config = ToolConfig.load(
    cmdLine = commandLineParams(),
    copyrightBanner = ansiForegroundColorCode(fgSection) &
      "\pNimbus capture file inspection tool.\p")
  name = config.captureFile.string

if not name.fileExists:
  fatal "No such capture file", name
  quit(QuitFailure)

ProcessState.setupStopHandlers()
ProcessState.notifyRunning()

let reader = ReplayReaderRef.init(name.newFileStream fmRead)
reader.captureLog(stop = proc: bool =
  ProcessState.stopIt(notice("Terminating", reason = it)))

quit(QuitSuccess)

# End
