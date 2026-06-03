# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Debug/benchmark only: a flat-file sidecar for block access lists.
##
## Block access lists (BALs, EIP-7928) only exist from the Amsterdam fork
## onwards, but it is useful to benchmark the BAL state prefetch against
## historical pre-Amsterdam import data. This sidecar lets a generation run
## write the BALs produced by the tracker to a file (keyed by block number),
## and a later benchmark run read them back and feed them into block processing
## so the prefetch has something to prefetch.
##
## The file is a simple sequence of records written in increasing block-number
## order:
##
##   [blockNumber: uint64 LE][balLen: uint32 LE][bal: balLen bytes of RLP]
##
## The reader streams the file in lockstep with the (linear) import, keeping a
## single record of lookahead so it uses O(1) memory regardless of range size.

{.push raises: [], gcsafe.}

import
  results,
  stew/endians2,
  eth/common/[block_access_lists, block_access_lists_rlp]

export results, block_access_lists

type
  BalSidecarWriter* = object
    file: File

  BalSidecarReader* = object
    file: File
    haveNext: bool
    atEof: bool
    nextNumber: uint64
    nextBytes: seq[byte]

const recordHeaderLen = 12 # uint64 block number + uint32 payload length

# ------------------------------------------------------------------------------
# Writer
# ------------------------------------------------------------------------------

proc openBalSidecarWriter*(path: string): Result[BalSidecarWriter, string] =
  var f: File
  if not open(f, path, fmWrite):
    return err("bal sidecar: could not open '" & path & "' for writing")
  ok(BalSidecarWriter(file: f))

proc writeBal*(
    w: var BalSidecarWriter, number: uint64, bal: BlockAccessListRef
): Result[void, string] =
  let payload = bal[].encode()

  var rec = newSeqOfCap[byte](recordHeaderLen + payload.len)
  rec.add(number.toBytesLE())
  rec.add(uint32(payload.len).toBytesLE())
  rec.add(payload)

  try:
    if w.file.writeBuffer(addr rec[0], rec.len) != rec.len:
      return err("bal sidecar: short write for block " & $number)
    ok()
  except IOError as e:
    err("bal sidecar: write failed for block " & $number & ": " & e.msg)

proc close*(w: var BalSidecarWriter) =
  if w.file != nil:
    w.file.flushFile()
    w.file.close()
    w.file = nil

# ------------------------------------------------------------------------------
# Reader
# ------------------------------------------------------------------------------

proc openBalSidecarReader*(path: string): Result[BalSidecarReader, string] =
  var f: File
  if not open(f, path, fmRead):
    return err("bal sidecar: could not open '" & path & "' for reading")
  ok(BalSidecarReader(file: f))

proc fillNext(r: var BalSidecarReader): Result[void, string] =
  ## Buffer the next record, if any, into the lookahead slot.
  if r.haveNext or r.atEof:
    return ok()

  var hdr: array[recordHeaderLen, byte]
  try:
    let n = r.file.readBuffer(addr hdr[0], recordHeaderLen)
    if n == 0:
      r.atEof = true
      return ok()
    if n != recordHeaderLen:
      return err("bal sidecar: truncated record header")

    let payloadLen = int(uint32.fromBytesLE(hdr.toOpenArray(8, 11)))
    var payload = newSeq[byte](payloadLen)
    if payloadLen > 0 and r.file.readBuffer(addr payload[0], payloadLen) != payloadLen:
      return err("bal sidecar: truncated record payload")

    r.nextNumber = uint64.fromBytesLE(hdr.toOpenArray(0, 7))
    r.nextBytes = move(payload)
    r.haveNext = true
    ok()
  except IOError as e:
    err("bal sidecar: read failed: " & e.msg)

proc readBal*(
    r: var BalSidecarReader, number: uint64
): Result[Opt[BlockAccessListRef], string] =
  ## Return the BAL for `number`, skipping past any earlier records. Returns
  ## `none` if the file has no record for that block (gap or EOF). Assumes
  ## records are stored in increasing block-number order.
  while true:
    ?r.fillNext()
    if r.atEof or r.nextNumber > number:
      return ok(Opt.none(BlockAccessListRef))
    if r.nextNumber < number:
      r.haveNext = false # stale record, drop it and keep scanning
      continue

    let bal = new BlockAccessList
    bal[] = BlockAccessList.decode(r.nextBytes).valueOr:
      return err("bal sidecar: decode failed for block " & $number & ": " & error)
    r.haveNext = false
    return ok(Opt.some(bal))

proc close*(r: var BalSidecarReader) =
  if r.file != nil:
    r.file.close()
    r.file = nil
