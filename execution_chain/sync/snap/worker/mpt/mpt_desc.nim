# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[tables, typetraits],
  pkg/eth/trie/nibbles,
  ../../../../db/aristo/aristo_desc/desc_identifiers,
  ../../../wire_protocol/snap/snap_types,
  ../state_db

export
  desc_identifiers # `HashKey` and friends

type
  NodeType* = enum
    Branch
    Leaf
    Stop

  NodeRef* = ref object of RootRef
    ## Base node object for building a temporary hexary trie.
    kind*: NodeType                    ## Sub-type (see below)
    selfKey*: HashKey                  ## Own node key (mostly a hash)

  BranchNodeRef* = ref object of NodeRef
    ## Branch and/or extension node.
    ##
    ## * Pure extension node
    ##   + `xtData`  == `rlp(extension-node-data)`
    ##   + `xtPfx` != `""`, set to path extension segment
    ##   + `selfKey` == `hash32(xtData)`
    ##   + `brData` is unset
    ##   + `brKey` is unset
    ##   + `brLinks[]` entry `0` is set, all others are `nil`
    ##
    ## * Pure branch node
    ##   + `xtData` is unset
    ##   + `xtPfx` is nunset
    ##   + `brData` == `rlp(branch-node-data)`
    ##   + `brKey` is unset
    ##   + `selfKey` == `hash32(brData)`
    ##   + `brLinks[]` has at least two non-`nil` entries
    ##
    ## * Combined branch and extension node.
    ##   + `xtData`  == `rlp(extension-node-data)`
    ##   + `xtPfx`  != `""`, set to path extension segment
    ##   + `selfKey` == `hash32(xtData)`
    ##   + `brData` == `rlp(branch-node-data)`
    ##   + `brKey` == `hash32(brData)`
    ##   + `brLinks[]` has at least two non-`nil` entries
    ##
    xtPfx*: NibblesBuf                 ## Portion of path segment
    xtData*: seq[byte]                 ## Rlp encoded extension node
    brKey*: HashKey                    ## Only if `xtPfx` is non-empty
    brLinks*: array[16,NodeRef]        ## Down links
    brData*: seq[byte]                 ## Rlp encoded branch node

  LeafNodeRef* = ref object of NodeRef
    lfPfx*: NibblesBuf                 ## Portion of path segment
    lfData*: seq[byte]                 ## Rlp encoded leaf node
    lfPayload*: seq[byte]              ## Leaf data

  StopNodeRef* = ref object of NodeRef
    path*: NibblesBuf                  ## Partial path
    parent*: NodeRef                   ## Unique parent node
    inx*: byte                         ## Index (for branch parent)
    sub*: NodeRef                      ## Optional start of a sub-tree

  NodeTrieRef* = ref object of RootRef
    root*: NodeRef                     ## Start of in-memory tree
    stops*: Table[HashKey,StopNodeRef] ## Dangling sub-tries

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

template to*(h: StateRoot|StoreRoot|BlockHash; _: type HashKey): HashKey =
  ## Variant of `desc_identifiers.to()`
  h.Hash32.to(HashKey)

template digestTo*(
    node: ProofNode;
    _: type HashKey;
    force32: static[bool] = false): HashKey =
  ## Variant of `desc_identifiers.digestTo()`
  when force32:
    HashKey.fromBytes(node.distinctBase.keccak256.data).expect "Valid HashKey"
  else:
    node.distinctBase.digestTo(HashKey)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
