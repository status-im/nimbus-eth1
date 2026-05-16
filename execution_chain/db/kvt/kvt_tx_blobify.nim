# nimbus-eth1
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## KVT -- transaction frame serialisation
## =======================================
##
## Serialises the pending key-value delta of a `KvtTxRef` (its `sTab`) to a
## flat byte sequence for database storage and restoration.
##
## Wire format (all multi-byte integers big-endian):
##
##   version      : 1 byte = 0x01
##   sTab_count   : 4 bytes
##   per entry    :
##     key_len    : 2 bytes
##     key        : key_len bytes
##     val_len    : 4 bytes
##     val        : val_len bytes

{.push raises: [].}

import
  std/tables,
  stew/endians2,
  results,
  ./[kvt_desc]

export results

const
  KVT_TX_FRAME_VERSION = 0x01'u8

  MaxInitTableHint = 1 shl 16
    ## Cap for untrusted-count → `initTable` capacity hints.  See `tableHint`.

template tableHint(count: uint32): int =
  ## Bound the capacity passed to `initTable` when `count` is read from an
  ## untrusted blob.  Avoids the `int(uint32)` sign-flip on 32-bit platforms
  ## (which would feed a negative `Natural` to `initTable` and raise
  ## `RangeDefect`) and prevents a hostile blob from forcing a multi-billion
  ## bucket pre-allocation on any platform.  Realistic per-frame deltas are
  ## a few thousand entries — orders of magnitude below the cap.  The
  ## per-entry parse loop catches any actual data truncation, so
  ## under-allocating buckets is purely a performance hint.
  int(min(count, MaxInitTableHint.uint32))

# ------------------------------------------------------------------------------
# Public: serialise
# ------------------------------------------------------------------------------

proc blobifyKvtTxFrame*(tx: KvtTxRef): seq[byte] =
  var buf: seq[byte]
  buf.add KVT_TX_FRAME_VERSION
  buf.add tx.sTab.len.uint32.toBytesBE
  for k, v in tx.sTab:
    buf.add k.len.uint16.toBytesBE
    buf.add k
    buf.add v.len.uint32.toBytesBE
    buf.add v
  buf

# ------------------------------------------------------------------------------
# Public: deserialise
# ------------------------------------------------------------------------------

proc deblobifyKvtTxFrame*(
    data: openArray[byte]
): Result[Table[seq[byte], seq[byte]], KvtError] =
  if data.len < 5:
    return err(DataInvalid)
  if data[0] != KVT_TX_FRAME_VERSION:
    return err(DataInvalid)

  var pos = 1
  let count = uint32.fromBytesBE(data.toOpenArray(1, 4))
  pos = 5

  var sTab = initTable[seq[byte], seq[byte]](tableHint(count))

  for _ in 0 ..< count:
    if pos + 1 >= data.len:
      return err(DataInvalid)
    let kLen = int(uint16.fromBytesBE(data.toOpenArray(pos, pos + 1)))
    pos += 2
    if pos + kLen - 1 >= data.len:
      return err(DataInvalid)
    let k = @(data.toOpenArray(pos, pos + kLen - 1))
    pos += kLen

    if pos + 3 >= data.len:
      return err(DataInvalid)
    let vLen = int(uint32.fromBytesBE(data.toOpenArray(pos, pos + 3)))
    pos += 4
    if pos + vLen - 1 >= data.len:
      return err(DataInvalid)
    let v = @(data.toOpenArray(pos, pos + vLen - 1))
    pos += vLen

    sTab[k] = v

  ok sTab

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
