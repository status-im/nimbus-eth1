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
  std/[algorithm, sets, sequtils, strutils, tables],
  eth/[common, trie/nibbles],
  stew/byteutils,
  ../../sync/snap/range_desc,
  "."/[aristo_constants, aristo_desc, aristo_error, aristo_hike, aristo_vid]

# ------------------------------------------------------------------------------
# Ptivate functions
# ------------------------------------------------------------------------------

proc toPfx(indent: int): string =
  "\n" & " ".repeat(indent)

proc keyVidUpdate(db: AristoDbRef, key: NodeKey, vid: VertexID): string =
  if not key.isZero and
     not vid.isZero and
     not db.isNil:
    db.pAmk.withValue(key, vidRef):
      if vidRef[] != vid:
        result = "(!)"
      return
    db.xMap.withValue(key, vidRef):
      if vidRef[] == vid:
        result = "(!)"
      return
    db.xMap[key] = vid

proc squeeze(s: string; hex = false; ignLen = false): string =
  ## For long strings print `begin..end` only
  if hex:
    let n = (s.len + 1) div 2
    result = if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len-8 .. s.len-1]
    if not ignLen:
      result &= "[" & (if 0 < n: "#" & $n else: "") & "]"
  elif s.len <= 30:
    result = s
  else:
    result = if (s.len and 1) == 0: s[0 ..< 8] else: "0" & s[0 ..< 7]
    if not ignLen:
      result &= "..(" & $s.len & ")"
    result &= ".." & s[s.len-16 ..< s.len]

proc stripZeros(a: string): string =
  for n in 0 ..< a.len:
    if a[n] != '0':
      return a[n .. ^1]
  return a

proc ppVid(vid: VertexID): string =
  if vid.isZero: "ø" else: "$" & vid.uint64.toHex.stripZeros.toLowerAscii

proc ppKey(key: NodeKey, db = AristoDbRef(nil)): string =
  if key.isZero:
    return "ø"
  if key == EMPTY_ROOT_KEY:
    return "£r"
  if key == EMPTY_CODE_KEY:
    return "£c"

  if not db.isNil:
    db.pAmk.withValue(key, pRef):
      return "£" & pRef[].uint64.toHex.stripZeros.toLowerAscii
    db.xMap.withValue(key, xRef):
      return "£" & xRef[].uint64.toHex.stripZeros.toLowerAscii

  "%" & key.ByteArray32
           .mapIt(it.toHex(2)).join.tolowerAscii
           .squeeze(hex=true,ignLen=true)

proc ppRootKey(a: NodeKey, db = AristoDbRef(nil)): string =
  if a != EMPTY_ROOT_KEY:
    return a.ppKey(db)

proc ppCodeKey(a: NodeKey, db = AristoDbRef(nil)): string =
  if a != EMPTY_CODE_KEY:
    return a.ppKey(db)

proc ppPathTag(tag: NodeTag, db = AristoDbRef(nil)): string =
  ## Raw key, for referenced key dump use `key.pp(db)` below
  if not db.isNil:
    db.lTab.withValue(tag, keyPtr):
      return "@" & keyPtr[].ppVid

  "@" & tag.to(NodeKey).ByteArray32
           .mapIt(it.toHex(2)).join.toLowerAscii
           .squeeze(hex=true,ignLen=true)

proc ppPathPfx(pfx: NibblesSeq): string =
  ($(pfx & EmptyNibbleSeq)).squeeze(hex=true)

proc ppNibble(n: int8): string =
  if n < 0: "ø" elif n < 10: $n else: n.toHex(1).toLowerAscii

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc keyToVtxID*(db: AristoDbRef, key: NodeKey): VertexID =
  ## Associate a vertex ID with the argument `key` for pretty printing.
  if not key.isZero and
     key != EMPTY_ROOT_KEY and
     key != EMPTY_CODE_KEY and
     not db.isNil:

    db.xMap.withValue(key, vidPtr):
      return vidPtr[]

    result = db.vidFetch()
    db.xMap[key] = result

proc pp*(vid: NodeKey): string =
  vid.ppKey

proc pp*(tag: NodeTag, db = AristoDbRef(nil)): string =
  tag.ppPathTag(db)

proc pp*(vid: VertexID): string =
  vid.ppVid

proc pp*(vid: openArray[VertexID]): string =
  "[" & vid.mapIt(it.ppVid).join(",") & "]"

proc pp*(p: PayloadRef, db = AristoDbRef(nil)): string =
  if p.isNil:
    result = "n/a"
  else:
    case p.pType:
    of BlobData:
      result &= p.blob.toHex.squeeze(hex=true)
    of AccountData:
      result = "("
      result &= $p.account.nonce & ","
      result &= $p.account.balance & ","
      result &= p.account.storageRoot.to(NodeKey).ppRootKey(db) & ","
      result &= p.account.codeHash.to(NodeKey).ppCodeKey(db) & ")"

