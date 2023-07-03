# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Patricia Trie layer management
## ===========================================
##

import
  std/[sequtils, tables],
  stew/results,
  "."/[aristo_desc, aristo_get, aristo_vid]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc cpy(layer: AristoLayerRef): AristoLayerRef =
  new result
  result[] = layer[]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc retool*(
    db: AristoDbRef;
    flushStack = false;
      ): Result[void,AristoError] =
  ## This function re-initialises the top layer cache to its default value. It
  ## acts as sort of a `rollback()` without a transaction.
  ##
  if 0 < db.stack.len and not flushStack:
    db.top = db.stack[^1].cpy

  else:
    # Initialise new top layer from the backend
    if db.backend.isNil:
      db.top = AristoLayerRef()
    else:
      let rc = db.backend.getIdgFn()
      if rc.isErr:
        return err(rc.error)
      db.top = AristoLayerRef(vGen: rc.value)
    if flushStack:
      db.stack.setLen(0)


proc push*(db: var AristoDbRef) =
  ## Save the current cache state on the stack and continue working on a copy
  ## of that state.
  ##
  db.stack.add db.top.cpy

proc pop*(
    db: AristoDbRef;
    merge = true;
      ): Result[void,(VertexID,AristoError)] =
  ## Reduce the cache state stack. If the argument `merge` is set `true`, the
  ## current top layer cache remains active and the top item of the stack is
  ## discarded. Otherwise if  `merge` is set `false`, top item of the stack is
  ## popped onto current top layer cache (so replacing it.)
  ##
  if db.stack.len == 0:
    return err((VertexID(0),PopStackUnderflow))

  if not merge:
    # Roll back to parent layer state.
    db.top = db.stack[^1]
  db.stack.setLen(db.stack.len-1)

  ok()


proc save*(
    db: AristoDbRef;                       # Database to be updated
      ): Result[void,(VertexID,AristoError)] =
  ## Save the top layer cache onto the persistent database. There is no check
  ## whether the current layer is fully consistent as a Merkle Patricia Tree.
  ## It is advised to run `hashify()` on the top layer before calling `save()`.
  ##
  ## After successful storage, all parent layers are cleared as well as the
  ## the top layer cache.
  ##
  ## Upon successful return, the previous state of the backend data is saved
  ## as a new entry in `history` field of the argument descriptor `db`.
  ##
  let be = db.backend
  if be.isNil:
    return err((VertexID(0),SaveBackendMissing))

  # Get Merkle hash for state root
  let key = db.getKey VertexID(1)
  if not key.isValid:
    return err((VertexID(1),SaveStateRootMissing))

  let hst = AristoChangeLogRef(root: key)       # Change history, previous state

  # Record changed `Leaf` nodes into the history table
  for (lky,vid) in db.top.lTab.pairs:
    if vid.isValid:
      # Get previous payload for this vertex
      let rc = db.getVtxBackend vid
      if rc.isErr:
        if rc.error != GetVtxNotFound:
          return err((vid,rc.error))            # Stop
        hst.leafs[lky] = PayloadRef(nil)        # So this is a new leaf vertex
      elif rc.value.vType == Leaf:
        hst.leafs[lky] = rc.value.lData         # Record previous payload
      else:
        return err((vid,SaveLeafVidRepurposed)) # Was re-puropsed
    else:
      hst.leafs[lky] = PayloadRef(nil)          # New leaf vertex

  # Compact recycled nodes
  db.vidReorg()

  # Save structural and other table entries
  let txFrame = be.putBegFn()
  be.putVtxFn(txFrame, db.top.sTab.pairs.toSeq)
  be.putKeyFn(txFrame, db.top.kMap.pairs.toSeq.mapIt((it[0],it[1].key)))
  be.putIdgFn(txFrame, db.top.vGen)
  let w = be.putEndFn txFrame
  if w != AristoError(0):
    return err((VertexID(0),w))

  # Delete stack and clear top
  db.stack.setLen(0)
  db.top = AristoLayerRef(vGen: db.top.vGen)

  # Save history
  db.history.add hst

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
