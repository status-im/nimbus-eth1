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

proc getBal*(
    db: CacheDbRef;
    number: BlockNumber;
    info: static[string];
      ): Opt[BlockAccessListRef] =
  db.getBal(number).valueOr:
    error info.failedToFetch "BAL", number, `error`=error
    return err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
