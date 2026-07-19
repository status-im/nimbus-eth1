# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/chronicles,
  ../[mpt, worker_desc]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc sessionPartMptClear*(ctx: SnapCtxRef, info: static[string]): Opt[void] =
  let db = ctx.pool.cacheDB
  db.clearAccPartMpt().isOkOr:
    error info & ": Cannot reset partial accounts MPT", `error`=error
    return err()
  db.clearAccDnglPath().isOkOr:
    error info & ": Cannot reset dangling account paths", `error`=error
    return err()
  db.clearStoPartMpt().isOkOr:
    error info & ": Cannot reset partial slots MPT", `error`=error
    return err()
  db.clearCodePartMpt().isOkOr:
    error info & ": Cannot reset partial receipts table", `error`=error
    return err()
  ok()

proc sessionFlatTabsClear*(ctx: SnapCtxRef,info: static[string]): Opt[void] =
  let db = ctx.pool.cacheDB
  db.clearMissingIntv().isOkOr:
    error info & ": Cannot reset unprocessed accounts/slots", `error`=error
    return err()
  db.clearMissingBlob().isOkOr:
    error info & ": Cannot reset missing contract codes", `error`=error
    return err()
  db.clearFlatAcc().isOkOr:
    error info & ": Cannot reset flat accounts table", `error`=error
    return err()
  db.clearFlatSlot().isOkOr:
    error info & ": Cannot reset flat slots table", `error`=error
    return err()
  db.clearFlatCode().isOkOr:
    error info & ": Cannot reset contract codes table", `error`=error
    return err()
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
