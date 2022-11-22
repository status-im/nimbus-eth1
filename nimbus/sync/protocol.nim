# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

when defined(legacy_eth66_enabled):
  import ./protocol/eth66 as proto_eth
  type eth* = eth66
else:
  import ./protocol/eth67 as proto_eth
  type eth* = eth67

import
  ./protocol/snap1 as proto_snap

export
  proto_eth,
  proto_snap

type
  snap* = snap1

  SnapAccountRange* = accountRangeObj
    ## Syntactic sugar, type defined in `snap1`

  SnapStorageRanges* = storageRangesObj
    ## Ditto

  SnapByteCodes* = byteCodesObj
    ## Ditto

  SnapTrieNodes* = trieNodesObj
    ## Ditto

# End
