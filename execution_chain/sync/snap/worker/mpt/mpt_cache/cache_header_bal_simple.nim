# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Variety of cache DB wrappers with `Opt[]` return codes and error
## logging.

{.push raises: [].}

import
  pkg/[chronicles, eth/common],
  ../../worker_desc,
  ./[cache_desc, cache_header_bal]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template failedToFetch(info, what: static[string]): auto =
  info & ": Failed to fetch " & what & " from cache"

template failedUpdating(info, what: static[string]): auto =
  info & ": Failed updaing " & what & " on cache"

# ------------------------------------------------------------------------------
# Public cache DB wrappers
# ------------------------------------------------------------------------------

proc getHeader*(
    db: CacheDbRef;
    number: BlockNumber;
    info: static[string];
      ): Opt[Header] =
  db.getHeader(number).valueOr:
    error info.failedToFetch "Header", number, `error`=error
    return err()

proc getBlockHash*(
    db: CacheDbRef;
    number: BlockNumber;
    info: static[string];
      ): Opt[Hash32] =
  db.getBlockHash(number).valueOr:
    error info.failedToFetch "block hash", number, `error`=error
    return err()

proc lastHeader*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[Header] =
  db.lastHeader().valueOr:
    let estr = if 0 < error.len: error else: "no headers yet"
    error info.failedToFetch "last Header", `error`=estr
    return err()

proc lastHeaderNumber*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[BlockNumber] =
  db.lastHeaderNumber().valueOr:
    let estr = if 0 < error.len: error else: "no headers yet"
    error info.failedToFetch "last Header number", `error`=estr
    return err()

proc putHeader*(
    db: CacheDbRef;
    header: Header;
    info: static[string];
      ): Opt[void] =
  db.putHeader(header).isOkOr:
    error info.failedUpdating "header", number=header.number, `error`=error
    return err()
  ok()


proc getBal*(
    db: CacheDbRef;
    number: BlockNumber;
    info: static[string];
      ): Opt[BlockAccessListRef] =
  db.getBal(number).valueOr:
    error info.failedToFetch "BAL", number, `error`=error
    return err()

proc lastBalNumber*(
    db: CacheDbRef;
    info: static[string];
      ): Opt[BlockNumber] =
  db.lastBalNumber().valueOr:
    let estr = if 0 < error.len: error else: "no BALs yet"
    error info.failedToFetch "last BAL number", `error`=estr
    return err()

proc putBal*(
    db: CacheDbRef;
    number: BlockNumber;
    bal: BlockAccessListRef;
    info: static[string];
      ): Opt[void] =
  db.putBal(number, bal).isOkOr:
    error info.failedUpdating "BAL", number, nBal=bal[].len, `error`=error
    return err()
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
