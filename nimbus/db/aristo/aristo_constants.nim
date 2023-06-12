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
  eth/[common, trie/nibbles],
  ./aristo_desc/aristo_types_identifiers

const
  EmptyBlob* = seq[byte].default
    ## Useful shortcut (borrowed from `sync/snap/constants.nim`)

  EmptyNibbleSeq* = EmptyBlob.initNibbleRange
    ## Useful shortcut (borrowed from `sync/snap/constants.nim`)

  VOID_CODE_KEY* = EMPTY_CODE_HASH.to(HashKey)
    ## Equivalent of `nil` for `Account` object code hash

  VOID_HASH_KEY* = EMPTY_ROOT_HASH.to(HashKey)
    ## Equivalent of `nil` for Merkle hash ket

  VOID_HASH_LABEL* = HashLabel(root: VertexID(0), key: VOID_HASH_KEY)

# End
