# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Identifier types
## =============================
##

{.push raises: [].}

import
  std/strutils,
  eth/common,
  ../../../sync/snap/range_desc

type
  VertexID* = distinct uint64
    ## Unique identifier for a vertex of the `Aristo Trie`. The vertex is the
    ## prefix tree (aka `Patricia Trie`) component. When augmented by hash
    ## keys, the vertex component will be called a node. On the persistent
    ## backend of the database, there is no other reference to the node than
    ## the very same `VertexID`

  LeafTie* = object
    ## Unique access key for a leaf vertex. It identifies a root vertex
    ## followed by a nibble path along the `Patricia Trie` down to a leaf
    ## vertex. So this implies an obvious injection from the set of `LeafTie`
    ## objects *into* the set of `VertexID` obvious (which is typically *into*
    ## only, not a bijection.)
    ##
    ## Note that `LeafTie` objects have no representation in the `Aristo Trie`.
    ## They are used temporarily and in caches or backlog tables.
    root*: VertexID                  ## Root ID for the sub-trie
    path*: NodeTag                   ## Path into the `Patricia Trie`

  HashLabel* = object
    ## Merkle hash key uniquely associated with a vertex ID. As hashes in a
    ## `Merkle Patricia Tree` are unique only on a particular sub-trie, the
    ## hash key is paired with the top vertex of the relevant sub-trie. This
    ## construction is similar to the one of a `LeafTie` object.
    ##
    ## Note that `LeafTie` objects have no representation in the `Aristo Trie`.
    ## They are used temporarily and in caches or backlog tables.
    root*: VertexID                  ## Root ID for the sub-trie
    key*: NodeKey                    ## Path into the `Patricia Trie`

# ------------------------------------------------------------------------------
# Public helpers: `VertexID` scalar data model
# ------------------------------------------------------------------------------

proc `<`*(a, b: VertexID): bool {.borrow.}
proc `==`*(a, b: VertexID): bool {.borrow.}
proc cmp*(a, b: VertexID): int {.borrow.}
proc `$`*(a: VertexID): string = $a.uint64

proc `==`*(a: VertexID; b: static[uint]): bool =
  a == VertexID(b)

# ------------------------------------------------------------------------------
# Public helpers: `LeafTie` scalar data model
# ------------------------------------------------------------------------------

proc `<`*(a, b: LeafTie): bool =
  a.root < b.root or (a.root == b.root and a.path < b.path)

proc `==`*(a, b: LeafTie): bool =
  a.root == b.root and a.path == b.path

proc cmp*(a, b: LeafTie): int =
  if a < b: -1 elif a == b: 0 else: 1

proc `$`*(a: LeafTie): string =
  let w = $a.root.uint64.toHex & ":" & $a.path.Uint256.toHex
  w.strip(leading=true, trailing=false, chars={'0'}).toLowerAscii

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
