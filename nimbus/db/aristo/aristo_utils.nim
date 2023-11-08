# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Handy Helpers
## ==========================
##
{.push raises: [].}

import
  eth/common,
  results,
  "."/[aristo_desc, aristo_get]

# ------------------------------------------------------------------------------
# Public functions, converters
# ------------------------------------------------------------------------------

proc toAccount*(
    payload: PayloadRef;
    db: AristoDbRef;
      ): Result[Account,AristoError] =
  ## Converts the argument `payload` to an `Account` type. If the implied
  ## account das a storage slots system associated, the database `db` must
  ## contain the Merkle hash key of the root vertex.
  case payload.pType:
  of RlpData:
    try:
      return ok(rlp.decode(payload.rlpBlob, Account))
    except RlpError:
      return err(AccountRlpDecodingError)
  of AccountData:
    var acc = Account(
      nonce:       payload.account.nonce,
      balance:     payload.account.balance,
      codeHash:    payload.account.codehash,
      storageRoot: EMPTY_ROOT_HASH)
    if payload.account.storageID.isValid:
      acc.storageRoot = (? db.getKeyRc payload.account.storageID).to(Hash256)
    return ok(acc)
  else:
    discard

  err PayloadTypeUnsupported

proc toAccount*(
    vtx: VertexRef;
    db: AristoDbRef;
      ): Result[Account,AristoError] =
  ## Variant of `toAccount()` for a `Leaf` vertex.
  if vtx.isValid and vtx.vType == Leaf:
    return vtx.lData.toAccount db
  err AccountVtxUnsupported

proc toAccount*(
    node: NodeRef;
      ): Result[Account,AristoError] =
  ## Variant of `toAccount()` for a `Leaf` node which must be complete (i.e.
  ## a potential Merkle hash key must have been initialised.)
  if node.isValid and node.vType == Leaf:
    case node.lData.pType:
    of RlpData:
      try:
        return ok(rlp.decode(node.lData.rlpBlob, Account))
      except RlpError:
        return err(AccountRlpDecodingError)
    of AccountData:
      var acc = Account(
        nonce:       node.lData.account.nonce,
        balance:     node.lData.account.balance,
        codeHash:    node.lData.account.codehash,
        storageRoot: EMPTY_ROOT_HASH)
      if node.lData.account.storageID.isValid:
        if not node.key[0].isValid:
          return err(AccountStorageKeyMissing)
        acc.storageRoot = node.key[0].to(Hash256)
      return ok(acc)
    else:
      return err(PayloadTypeUnsupported)

  err AccountNodeUnsupported

# ---------------------

proc toNode*(
    vtx: VertexRef;                    # Vertex to convert
    db: AristoDbRef;                   # Database, top layer
    stopEarly = true;                  # Full list of missing links if `false`
    beKeyOk = false;                   # Allow fetching DB backend keys
      ): Result[NodeRef,seq[VertexID]] =
  ## Convert argument the vertex `vtx` to a node type. Missing Merkle hash
  ## keys are searched for on the argument database `db`.
  ##
  ## If backend keys are allowed by passing `beKeyOk` as `true`, there is no
  ## compact embedding of a small node into another rather than its hash
  ## reference. In that case, the hash reference will always be used.
  ##
  ## On error, at least the vertex ID of the first missing Merkle hash key is
  ## returned. If the argument `stopEarly` is set `false`, all missing Merkle
  ## hash keys are returned.
  ##
  case vtx.vType:
  of Leaf:
    let node = NodeRef(vType: Leaf, lPfx: vtx.lPfx, lData: vtx.lData)
    # Need to resolve storage root for account leaf
    if vtx.lData.pType == AccountData:
      let vid = vtx.lData.account.storageID
      if vid.isValid:
        let key = db.getKey vid
        if key.isValid:
          node.key[0] = key
        else:
          return err(@[vid])
        node.key[0] = key
    return ok node

  of Branch:
    let node = NodeRef(vType: Branch, bVid: vtx.bVid)
    var missing: seq[VertexID]
    for n in 0 .. 15:
      let vid = vtx.bVid[n]
      if vid.isValid:
        let key = db.getKey vid
        if key.isValid:
          node.key[n] = key
        elif stopEarly:
          return err(@[vid])
        else:
          missing.add vid
    if 0 < missing.len:
      return err(missing)
    return ok node

  of Extension:
    let
      vid = vtx.eVid
      key = db.getKey vid
    if not key.isValid:
      return err(@[vid])
    let node = NodeRef(vType: Extension, ePfx: vtx.ePfx, eVid: vid)
    node.key[0] = key
    return ok node

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
