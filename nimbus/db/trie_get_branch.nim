# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# This implementation of getBranch on the CoreDbPhkRef type is a temporary solution
# which can be removed once we get an equivient proc defined on the CoreDbPhkRef type
# in the db layer.

{.push raises: [].}

import
  eth/[rlp, trie/nibbles],
  "."/[core_db]

type
  TrieNodeKey = object
    hash: KeccakHash
    usedBytes: uint8

template len(key: TrieNodeKey): int =
  key.usedBytes.int

template asDbKey(k: TrieNodeKey): untyped =
  doAssert k.usedBytes == 32
  k.hash.data

template extensionNodeKey(r: Rlp): auto =
  hexPrefixDecode r.listElem(0).toBytes

proc getLocalBytes(x: TrieNodeKey): seq[byte] =
  ## This proc should be used on nodes using the optimization
  ## of short values within the key.
  doAssert x.usedBytes < 32
  x.hash.data[0..<x.usedBytes]

proc dbGet(db: CoreDbRef, data: openArray[byte]): seq[byte]
  {.gcsafe, raises: [].} =
  db.kvt.get(data)

template keyToLocalBytes(db: CoreDbRef, k: TrieNodeKey): seq[byte] =
  if k.len < 32: k.getLocalBytes
  else: dbGet(db, k.asDbKey)

proc expectHash(r: Rlp): seq[byte] {.raises: [RlpError].} =
  result = r.toBytes
  if result.len != 32:
    raise newException(RlpTypeMismatch,
      "RLP expected to be a Keccak hash value, but has an incorrect length")

template getNode(db: CoreDbRef, elem: Rlp): untyped =
  if elem.isList: @(elem.rawData)
  else: dbGet(db, elem.expectHash)

proc getBranchAux(
    db: CoreDbRef, node: openArray[byte],
    fullPath: NibblesSeq,
    pathIndex: int,
    output: var seq[seq[byte]]) {.raises: [RlpError].} =
  var nodeRlp = rlpFromBytes node
  if not nodeRlp.hasData or nodeRlp.isEmpty: return

  let path = fullPath.slice(pathIndex)
  case nodeRlp.listLen
  of 2:
    let (isLeaf, k) = nodeRlp.extensionNodeKey
    let sharedNibbles = sharedPrefixLen(path, k)
    if sharedNibbles == k.len:
      let value = nodeRlp.listElem(1)
      if not isLeaf:
        let nextLookup = getNode(db, value)
        output.add nextLookup
        getBranchAux(db, nextLookup, fullPath, pathIndex + sharedNibbles, output)
  of 17:
    if path.len != 0:
      var branch = nodeRlp.listElem(path[0].int)
      if not branch.isEmpty:
        let nextLookup = getNode(db, branch)
        output.add nextLookup
        getBranchAux(db, nextLookup, fullPath, pathIndex + 1, output)
  else:
    raise newException(RlpError, "node has an unexpected number of children")

proc getBranch*(
    self: CoreDbPhkRef;
    key: openArray[byte]): seq[seq[byte]] {.raises: [RlpError].} =
  let keyHash = keccakHash(key).data
  result = @[]
  var node = keyToLocalBytes(self.parent(), TrieNodeKey(
        hash: self.rootHash(), usedBytes: self.rootHash().data.len().uint8))
  result.add node
  getBranchAux(self.parent(), node, initNibbleRange(keyHash), 0, result)