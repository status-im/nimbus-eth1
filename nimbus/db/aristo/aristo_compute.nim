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
  eth/common,
  results,
  "."/[aristo_desc, aristo_get, aristo_layers, aristo_serialise]

proc computeKey*(
    db: AristoDbRef;                  # Database, top layer
    rvid: RootedVertexID;             # Vertex to convert
      ): Result[HashKey, AristoError] =
  # This is a variation on getKeyRc which computes the key instead of returning
  # an error
  # TODO it should not always write the key to the persistent storage

  proc getKey(db: AristoDbRef; rvid: RootedVertexID): HashKey =
    block body:
      let key = db.layersGetKey(rvid).valueOr:
        break body
      if key.isValid:
        return key
      else:
        return VOID_HASH_KEY
    let rc = db.getKeyBE rvid
    if rc.isOk:
      return rc.value
    VOID_HASH_KEY

  let key = getKey(db, rvid)
  if key.isValid():
    return ok key

  let vtx = ? db.getVtxRc rvid

  # TODO this is the same code as when serializing NodeRef, without the NodeRef
  var writer = initRlpWriter()

  case vtx.vType:
  of Leaf:
    writer.startList(2)
    writer.append(vtx.lPfx.toHexPrefix(isLeaf = true))
    # Need to resolve storage root for account leaf
    case vtx.lData.pType
    of AccountData:
      let
        stoID = vtx.lData.stoID
        key = if stoID.isValid:
          ?db.computeKey((stoID, stoID))
        else:
          VOID_HASH_KEY

      writer.append(encode Account(
        nonce:       vtx.lData.account.nonce,
        balance:     vtx.lData.account.balance,
        storageRoot: key.to(Hash256),
        codeHash:    vtx.lData.account.codeHash)
      )
    of RawData:
      writer.append(vtx.lData.rawBlob)
    of StoData:
      # TODO avoid memory allocation when encoding storage data
      writer.append(rlp.encode(vtx.lData.stoData))

  of Branch:
    writer.startList(17)
    for n in 0..15:
      let vid = vtx.bVid[n]
      if vid.isValid:
        writer.append(?db.computeKey((rvid.root, vid)))
      else:
        writer.append(VOID_HASH_KEY)
    writer.append EmptyBlob

  of Extension:
    writer.startList(2)
    writer.append(vtx.ePfx.toHexPrefix(isleaf = false))
    writer.append(?db.computeKey((rvid.root, vtx.eVid)))

  let h = writer.finish().digestTo(HashKey)
  # TODO This shouldn't necessarily go into the database if we're just computing
  #      a key ephemerally - it should however be cached for some tiem since
  #      deep hash computations are expensive
  db.layersPutKey(rvid, h)
  ok h



# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
