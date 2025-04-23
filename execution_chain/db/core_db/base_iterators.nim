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
  ../aristo/[aristo_desc]

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator slotPairs*(acc: CoreDbTxRef; accPath: Hash32): (Hash32, UInt256) =
  for a in acc.aTx.rightPairsStorage accPath:
    yield a

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
