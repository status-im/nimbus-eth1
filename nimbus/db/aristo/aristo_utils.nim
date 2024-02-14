# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  std/[sequtils, tables, typetraits],
  eth/common,
  results,
  "."/[aristo_constants, aristo_desc, aristo_get, aristo_hike, aristo_layers]

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
      return err(AccRlpDecodingError)
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
  err AccVtxUnsupported

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
        return err(AccRlpDecodingError)
    of AccountData:
      var acc = Account(
        nonce:       node.lData.account.nonce,
        balance:     node.lData.account.balance,
        codeHash:    node.lData.account.codehash,
        storageRoot: EMPTY_ROOT_HASH)
      if node.lData.account.storageID.isValid:
        if not node.key[0].isValid:
          return err(AccStorageKeyMissing)
        acc.storageRoot = node.key[0].to(Hash256)
      return ok(acc)
    else:
      return err(PayloadTypeUnsupported)

  err AccNodeUnsupported

# ---------------------

proc toNode*(
    vtx: VertexRef;                    # Vertex to convert
    db: AristoDbRef;                   # Database, top layer
    stopEarly = true;                  # Full list of missing links if `false`
    beKeyOk = true;                    # Allow fetching DB backend keys
      ): Result[NodeRef,seq[VertexID]] =
  ## Convert argument the vertex `vtx` to a node type. Missing Merkle hash
  ## keys are searched for on the argument database `db`.
  ##
  ## On error, at least the vertex ID of the first missing Merkle hash key is
  ## returned. If the argument `stopEarly` is set `false`, all missing Merkle
  ## hash keys are returned.
  ##
  ## In the argument `beKeyOk` is set `false`, keys for node links are accepted
  ## only from the cache layer. This does not affect a link key for a payload
  ## storage root.
  ##
  proc getKey(db: AristoDbRef; vid: VertexID; beOk: bool): HashKey =
    block body:
      let key = db.layersGetKey(vid).valueOr:
        break body
      if key.isValid:
        return key
      else:
        return VOID_HASH_KEY
    if beOk:
      let rc = db.getKeyBE vid
      if rc.isOk:
        return rc.value
    VOID_HASH_KEY

  case vtx.vType:
  of Leaf:
    let node = NodeRef(vType: Leaf, lPfx: vtx.lPfx, lData: vtx.lData)
    # Need to resolve storage root for account leaf
    if vtx.lData.pType == AccountData:
      let vid = vtx.lData.account.storageID
      if vid.isValid:
        let key = db.getKey vid
        if not key.isValid:
          block looseCoupling:
            when LOOSE_STORAGE_TRIE_COUPLING:
              # Stale storage trie?
              if LEAST_FREE_VID <= vid.distinctBase and
                 not db.getVtx(vid).isValid:
                node.lData.account.storageID = VertexID(0)
                break looseCoupling
            # Otherwise this is a stale storage trie.
            return err(@[vid])
        node.key[0] = key
    return ok node

  of Branch:
    let node = NodeRef(vType: Branch, bVid: vtx.bVid)
    var missing: seq[VertexID]
    for n in 0 .. 15:
      let vid = vtx.bVid[n]
      if vid.isValid:
        let key = db.getKey(vid, beOk=beKeyOk)
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
      key = db.getKey(vid, beOk=beKeyOk)
    if not key.isValid:
      return err(@[vid])
    let node = NodeRef(vType: Extension, ePfx: vtx.ePfx, eVid: vid)
    node.key[0] = key
    return ok node


proc subVids*(vtx: VertexRef): seq[VertexID] =
  ## Returns the list of all sub-vertex IDs for the argument `vtx`.
  case vtx.vType:
  of Leaf:
    if vtx.lData.pType == AccountData:
      let vid = vtx.lData.account.storageID
      if vid.isValid:
        result.add vid
  of Branch:
    for vid in vtx.bVid:
      if vid.isValid:
        result.add vid
  of Extension:
    result.add vtx.eVid

# ---------------------

proc registerAccount*(
    db: AristoDbRef;                   # Database, top layer
    stoRoot: VertexID;                 # Storage root ID
    accPath: PathID;                   # Needed for accounts payload
       ): Result[void,AristoError] =
  ## Verify that the `stoRoot` argument is properly referred to by the
  ## account data (if any) implied to by the `accPath` argument.
  ##
  # Verify storage root and account path
  if not stoRoot.isValid:
    return err(UtilsStoRootMissing)
  if not accPath.isValid:
    return err(UtilsAccPathMissing)

  # Check whether the account is marked for re-hash, already
  let lty = LeafTie(root: VertexID(1), path: accPath)
  if db.lTab.hasKey lty:
    return ok()

  # Get account leaf with account data
  let rc = lty.hikeUp(db)
  let hike = block:
    if rc.isErr:
      return err(UtilsAccUnaccessible)
    rc.value

  let wp = hike.legs[^1].wp
  if wp.vtx.vType != Leaf:
    return err(UtilsAccPathWithoutLeaf)
  if wp.vtx.lData.pType != AccountData:
    return ok() # nothing to do

  # Need to flag for re-hash
  let stoID = wp.vtx.lData.account.storageID
  if stoID.isValid and stoID != stoRoot:
    return err(UtilsAccWrongStorageRoot)

  # Clear Merkle keys and store leaf record
  for w in hike.legs.mapIt(it.wp.vid):
    db.layersResKey w
  db.top.final.lTab[lty] = wp.vid

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
