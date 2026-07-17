# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## File IO for debugging and testing purposes, only.

{.push raises: [].}

{.used.}

import
  std/[streams, syncio],
  pkg/[eth/common, stew/byteutils, zlib],
  ../../../wire_protocol/snap/snap_types,
  ../state_db,
  ./mpt_desc

export
  GUnzipRef

type
  AccountRangeData* = tuple
    root: StateRoot
    start: ItemKey
    pck: AccountRangePacket
    error: string
    lnr: int

  StoreSlotRangeData* = tuple
    root: StoreRoot
    start: ItemKey
    pck: StorageRangesPacket                        # always has `pkg.len == 1`
    error: string
    lnr: int

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template rangeFromFile[T: AccountRangePacket|StorageRangesPacket](
    fd: var File;
    fPath: string;
    lnr: int;
      ): untyped =
  when T is AccountRangePacket:
    type U = StateRoot
    type R = AccountRangeData
  elif T is StorageRangesPacket:
    type U = StoreRoot
    type R = StoreSlotRangeData

  var blockRc: R
  block body:
    if fd.isNil and not fd.open(fPath, fmRead):
      blockRc.error = "Cannot open file \"" & fPath & "\" for reading"
      break body

    blockRc.lnr = lnr
    try:
      var line = ""

      while line.len == 0 or line[0] == '#':
        if fd.endOfFile:
          blockRc.error = "End of file"
          break body
        blockRc.lnr.inc
        line = fd.readLine
      blockRc.root = U(Hash32.fromHex line)

      blockRc.lnr.inc
      line = fd.readLine
      if line.len == 0:
        blockRc.error = "Missing line: Hash32 value"
        break body
      blockRc.start = (Hash32.fromHex line).to(ItemKey)

      blockRc.lnr.inc
      line = fd.readLine
      if line.len == 0:
        blockRc.error = "Missing line: data packet value"
        break body
      blockRc.pck = rlp.decode(line.hexToSeqByte, T)

    except IOError as e:
      blockRc.error = $e.name & "(" & e.msg & ")"
    except ValueError as e:
      blockRc.error = $e.name & "(" & e.msg & ")"
    except RlpError as e:
      blockRc.error = $e.name & "(" & e.msg & ")"

  blockRc

template rangeFromUnzip[T: AccountRangePacket|StorageRangesPacket](
    gz: GUnzipRef;
    lnr: int;
      ): untyped =
  when T is AccountRangePacket:
    type U = StateRoot
    type R = AccountRangeData
  elif T is StorageRangesPacket:
    type U = StoreRoot
    type R = StoreSlotRangeData

  var blockRc: R
  block body:
    blockRc.lnr = lnr
    try:
      var line = ""

      while line.len == 0 or line[0] == '#':
        if gz.atEnd:
          blockRc.error = "End of file"
          break body
        blockRc.lnr.inc
        line = gz.nextLine.valueOr:
          blockRc.error = "Read error: " & $error
          break body
      blockRc.root = U(Hash32.fromHex line)

      blockRc.lnr.inc
      line = gz.nextLine.valueOr:
        blockRc.error = "Read error: " & $error
        break body
      if line.len == 0:
        blockRc.error = "Missing line: Hash32 value"
        break body
      blockRc.start = (Hash32.fromHex line).to(ItemKey)

      blockRc.lnr.inc
      line =  gz.nextLine.valueOr:
        blockRc.error = "Read error: " & $error
        break body
      if line.len == 0:
        blockRc.error = "Missing line:data packet value"
        break body
      blockRc.pck = rlp.decode(line.hexToSeqByte, T)

    except OSError as e:
      blockRc.error = $e.name & "(" & e.msg & ")"
    except IOError as e:
      blockRc.error = $e.name & "(" & e.msg & ")"
    except ValueError as e:
      blockRc.error = $e.name & "(" & e.msg & ")"
    except RlpError as e:
      blockRc.error = $e.name & "(" & e.msg & ")"

  blockRc

# ------------------------------------------------------------------------------
# Public serialisation functions
# ------------------------------------------------------------------------------

proc dumpToFile*[T: AccountRangePacket|StorageRangesPacket](
    fPath: string;
    root: StateRoot|StoreRoot;
    start: ItemKey;
    pck: T;
      ): bool =
  when root is StateRoot and T isnot AccountRangePacket:
    {.error: "Leafs item must be of type AccountRangePacket" &
             " for root type StateRoot".}
  elif root is StoreRoot and T isnot StorageRangesPacket:
    {.error: "Leafs item must be of type StorageRangesPacket" &
             " for root type StoreRoot".}
  let s =
    $root.to(Hash32) & "\n" &
    $start.to(Hash32) & "\n" &
    rlp.encode(pck).toHex & "\n" &
    "\n"
  try:
    var fd: File
    if fd.open(fPath, fmAppend):
      fd.write s
      fd.close()
      return true
  except IOError:
    discard
  # false

proc dumpToFile*(
    fPath: string;
    root: StateRoot;
    start: ItemKey;
    data: openArray[SnapAccount];
    proof: openArray[ProofNode]
      ): bool =
  fPath.dumpToFile(
    root, start, AccountRangePacket(accounts: @data, proof: @proof))

proc dumpToFile*(
    fPath: string;
    root: StoreRoot;
    start: ItemKey;
    data: openArray[StorageItem];
    proof: openArray[ProofNode]
      ): bool =
  fPath.dumpToFile(
    root, start, StorageRangesPacket(slots: @[@data], proof: @proof))


proc accountRangeFromFile*(
    fd: var File;
    fPath: string;
    lnr = 0;
      ): AccountRangeData =
  rangeFromFile[AccountRangePacket](fd, fPath, lnr)

proc storeSlotRangeFromFile*(
    fd: var File;
    fPath: string;
    lnr = 0;
      ): StoreSlotRangeData =
  rangeFromFile[StorageRangesPacket](fd, fPath, lnr)


proc accountRangeFromUnzip*(gz: GUnzipRef; lnr = 0): AccountRangeData =
  rangeFromUnzip[AccountRangePacket](gz, lnr)

proc storeSlotRangeFromUnzip*(gz: GUnzipRef; lnr = 0): StoreSlotRangeData =
  rangeFromUnzip[StorageRangesPacket](gz, lnr)


proc initUnzip*(fPath: string): Result[(Stream,GUnzipRef),string] =
  var (stm,gz) = (Stream(nil),GUnzipRef(nil))
  stm = fPath.newFileStream fmRead
  if stm.isNil:
    return err("Cannot open \"" & fPath & "\" for reading")
  try:
    gz = GUnzipRef.init(stm).valueOr:
      stm.close()
      return err("Cannot initialise unzip for \"" & fPath & "\": " & $error)
  except IOError as e:
    return err($e.name & "(" & e.msg & ")")
  except OSError as e:
    return err($e.name & "(" & e.msg & ")")
  ok((stm,gz))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
