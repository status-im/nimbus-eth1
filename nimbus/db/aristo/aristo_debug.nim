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
  eth/[common, trie/nibbles],
  stew/byteutils,
  ../../sync/snap/range_desc,
  "."/[aristo_desc, aristo_error]

const
  EMPTY_ROOT_KEY = EMPTY_ROOT_HASH.to(NodeKey)
  EMPTY_CODE_KEY = EMPTY_CODE_HASH.to(NodeKey)

# ------------------------------------------------------------------------------
# Ptivate functions
# ------------------------------------------------------------------------------

proc keyVtxUpdate(db: AristoDbRef, key: NodeKey, vtx: VertexID): string =
  if not key.isZero and not db.isNil:
    if db.xMap.hasKey(key):
      try:
        if db.xMap[key] == vtx: return
      except:
        discard
      return "(!)"
    if not vtx.isZero:
      db.xMap[key] = vtx

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

proc ppReason(a: AristoError): string =
  if a.ord == 0: "" else: "!" & $a

proc ppVtx(vrt: VertexID): string =
  if vrt.isZero: "ø" else: $vrt

proc ppKey(a: NodeKey, db = AristoDbRef(nil)): string =
  if a.isZero:
    return "ø"

  let tag = if a == EMPTY_ROOT_KEY or a == EMPTY_CODE_KEY: "(!)" else: ""
  if not db.isNil and db.xMap.hasKey a:
    try:
      return "£" & $db.xMap[a] & tag
    except:
      discard

  "%" & ($a).squeeze(hex=true,ignLen=true) & tag

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
  if not key.isZero and not db.isNil:
    if db.xMap.len == 0:
      db.xMap[EMPTY_ROOT_KEY] = db.newVtxID
      db.xMap[EMPTY_CODE_KEY] = db.newVtxID
    if db.xMap.hasKey(key):
      try:
        return db.xMap[key]
      except:
        discard
      return

    result = db.newVtxID
    db.xMap[key] = result


proc pp*(p: PayloadRef, db = AristoDbRef(nil)): string =
  if p.isNil:
    result = "n/a"
  else:
    case p.kind:
    of BlobData:
      result &= p.blob.toHex.squeeze(hex=true)
    of AccountData:
      result = "("
      result &= $p.account.nonce & ","
      result &= $p.account.balance & ","
      result &= p.account.storageRoot.to(NodeKey).ppRootKey(db) & ","
      result &= p.account.codeHash.to(NodeKey).ppCodeKey(db) & ")"

proc pp*(nd: NodeRef, db = AristoDbRef(nil)): string =
  if nd.isNil:
    result = "n/a"
  else:
    result = ["(", "L(", "X(", "B("][nd.kind.ord]
    case nd.kind:
    of Dummy:
      result &= nd.reason.ppReason
    of Leaf:
      result &= $nd.lPfx & "," & nd.lData.pp(db)
    of Extension:
      result &= $nd.ePfx & "," & nd.eVtx.ppVtx & "," & nd.eKey.ppKey
    of Branch:
      result &= "["
      for n in 0..15:
        if not nd.bVtx[n].isZero or not nd.bKey[n].isZero:
          result &= nd.bVtx[n].ppVtx
        result &= db.keyVtxUpdate(nd.bKey[n], nd.bVtx[n]) & ","
      result[^1] = ']'
      result &= ",["
      for n in 0..15:
        if not nd.bVtx[n].isZero or not nd.bKey[n].isZero:
          result &= nd.bKey[n].ppKey(db)
        result &= ","
      result[^1] = ']'
    result &= ")"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
