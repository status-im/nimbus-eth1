# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[sequtils, sets, strutils, tables],
  eth/[common, trie/nibbles],
  ../../range_desc,
  "."/[hexary_desc, hexary_error]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc pp(q: openArray[byte]): string =
  q.toSeq.mapIt(it.toHex(2)).join.toLowerAscii.pp(hex = true)

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc hexaryImport*(
    db: HexaryTreeDbRef;                ## Contains node table
    recData: Blob;                      ## Node to add
    unrefNodes: var HashSet[RepairKey]; ## Keep track of freestanding nodes
    nodeRefs: var HashSet[RepairKey];   ## Ditto
      ): HexaryNodeReport
      {.gcsafe, raises: [Defect, RlpError, KeyError].} =
  ## Decode a single trie item for adding to the table and add it to the
  ## database. Branch and exrension record links are collected.
  if recData.len == 0:
    return HexaryNodeReport(error: RlpNonEmptyBlobExpected)
  let
    nodeKey = recData.digestTo(NodeKey)
    repairKey = nodeKey.to(RepairKey) # for repair table
  var
    rlp = recData.rlpFromBytes
    blobs = newSeq[Blob](2)         # temporary, cache
    links: array[16,RepairKey]      # reconstruct branch node
    blob16: Blob                    # reconstruct branch node
    top = 0                         # count entries
    rNode: RNodeRef                 # repair tree node

  # Collect lists of either 2 or 17 blob entries.
  for w in rlp.items:
    case top
    of 0, 1:
      if not w.isBlob:
        return HexaryNodeReport(error: RlpBlobExpected)
      blobs[top] = rlp.read(Blob)
    of 2 .. 15:
      var key: NodeKey
      if not key.init(rlp.read(Blob)):
        return HexaryNodeReport(error: RlpBranchLinkExpected)
      # Update ref pool
      links[top] = key.to(RepairKey)
      unrefNodes.excl links[top] # is referenced, now (if any)
      nodeRefs.incl links[top]
    of 16:
      if not w.isBlob:
        return HexaryNodeReport(error: RlpBlobExpected)
      blob16 = rlp.read(Blob)
    else:
      return HexaryNodeReport(error: Rlp2Or17ListEntries)
    top.inc

  # Verify extension data
  case top
  of 2:
    if blobs[0].len == 0:
      return HexaryNodeReport(error: RlpNonEmptyBlobExpected)
    let (isLeaf, pathSegment) = hexPrefixDecode blobs[0]
    if isLeaf:
      rNode = RNodeRef(
        kind:  Leaf,
        lPfx:  pathSegment,
        lData: blobs[1])
    else:
      var key: NodeKey
      if not key.init(blobs[1]):
        return HexaryNodeReport(error: RlpExtPathEncoding)
      # Update ref pool
      rNode = RNodeRef(
        kind:  Extension,
        ePfx:  pathSegment,
        eLink: key.to(RepairKey))
      unrefNodes.excl rNode.eLink # is referenced, now (if any)
      nodeRefs.incl rNode.eLink
  of 17:
    for n in [0,1]:
      var key: NodeKey
      if not key.init(blobs[n]):
        return HexaryNodeReport(error: RlpBranchLinkExpected)
      # Update ref pool
      links[n] = key.to(RepairKey)
      unrefNodes.excl links[n] # is referenced, now (if any)
      nodeRefs.incl links[n]
    rNode = RNodeRef(
      kind:  Branch,
      bLink: links,
      bData: blob16)
  else:
    discard

  # Add to database
  if not db.tab.hasKey(repairKey):
    db.tab[repairKey] = rNode

    # Update  unreferenced nodes list
    if repairKey notin nodeRefs:
      unrefNodes.incl repairKey # keep track of stray nodes

  elif db.tab[repairKey].convertTo(Blob) != recData:
    return HexaryNodeReport(error: DifferentNodeValueExists)

  HexaryNodeReport(kind: some(rNode.kind))


proc hexaryImport*(
    db: HexaryTreeDbRef;                ## Contains node table
    rec: NodeSpecs;                     ## Expected key and value data pair
      ): HexaryNodeReport
      {.gcsafe, raises: [Defect, RlpError, KeyError].} =
  ## Ditto without referece checks but expected node key argument.
  if rec.data.len == 0:
    return HexaryNodeReport(error: RlpNonEmptyBlobExpected)
  if rec.nodeKey != rec.data.digestTo(NodeKey):
    return HexaryNodeReport(error: ExpectedNodeKeyDiffers)

  let
    repairKey = rec.nodeKey.to(RepairKey) # for repair table
  var
    rlp = rec.data.rlpFromBytes
    blobs = newSeq[Blob](2)         # temporary, cache
    links: array[16,RepairKey]      # reconstruct branch node
    blob16: Blob                    # reconstruct branch node
    top = 0                         # count entries
    rNode: RNodeRef                 # repair tree node

  # Collect lists of either 2 or 17 blob entries.
  for w in rlp.items:
    case top
    of 0, 1:
      if not w.isBlob:
        return HexaryNodeReport(error: RlpBlobExpected)
      blobs[top] = rlp.read(Blob)
    of 2 .. 15:
      var key: NodeKey
      if not key.init(rlp.read(Blob)):
        return HexaryNodeReport(error: RlpBranchLinkExpected)
      # Update ref pool
      links[top] = key.to(RepairKey)
    of 16:
      if not w.isBlob:
        return HexaryNodeReport(error: RlpBlobExpected)
      blob16 = rlp.read(Blob)
    else:
      return HexaryNodeReport(error: Rlp2Or17ListEntries)
    top.inc

  # Verify extension data
  case top
  of 2:
    if blobs[0].len == 0:
      return HexaryNodeReport(error: RlpNonEmptyBlobExpected)
    let (isLeaf, pathSegment) = hexPrefixDecode blobs[0]
    if isLeaf:
      rNode = RNodeRef(
        kind:  Leaf,
        lPfx:  pathSegment,
        lData: blobs[1])
    else:
      var key: NodeKey
      if not key.init(blobs[1]):
        return HexaryNodeReport(error: RlpExtPathEncoding)
      # Update ref pool
      rNode = RNodeRef(
        kind:  Extension,
        ePfx:  pathSegment,
        eLink: key.to(RepairKey))
  of 17:
    for n in [0,1]:
      var key: NodeKey
      if not key.init(blobs[n]):
        return HexaryNodeReport(error: RlpBranchLinkExpected)
      # Update ref pool
      links[n] = key.to(RepairKey)
    rNode = RNodeRef(
      kind:  Branch,
      bLink: links,
      bData: blob16)
  else:
    discard

  # Add to database
  if not db.tab.hasKey(repairKey):
    db.tab[repairKey] = rNode

  elif db.tab[repairKey].convertTo(Blob) != rec.data:
    return HexaryNodeReport(error: DifferentNodeValueExists)

  HexaryNodeReport(kind: some(rNode.kind))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
