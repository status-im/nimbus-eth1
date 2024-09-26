# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Policy driven read-only database wrapper
## ========================================
##
## It lives on the edge and pretends to be agnostic of a particular
## backend implementation.
##
{.push raises: [].}

import
  pkg/eth/common,
  pkg/results,
  edge_db/[
    db_desc,
    init_era1_coredb,
  ]

export
  EdgeDbColumn,
  EdgeDbError,
  EdgeDbRef,
  init

proc get*(
    edg: EdgeDbRef;
    col: EdgeDbColumn;
    key: uint64;
      ): Result[Blob,EdgeDbError] =
  edg.uintGetPolFn(edg, col, key)

proc get*(
    edg: EdgeDbRef;
    col: EdgeDbColumn;
    key: openArray[byte];
      ): Result[Blob,EdgeDbError] =
  edg.blobGetPolFn(edg, col, key)

# End
