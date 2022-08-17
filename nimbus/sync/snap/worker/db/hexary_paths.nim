# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Find node paths in hexary tries.

import
  std/[sequtils, tables],
  eth/[common/eth_types, trie/nibbles],
  ../../range_desc,
  ./hexary_desc

{.push raises: [Defect].}

const
  HexaryXPathDebugging = false # or true

type
  HexaryGetFn* = proc(key: Blob): Blob {.gcsafe.}
    ## Fortesting/debugging: database get() function

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc pp(w: Blob; db: HexaryTreeDB): string =
  w.convertTo(RepairKey).pp(db)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hexaryPath*(
    nodeKey: NodeKey;
    db: HexaryTreeDB
      ): RPath
      {.gcsafe, raises: [Defect,KeyError]} =
  ## Compute logest possible repair tree `db` path matching the `nodeKey`
  ## nibbles. The `nodeNey` path argument come first to support a more
  ## functional notation.
  result.tail = nodeKey.to(NibblesSeq)
  var key = db.rootKey.to(RepairKey)
  while db.tab.hasKey(key) and 0 < result.tail.len:
    let node = db.tab[key]
    case node.kind:
    of Leaf:
      if result.tail.len == result.tail.sharedPrefixLen(node.lPfx):
        # Bingo, got full path
        result.path.add RPathStep(key: key, node: node, nibble: -1)
        result.tail = EmptyNibbleRange
      return
    of Branch:
      let nibble = result.tail[0].int8
      if node.bLink[nibble].isZero:
        return
      result.path.add RPathStep(key: key, node: node, nibble: nibble)
      result.tail = result.tail.slice(1)
      key = node.bLink[nibble]
    of Extension:
      if node.ePfx.len != result.tail.sharedPrefixLen(node.ePfx):
        return
      result.path.add RPathStep(key: key, node: node, nibble: -1)
      result.tail = result.tail.slice(node.ePfx.len)
      key = node.eLink


proc hexaryPath*(
    nodeTag: NodeTag;
    db: HexaryTreeDB
      ): RPath
      {.gcsafe, raises: [Defect,KeyError]} =
  ## Variant of `hexaryPath()` for traversing a repair tree
  nodeTag.to(NodeKey).hexaryPath(db)


proc hexaryPath*(
    nodeKey: NodeKey;
    root: NodeKey;
    getFn: HexaryGetFn;
    db: HexaryTreeDB;
      ): XPath
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Compute logest possible path on an arbitrary hexary trie. Note that this
  ## prototype resembles the other ones with the implict `state root`. The
  ## rules for the protopye arguments are:
  ## * First argument is the node key, the node path to be followed
  ## * Last argument is the database (needed only here for debugging)
  ##
  ## Note that this function will flag a potential lowest level `Extception`
  ## in the invoking function due to the `getFn` argument.
  var key = root.ByteArray32.toSeq
  result.tail = nodeKey.to(NibblesSeq)

  when HexaryXPathDebugging:
    echo "*** hexaryPath start:",
      " root=", key.pp(db),
      " tail=", result.tail

  while true:
    let value = key.getFn()
    if value.len == 0:
      break

    var nodeRlp = rlpFromBytes value
    case nodeRlp.listLen:
    of 2:
      let
        (isLeaf, pathSegment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
        nSharedNibbles = result.tail.sharedPrefixLen(pathSegment)
        fullPath = (nSharedNibbles == pathSegment.len)
        newTail = result.tail.slice(nSharedNibbles)

      # Leaf node
      if isLeaf:
        result.path.add XPathStep(key: key, kind: Leaf, nibble: -1)
        result.tail = newTail
        if result.tail.len == 0:
          result.leaf = nodeRlp.listElem(1).toBytes
        when HexaryXPathDebugging:
          echo "*** hexaryPath leaf:",
            " nSharedNibbles=", nSharedNibbles,
            " pathSegment=", pathSegment,
            " tail=", result.tail
        break

      # Extension node
      if fullPath:
        let link = nodeRlp.listElem(1)
        if link.isEmpty:
          when HexaryXPathDebugging:
            echo "*** hexaryPath extension (empty link):",
              " key=", "n/a",
              " tail=", result.tail
          break
        result.path.add XPathStep(key: key, kind: Extension, nibble: -1)
        result.tail = newTail
        key = link.toBytes
        when HexaryXPathDebugging:
          echo "*** hexaryPath extension:",
            " fullPath=", fullPath,
            " key=", key.pp(db),
            " tail=", result.tail
      else:
        when HexaryXPathDebugging:
          echo "*** hexaryPath extension:",
            " fullPath=", fullPath,
            " key=", "n/a",
            " nSharedNibbles=", nSharedNibbles,
            " pathSegment=", pathSegment,
            " tail=", result.tail
        break

    of 17:
      # Branch node
      if result.tail.len == 0:
        result.path.add XPathStep(key: key, kind: Branch, nibble: -1)
        result.leaf = nodeRlp.listElem(1).toBytes
        break
      let
        inx = result.tail[0].int
        link = nodeRlp.listElem(inx)
      if link.isEmpty:
        when HexaryXPathDebugging:
          echo "*** hexaryPath branch (empty link):",
            " key=", "n/a"
        break
      result.path.add XPathStep(key: key, kind: Branch, nibble: inx.int8)
      result.tail = result.tail.slice(1)
      key = link.toBytes
      when HexaryXPathDebugging:
        echo "*** hexaryPath branch:",
          " key=", key.pp(db),
          " inx=", inx,
          " tail=", result.tail
    else:
      when HexaryXPathDebugging:
        echo "*** hexaryPath oops",
          " nColumns=", nodeRlp.listLen
      break

  # end while

  when HexaryXPathDebugging:
    echo "*** hexaryPath done",
      " key=", key.pp(db),
      " tailLen=", result.tail.len,
      " leafSize=", result.leaf.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
