# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/sets,
  ./aristo_desc/desc_identifiers

const
  EmptyBlob* = seq[byte].default
    ## Useful shortcut (borrowed from `sync/snap/constants.nim`)

  EmptyVidSeq* = seq[VertexID].default
    ## Useful shortcut

  EmptyVidSet* = EmptyVidSeq.toHashSet
    ## Useful shortcut

  VOID_HASH_KEY* = HashKey()
    ## Void equivalent for Merkle hash value

  STATE_ROOT_VID* = VertexID(1)
    ## VertexID of state root entry in the MPT

  STATIC_VID_LEVELS* = 8
    ## Number of MPT levels that get a fixed VertexID(1)

  FIRST_DYNAMIC_VID* = ## First VertexID of the sparse/dynamic part of the MPT
    block:
      var v = uint64(STATE_ROOT_VID)
      for i in 0..<STATIC_VID_LEVELS:
        v += 1'u64 shl (i * 4)
      v

  ACC_LRU_SIZE* = 1024 * 1024
    ## LRU cache size for accounts that have storage, see `.accLeaves` and
    ## `.stoLeaves` fields of the main descriptor.

# End
