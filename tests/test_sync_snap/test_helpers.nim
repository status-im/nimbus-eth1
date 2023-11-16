# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
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

type
  KnownStorageFailure* = seq[(string,seq[(int,HexaryError)])]
    ## (<sample-name> & "#" <instance>, @[(<slot-id>, <error-symbol>)), ..])

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

template isImportOk*(rc: Result[SnapAccountsGaps,HexaryError]): bool =
  if rc.isErr:
    check rc.error == NothingSerious # prints an error if different
    false
  elif 0 < rc.value.innerGaps.len:
    check rc.value.innerGaps == seq[NodeSpecs].default
    false
  else:
    true

proc lastTwo*(a: openArray[string]): seq[string] =
  if 1 < a.len: @[a[^2],a[^1]] else: a.toSeq

proc isOK*(rc: ValidationResult): bool =
  rc == ValidationResult.OK

# ------------------------------------------------------------------------------
# Public type conversions
# ------------------------------------------------------------------------------

proc to*(t: NodeTag; T: type Blob): T =
  toSeq(t.UInt256.toBytesBE)

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

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
