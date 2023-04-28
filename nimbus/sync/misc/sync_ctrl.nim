# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[os, strutils],
  chronicles,
  eth/[common, p2p]

logScope:
  topics = "sync-ctrl"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getDataLine(
    name: string;
    lineNum: int;
      ): string {.gcsafe, raises: [IOError].} =
  if name.fileExists:
    let file = name.open
    defer: file.close
    let linesRead = file.readAll.splitLines
    if lineNum < linesRead.len:
      return linesRead[lineNum].strip

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc syncCtrlBlockNumberFromFile*(
    fileName: Option[string];               # Optional file name
    lineNum = 0;                            # Read line from file
      ): Result[BlockNumber,void] =
  ## Returns a block number from the file name argument `fileName`. The first
  ## line of the file is parsed as a decimal encoded block number.
  if fileName.isSome:
    let file = fileName.get
    try:
      let data = file.getDataLine(lineNum)
      if 0 < data.len:
        let num = parse(data,UInt256)
        return ok(num.toBlockNumber)
    except CatchableError as e:
      let
        name {.used.} = $e.name
        msg {.used.} = e.msg
      debug "Exception while parsing block number", file, name, msg
  err()

proc syncCtrlHashOrBlockNumFromFile*(
    fileName: Option[string];               # Optional file name
    lineNum = 0;                            # Read line from file
      ): Result[HashOrNum,void] =
  ## Returns a block number or a hash from the file name argument `fileName`.
  ## A block number is decimal encoded and a hash is expexted to be a 66 hex
  ## digits string startnib wiyh `0x`.
  if fileName.isSome:
    let file = fileName.get

    # Parse value dump and fetch a header from the peer (if any)
    try:
      let data = file.getDataLine(lineNum)
      if 0 < data.len:
        if 66 == data.len:
          let hash = HashOrNum(
            isHash: true,
            hash:   Hash256(
              data: UInt256.fromHex(data).toBytesBE))
          return ok(hash)
        else:
          let num = HashOrNum(
            isHash: false,
            number: parse(data,UInt256))
          return ok(num)
    except CatchableError as e:
      let
        name {.used.} = $e.name
        msg {.used.} = e.msg
      debug "Exception while parsing hash or block number", file, name, msg
  err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
