# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  stint,
  eth/common/hashes,
  ../aristo as use_ari,
  ./base/base_desc

export stint, hashes

import
  ../aristo/[aristo_desc, aristo_path]

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator slotPairs*(acc: CoreDbTxRef; accPath: Hash32): (seq[byte], UInt256) =
  for (path,data) in acc.aTx.rightPairsStorage accPath:
    yield (pathAsBlob(path), data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
