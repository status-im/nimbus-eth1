# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
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

  FIRST_STATIC_VID* = VertexID(1)
    ## First VertexID of the dense/static part of a trie, ie the level 0 slot.
    ## The account trie stores its root there while a storage trie roots at its
    ## own dynamic `stoID`, leaving the slot unused

  STATE_ROOT_VID* = FIRST_STATIC_VID
    ## VertexID of state root entry in the MPT

  STATIC_VID_LEVELS* = 8
    ## Number of MPT levels in a trie that get a fixed VertexID based
    ## on the initial nibbles of the path. We'll consume a little bit more than
    ## `STATIC_VID_LEVELS*4` bits for the static part of the vid space:
    ##
    ## FIRST_STATIC_VID + 16^0 + 16^1 + ... + 16^STATIC_VID_LEVELS

  FIRST_DYNAMIC_VID* = ## First VertexID of the sparse/dynamic part of the MPT
    block:
      var v = uint64(FIRST_STATIC_VID)
      for i in 0..STATIC_VID_LEVELS:
        v += 1'u64 shl (i * 4)
      v

  MAX_KEYS_FETCH* = 16
    ## Maximum number of keys accepted by `GetKeysFn` in a single batch, sized
    ## to the branch vertex fan-out.

  ACC_LRU_SIZE* = 1024 * 1024
    ## LRU cache size for accounts that have storage, see `.accLeaves` and
    ## `.stoLeaves` fields of the main descriptor.

# End