proc pp*(nd: VertexRef, db = AristoDbRef(nil)): string =
  if nd.isNil:
    result = "n/a"
  else:
    result = ["l(", "x(", "b("][nd.vType.ord]
    case nd.vType:
    of Leaf:
      result &= nd.lPfx.ppPathPfx & "," & nd.lData.pp(db)
    of Extension:
      result &= nd.ePfx.ppPathPfx & "," & nd.eVid.ppVid
    of Branch:
      result &= "["
      for n in 0..15:
        if not nd.bVid[n].isZero:
          result &= nd.bVid[n].ppVid
        result &= ","
      result[^1] = ']'
    result &= ")"

proc pp*(nd: NodeRef, db = AristoDbRef(nil)): string =
  if nd.isNil:
    result = "n/a"
  elif nd.isError:
    result = "(!" & $nd.error
  else:
    result = ["L(", "X(", "B("][nd.vType.ord]
    case nd.vType:
    of Leaf:
      result &= $nd.lPfx.ppPathPfx & "," & nd.lData.pp(db)

    of Extension:
      result &= $nd.ePfx.ppPathPfx & "," & nd.eVid.ppVid & "," & nd.key[0].ppKey

    of Branch:
      result &= "["
      for n in 0..15:
        if not nd.bVid[n].isZero or not nd.key[n].isZero:
          result &= nd.bVid[n].ppVid
        result &= db.keyVidUpdate(nd.key[n], nd.bVid[n]) & ","
      result[^1] = ']'

      result &= ",["
      for n in 0..15:
        if not nd.bVid[n].isZero or not nd.key[n].isZero:
          result &= nd.key[n].ppKey(db)
        result &= ","
      result[^1] = ']'
  result &= ")"

proc pp*(
    sTab: var Table[VertexID,VertexRef];
    db = AristoDbRef(nil);
    indent = 4;
      ): string =
  let pfx = indent.toPfx
  var first = true
  result = "{"
  for vid in toSeq(sTab.keys).mapIt(it.uint64).sorted.mapIt(it.VertexID):
    sTab.withValue(vid, vtxPtr):
      if first:
        first = false
      else:
        result &= pfx & " "
      result &= "(" & vid.ppVid & "," & vtxPtr[].pp(db) & "),"
  if result[^1] == ',':
    result[^1] = '}'
  else:
    result &= "}"

proc pp*(lTab: var Table[NodeTag,VertexID]; indent = 4): string =
  let pfx = indent.toPfx
  var first = true
  result = "{"
  for tag in toSeq(lTab.keys).mapIt(it.UInt256).sorted.mapIt(it.NodeTag):
    lTab.withValue(tag,vidPtr):
      if first:
        first = false
      else:
        result &= pfx & " "
      result &= "(" & tag.ppPathTag & "," & vidPtr[].ppVid & "),"
  if result[^1] == ',':
    result[^1] = '}'
  else:
    result &= "}"

proc pp*(sDel: HashSet[VertexID]): string =
  result = "{"
  for vid in toSeq(sDel.items).mapIt(it.uint64).sorted.mapIt(it.VertexID):
    result &= vid.ppVid & ","
  if result[^1] == ',':
    result[^1] = '}'
  else:
    result &= "}"

proc pp*(
    hike: Hike;
    db = AristoDbRef(nil);
    indent = 4;
      ): string =
  let pfx = indent.toPfx
  var first = true
  result = "[(" & hike.root.ppVid & ")"
  for leg in hike.legs:
    result &= "," & pfx & " (" & leg.wp.vid.ppVid
    if not db.isNil:
      var key = "ø"
      db.kMap.withValue(leg.wp.vid, keyPtr):
        key = keyPtr[].ppKey(db)
      result &= "," & key
    result &= "," & $leg.nibble.ppNibble & "," & leg.wp.vtx.pp(db) & ")"
  result &= "," & pfx & " (" & $hike.tail & ")"
  if hike.error != AristoError(0):
    result &= "," & pfx & " (" & $hike.error & ")"
  result &= "]"

proc pp*(
    kMap: var Table[VertexID,NodeKey];
    db = AristoDbRef(nil);
    indent = 4;
      ): string =
  let pfx = indent.toPfx
  var first = true
  result = "{"
  for vid in toSeq(kMap.keys).mapIt(it.uint64).sorted.mapIt(it.VertexID):
    kMap.withValue(vid, keyPtr):
      if first:
        first = false
      else:
        result &= pfx & " "
      result &= "(" & vid.ppVid & "," & keyPtr[].ppKey(db) & "),"
  if result[^1] == ',':
    result[^1] = '}'
  else:
    result &= "}"

proc pp*(
    pAmk: var Table[NodeKey,VertexID];
    db = AristoDbRef(nil);
    indent = 4;
      ): string =
  let pfx = indent.toPfx
  var first = true
  result = "{"
  for key in toSeq(pAmk.keys).mapIt(it.to(NodeTag).UInt256)
                             .sorted.mapIt(it.NodeTag.to(NodeKey)):
    pAmk.withValue(key,vidPtr):
      if first:
        first = false
      else:
        result &= pfx & " "
      result &= "(" & key.ppKey(db) & "," & vidPtr[].ppVid & "),"
  if result[^1] == ',':
    result[^1] = '}'
  else:
    result &= "}"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
