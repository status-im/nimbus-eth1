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

## Parked here, currently uded only for trancode tests

import
  std/tables,
  eth/common,
  stew/results,
  ../../nimbus/db/aristo/[aristo_desc, aristo_transcode, aristo_vid]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc convertPartially(
    db: AristoDb;
    vtx: VertexRef;
    nd: var NodeRef;
      ): seq[VertexID] =
  ## Returns true if completely converted by looking up the cached hashes.
  ## This function does not recurse. It will return the vertex IDs that are
  ## are missing in order to convert in a single step.
  case vtx.vType:
  of Leaf:
    nd = NodeRef(
      vType: Leaf,
      lPfx:  vtx.lPfx,
      lData: vtx.lData)
  of Extension:
    nd = NodeRef(
      vType: Extension,
      ePfx:  vtx.ePfx,
      eVid:  vtx.eVid)
    let key = db.top.kMap.getOrVoid vtx.eVid
    if key.isValid:
      nd.key[0] = key
      return
    result.add vtx.eVid
  of Branch:
    nd = NodeRef(
      vType: Branch,
      bVid:  vtx.bVid)
    for n in 0..15:
      if vtx.bVid[n].isValid:
        let key = db.top.kMap.getOrVoid vtx.bVid[n]
        if key.isValid:
          nd.key[n] = key
          continue
      result.add vtx.bVid[n]

proc convertPartiallyOk(
    db: AristoDb;
    vtx: VertexRef;
    nd: var NodeRef;
      ): bool =
  ## Variant of `convertPartially()`, shortcut for `convertPartially().le==0`.
  case vtx.vType:
  of Leaf:
    nd = NodeRef(
      vType: Leaf,
      lPfx:  vtx.lPfx,
      lData: vtx.lData)
    result = true
  of Extension:
    nd = NodeRef(
      vType: Extension,
      ePfx:  vtx.ePfx,
      eVid:  vtx.eVid)
    let key = db.top.kMap.getOrVoid vtx.eVid
    if key.isValid:
      nd.key[0] = key
      result = true
  of Branch:
    nd = NodeRef(
      vType: Branch,
      bVid:  vtx.bVid)
    result = true
    for n in 0..15:
      if vtx.bVid[n].isValid:
        let key = db.top.kMap.getOrVoid vtx.bVid[n]
        if key.isValid:
          nd.key[n] = key
          continue
        return false

proc cachedVID(db: AristoDb; nodeKey: NodeKey): VertexID =
  ## Get vertex ID from reverse cache
  let vid = db.top.pAmk.getOrDefault(nodeKey, VertexID(0))
  if vid != VertexID(0):
    result = vid
  else:
    result = db.vidFetch()
    db.top.pAmk[nodeKey] = result
    db.top.kMap[result] = nodeKey

# ------------------------------------------------------------------------------
# Public functions for `VertexID` => `NodeKey` mapping
# ------------------------------------------------------------------------------

proc pal*(db: AristoDb; vid: VertexID): NodeKey =
  ## Retrieve the cached `Merkel` hash (aka `NodeKey` object) associated with
  ## the argument `VertexID` type argument `vid`. Return a zero `NodeKey` if
  ## there is none.
  ##
  ## If the vertex ID `vid` is not found in the cache, then the structural
  ## table is checked whether the cache can be updated.
  if not db.top.isNil:

    let key = db.top.kMap.getOrVoid vid
    if key.isValid:
      return key

    let vtx = db.top.sTab.getOrVoid vid
    if vtx.isValid:
      var node: NodeRef
      if db.convertPartiallyOk(vtx,node):
        var w = initRlpWriter()
        w.append node
        result = w.finish.keccakHash.data.NodeKey
        db.top.kMap[vid] = result

# ------------------------------------------------------------------------------
# Public funcions extending/completing vertex records
# ------------------------------------------------------------------------------

proc updated*(nd: NodeRef; db: AristoDb): NodeRef =
  ## Return a copy of the argument node `nd` with updated missing vertex IDs.
  ##
  ## For a `Leaf` node, the payload data `PayloadRef` type reference is *not*
  ## duplicated and returned as-is.
  ##
  ## This function will not complain if all `Merkel` hashes (aka `NodeKey`
  ## objects) are zero for either `Extension` or `Leaf` nodes.
  if nd.isValid:
    case nd.vType:
    of Leaf:
      result = NodeRef(
        vType: Leaf,
        lPfx:  nd.lPfx,
        lData: nd.lData)
    of Extension:
      result = NodeRef(
        vType:  Extension,
        ePfx:   nd.ePfx)
      if nd.key[0].isValid:
        result.eVid = db.cachedVID nd.key[0]
        result.key[0] = nd.key[0]
    of Branch:
      result = NodeRef(
        vType: Branch,
        key:   nd.key)
      for n in 0..15:
        if nd.key[n].isValid:
          result.bVid[n] = db.cachedVID nd.key[n]

proc asNode*(vtx: VertexRef; db: AristoDb): NodeRef =
  ## Return a `NodeRef` object by augmenting missing `Merkel` hashes (aka
  ## `NodeKey` objects) from the cache or from calculated cached vertex
  ## entries, if available.
  ##
  ## If not all `Merkel` hashes are available in a single lookup, then the
  ## result object is a wrapper around an error code.
  if not db.convertPartiallyOk(vtx, result):
    return NodeRef(error: CacheMissingNodekeys)

proc asNode*(rc: Result[VertexRef,AristoError]; db: AristoDb): NodeRef =
  ## Variant of `asNode()`.
  if rc.isErr:
    return NodeRef(error: rc.error)
  rc.value.asNode(db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
