# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  chronicles,
  eth/common,
  results,
  "."/[aristo_desc, aristo_get, aristo_layers, aristo_serialise]

logScope:
  topics = "aristo-hashify"

proc computeKey*(
    db: AristoDbRef;                   # Database, top layer
    vid: VertexID;                    # Vertex to convert
      ): Result[HashKey, AristoError] =
  # This is a variation on getKeyRc which computes the key instead of returning
  # an error
  # TODO it should not always write the key to the persistent storage

  proc getKey(db: AristoDbRef; vid: VertexID): HashKey =
    block body:
      let key = db.layersGetKey(vid).valueOr:
        break body
      if key.isValid:
        return key
      else:
        return VOID_HASH_KEY
    let rc = db.getKeyBE vid
    if rc.isOk:
      return rc.value
    VOID_HASH_KEY

  let key = getKey(db, vid)
  if key.isValid():
    # debugEcho "ok ", vid, " ", key
    return ok key

  #let vtx = db.getVtx(vid)
  #doAssert vtx.isValid()
  let vtx = ? db.getVtxRc vid

  # TODO this is the same code as when serializing NodeRef, without the NodeRef
  var rlp = initRlpWriter()

  case vtx.vType:
  of Leaf:
    rlp.startList(2)
    rlp.append(vtx.lPfx.toHexPrefix(isLeaf = true))
    # Need to resolve storage root for account leaf
    case vtx.lData.pType
    of AccountData:
      let vid = vtx.lData.stoID
      let key = if vid.isValid:
        ?db.computeKey(vid)
        # if not key.isValid:
        #   block looseCoupling:
        #     when LOOSE_STORAGE_TRIE_COUPLING:
        #       # Stale storage trie?
        #       if LEAST_FREE_VID <= vid.distinctBase and
        #          not db.getVtx(vid).isValid:
        #         node.lData.account.storageID = VertexID(0)
        #         break looseCoupling
        #     # Otherwise this is a stale storage trie.
        #     return err(@[vid])
      else:
        VOID_HASH_KEY

      rlp.append(encode Account(
        nonce:       vtx.lData.account.nonce,
        balance:     vtx.lData.account.balance,
        storageRoot: key.to(Hash256),
        codeHash:    vtx.lData.account.codeHash)
      )
    of RawData:
      rlp.append(vtx.lData.rawBlob)

  of Branch:
    rlp.startList(17)
    for n in 0..15:
      let vid = vtx.bVid[n]
      if vid.isValid:
        rlp.append(?db.computeKey(vid))
      else:
        rlp.append(VOID_HASH_KEY)
    rlp.append EmptyBlob

  of Extension:
    rlp.startList(2)
    rlp.append(vtx.ePfx.toHexPrefix(isleaf = false))
    rlp.append(?db.computeKey(vtx.eVid))

  let h = rlp.finish().digestTo(HashKey)
  # TODO This shouldn't necessarily go into the database if we're just computing
  #      a key ephemerally - it should however be cached for some tiem since
  #      deep hash computations are expensive
  # debugEcho "putkey ", vtx.vType, " ", vid, " ", h, " ", toHex(rlp.finish)
  db.layersPutKey(VertexID(1), vid, h)
  ok h



# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
