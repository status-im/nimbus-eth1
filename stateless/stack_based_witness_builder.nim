proc getBranchStack*(wb: WitnessBuilder; key: openArray[byte]): string =
  var
    node = wb.db.get(wb.root.data)
    stack = @[(node, initNibbleRange(key))]

  result.add node.toHex
  while stack.len > 0:
    let (node, path) = stack.pop()
    if node.len == 0: continue
    var nodeRlp = rlpFromBytes node

    case nodeRlp.listLen
    of 2:
      let (isLeaf, k) = nodeRlp.extensionNodeKey
      let sharedNibbles = sharedPrefixLen(path, k)
      if sharedNibbles == k.len:
        let value = nodeRlp.listElem(1)
        if not isLeaf:
          let nextLookup = value.getNode
          stack.add((nextLookup, path.slice(sharedNibbles)))
          result.add nextLookup.toHex
    of 17:
      if path.len != 0:
        var branch = nodeRlp.listElem(path[0].int)
        if not branch.isEmpty:
          let nextLookup = branch.getNode
          stack.add((nextLookup, path.slice(1)))
          result.add nextLookup.toHex
    else:
      raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")

proc getBranch*(wb: WitnessBuilder; key: openArray[byte]): seq[seq[byte]] =
  var
    node = wb.db.get(wb.root.data)
    stack = @[(node, initNibbleRange(key))]

  result.add node
  while stack.len > 0:
    let (node, path) = stack.pop()
    if node.len == 0: continue
    var nodeRlp = rlpFromBytes node

    case nodeRlp.listLen
    of 2:
      let (isLeaf, k) = nodeRlp.extensionNodeKey
      let sharedNibbles = sharedPrefixLen(path, k)
      if sharedNibbles == k.len:
        let value = nodeRlp.listElem(1)
        if not isLeaf:
          let nextLookup = value.getNode
          stack.add((nextLookup, path.slice(sharedNibbles)))
          result.add nextLookup
    of 17:
      if path.len != 0:
        var branch = nodeRlp.listElem(path[0].int)
        if not branch.isEmpty:
          let nextLookup = branch.getNode
          stack.add((nextLookup, path.slice(1)))
          result.add nextLookup
    else:
      raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")

proc buildWitness*(wb: var WitnessBuilder; key: openArray[byte]) =
  var
    node = wb.db.get(wb.root.data)
    stack = @[(node, initNibbleRange(key))]

  while stack.len > 0:
    let (node, path) = stack.pop()
    if node.len == 0: continue
    var nodeRlp = rlpFromBytes node

    case nodeRlp.listLen
    of 2:
      let (isLeaf, k) = nodeRlp.extensionNodeKey
      let sharedNibbles = sharedPrefixLen(path, k)
      if sharedNibbles == k.len:
        let value = nodeRlp.listElem(1)
        if not isLeaf:
          let nextLookup = value.getNode
          stack.add((nextLookup, path.slice(sharedNibbles)))
    of 17:
      if path.len != 0:
        var branch = nodeRlp.listElem(path[0].int)
        if not branch.isEmpty:
          let nextLookup = branch.getNode
          stack.add((nextLookup, path.slice(1)))
    else:
      raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")
