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
  ../../../../db/aristo/[aristo_constants, aristo_desc/desc_identifiers],
  ../../../wire_protocol/snap/snap_types,
  ../state_db

export
  EmptyBlob,
  VOiD_HASH_KEY,
  desc_identifiers # `HashKey` and friends

const
  EmptyPath* = NibblesBuf()

type
  NodeType* = enum
    Branch
    Leaf
    Stop

  NodeRef* = ref object of RootRef
    ## Base node object for building a temporary, partial hexary MPT.
    kind*: NodeType                                 ## sub-type (see below)
    selfKey*: HashKey                               ## owned node key

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
    xtPfx*: NibblesBuf                              ## portion of path segment
    xtData*: seq[byte]                              ## rlp encoded extension
    brKey*: HashKey                                 ## if `xtPfx` is non-empty
    brLinks*: array[16,NodeRef]                     ## down links
    brData*: seq[byte]                              ## rlp encoded branch node

  LeafNodeRef* = ref object of NodeRef
    lfPfx*: NibblesBuf                              ## portion of path segment
    lfData*: seq[byte]                              ## rlp encoded leaf node
    lfPayload*: seq[byte]                           ## leaf data

  StopNodeRef* = ref object of NodeRef
    path*: NibblesBuf                               ## partial path
    parent*: NodeRef                                ## unique parent node
    inx*: byte                                      ## index (for branch parent)
    sub*: NodeRef                                   ## start of a sub-MPT

  NodeTrieRef* = ref object of RootRef
    root*: NodeRef                                  ## start of in-memory MPT
    stops*: Table[HashKey,StopNodeRef]              ## sub-MPT to complete
    proof*: seq[HashKey]                            ## hash links to proof nodes

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
