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
  std/[sequtils, strutils],
  eth/[common, trie/nibbles],
  stew/byteutils,
  ../../sync/snap/range_desc,
  "."/[aristo_constants, aristo_desc, aristo_vid]

# ------------------------------------------------------------------------------
# Ptivate functions
# ------------------------------------------------------------------------------

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
  if vid.isZero: "ø" else: "$" & vid.uint64.toHex.stripZeros

proc ppKey(key: NodeKey, db = AristoDbRef(nil)): string =
  if key.isZero:
    return "ø"
  if key == EMPTY_ROOT_KEY:
    return "£r"
  if key == EMPTY_CODE_KEY:
    return "£c"

  if not db.isNil:
    db.pAmk.withValue(key, pRef):
      return "£" & $pRef[]
    db.xMap.withValue(key, xRef):
      return "£" & $xRef[]

  "%" & ($key).squeeze(hex=true,ignLen=true)

proc ppRootKey(a: NodeKey, db = AristoDbRef(nil)): string =
  if a != EMPTY_ROOT_KEY:
    return a.ppKey(db)

proc ppCodeKey(a: NodeKey, db = AristoDbRef(nil)): string =
  if a != EMPTY_CODE_KEY:
    return a.ppKey(db)

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
      result &= $nd.lPfx & "," & nd.lData.pp(db)
    of Extension:
      result &= $nd.ePfx & "," & nd.eVid.ppVid
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
      result &= $nd.lPfx & "," & nd.lData.pp(db)

    of Extension:
      result &= $nd.ePfx & "," & nd.eVid.ppVid & "," & nd.key[0].ppKey

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
