# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  eth/[common, trie/nibbles],
  ./aristo_desc/desc_identifiers

const
  EmptyBlob* = seq[byte].default
    ## Useful shortcut (borrowed from `sync/snap/constants.nim`)

  EmptyNibbleSeq* = EmptyBlob.initNibbleRange
    ## Useful shortcut (borrowed from `sync/snap/constants.nim`)

  EmptyVidSeq* = seq[VertexID].default
    ## Useful shortcut

  EmptyVidSet* = EmptyVidSeq.toHashSet
    ## Useful shortcut

  VOID_CODE_HASH* = EMPTY_CODE_HASH
    ## Equivalent of `nil` for `Account` object code hash

  VOID_HASH_KEY* = HashKey()
    ## Void equivalent for Merkle hash value

  VOID_HASH_LABEL* = HashLabel()
    ## Void equivalent for Merkle hash value

  EmptyQidPairSeq* = seq[(QueueID,QueueID)].default
    ## Useful shortcut

  DEFAULT_QID_QUEUES* = [
    (128,   0), ## Consecutive list of 128 filter slots
    ( 64,  63), ## Overflow list, 64 filters, skipping 63 filters in-between
    ( 64, 127), ## ..
    ( 64, 255)]

# End
