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
  pkg/eth/common/[base, hashes],
  ../../../../db/aristo/aristo_desc/desc_nibbles,
  ../../../wire_protocol/snap/snap_types,
  ../state_db

type
  NodeKey* = object
    data: array[32, byte] # Either Hash32 or blob data, depending on `len`
    len: int8 # length in the case of blobs, or 32 when it's a hash

  NodeType* = enum
    Branch
    Leaf
    Stop

  NodeRef* = ref object of RootRef
    ## Base node object for building a temporary hexary trie.
    kind*: NodeType                    ## Sub-type (see below)
    selfKey*: NodeKey                  ## Own node key (mostly a hash)

  BranchNodeRef* = ref object of NodeRef
    xtPfx*: NibblesBuf                 ## Portion of path segment
    xtData*: seq[byte]                 ## Rlp encoded extension node
    brKey*: NodeKey                    ## Only if `xtPfx` is non-empty
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
    stops*: Table[NodeKey,StopNodeRef] ## Dangling sub-tries

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func digestTo*(data: openArray[byte], T: type NodeKey, force32 = false): T =
  ## Expensive call, hashes rlp encoded node record.
  ##
  if data.len < 32:
    result.len = data.len.int8
    if 0 < data.len:
      (addr result.data[0]).copyMem(addr data[0], data.len)
  else:
    result.len = 32
    result.data = data.keccak256.distinctBase

func digestTo*(node: ProofNode, T: type NodeKey, force32 = false): T =
  ## Variant of the former `digestTo()`
  node.distinctBase.digestTo(T,force32)


func to*(k: NodeKey; T: type Hash32): T =
  if k.len == 32: k.data.T else: zeroHash32

func to*(k: NodeKey; T: type seq[byte]): T =
  if 0 < k.len:
    result.setLen k.len
    (addr result[0]).copyMem(addr k.data[0], k.len)

func len*(k: NodeKey): int =
  k.len.int

proc clear*(k: var NodeKey) =
  k.len = 0

func to*(blob: openArray[byte]; T: type NodeKey): T =
  ## Conversion of serialised node key to `NodeKey`. If applied to a an
  ## argument `blob` with length larger than 32, only the first 32 bytes are
  ## used.
  ##
  result.len = min(blob.len.int8,32)
  (addr result.data[0]).copyMem(addr blob[0], result.len)

func to*(h: Hash32|StateRoot|BlockHash; T: type NodeKey): T =
  ## Vaiiant of the former `to()`
  h.distinctBase.to(T)


func `==`*(a, b: NodeKey): bool =
  a.len == b.len and a.data == b.data

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
