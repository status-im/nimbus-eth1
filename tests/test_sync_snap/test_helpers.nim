# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/times,
  eth/common,
  stew/[interval_set, results],
  unittest2,
  ../../nimbus/sync/snap/range_desc,
  ../../nimbus/sync/snap/worker/db/hexary_error,
  ../../nimbus/sync/snap/worker/db/[hexary_desc, snapdb_accounts],
  ../replay/pp

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc isImportOk*(rc: Result[SnapAccountsGaps,HexaryError]): bool =
  if rc.isErr:
    check rc.error == NothingSerious # prints an error if different
  elif 0 < rc.value.innerGaps.len:
    check rc.value.innerGaps == seq[NodeSpecs].default
  else:
    return true

proc lastTwo*(a: openArray[string]): seq[string] =
  if 1 < a.len: @[a[^2],a[^1]] else: a.toSeq

# ------------------------------------------------------------------------------
# Public type conversions
# ------------------------------------------------------------------------------

proc to*(b: openArray[byte]; T: type ByteArray32): T =
  ## Convert to other representation (or exception)
  if b.len == 32:
    (addr result[0]).copyMem(unsafeAddr b[0], 32)
  else:
    doAssert b.len == 32

proc to*(b: openArray[byte]; T: type ByteArray33): T =
  ## Convert to other representation (or exception)
  if b.len == 33:
    (addr result[0]).copyMem(unsafeAddr b[0], 33)
  else:
    doAssert b.len == 33

proc to*(b: ByteArray32|ByteArray33; T: type Blob): T =
  b.toSeq

proc to*(b: openArray[byte]; T: type NodeTag): T =
  ## Convert from serialised equivalent
  UInt256.fromBytesBE(b).T

proc to*(w: (byte, NodeTag); T: type Blob): T =
  let (b,t) = w
  @[b] & toSeq(t.UInt256.toBytesBE)

proc to*(t: NodeTag; T: type Blob): T =
  toSeq(t.UInt256.toBytesBE)

# ----------

proc convertTo*(key: RepairKey; T: type NodeKey): T =
  ## Might be lossy, check before use (if at all, unless debugging)
  (addr result.ByteArray32[0]).copyMem(unsafeAddr key.ByteArray33[1], 32)

# ------------------------------------------------------------------------------
# Public functions, pretty printing
# ------------------------------------------------------------------------------

proc pp*(rc: Result[Account,HexaryError]): string =
  if rc.isErr: $rc.error else: rc.value.pp

proc pp*(a: NodeKey; collapse = true): string =
  a.to(Hash256).pp(collapse)

proc pp*(d: Duration): string =
  if 40 < d.inSeconds:
    d.ppMins
  elif 200 < d.inMilliseconds:
    d.ppSecs
  elif 200 < d.inMicroseconds:
    d.ppMs
  else:
    d.ppUs

proc ppKvPc*(w: openArray[(string,int)]): string =
  w.mapIt(&"{it[0]}={it[1]}%").join(", ")

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

# ------------------------------------------------------------------------------
# Public free parking
# ------------------------------------------------------------------------------

proc rangeAccountSizeMax*(n: int): int =
  ## Max number of bytes needed to store `n` RLP encoded `Account()` type
  ## entries. Note that this is an upper bound.
  ##
  ## The maximum size of a single RLP encoded account item can be determined
  ## by setting every field of `Account()` to `high()` or `0xff`.
  if 127 < n:
    3 + n * 110
  elif 0 < n:
    2 + n * 110
  else:
    1

proc rangeNumAccounts*(size: int): int =
  ## ..
  (size - 3) div 110

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
