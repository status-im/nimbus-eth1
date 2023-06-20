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
  "."/[aristo_desc, aristo_get]

type
  DeltaHistoryRef* = ref object
    ## Change history for backend saving
    leafs*: Table[LeafTie,PayloadRef] ## Changed leafs after merge into backend

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc cpy(layer: AristoLayerRef): AristoLayerRef =
  new result
  result[] = layer[]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc push*(db: var AristoDb) =
  ## Save a copy of the current delta state on the stack of non-persistent
  ## state layers.
  db.stack.add db.top.cpy


proc pop*(db: var AristoDb; merge = true): AristoError =
  ## Remove the current state later and merge it into the next layer if the
  ## argument `merge` is `true`, and discard it otherwise. The next layer then
  ## becomes the current state.
  ##
  ## Note that merging is sort of a virtual action because the top layer has
  ## always the full latest non-persistent delta state. This implies that in
  ## the case of *merging* just the first parent layer will be discarded.
  ##
  if 0 < db.stack.len:
    if not merge:
      # Roll back to parent layer state
      db.top = db.stack[^1]
    db.stack.setLen(db.stack.len-1)

  elif merge:
    # Accept as-is (there is no parent layer)
    discard

  elif db.backend.isNil:
    db.top = AristoLayerRef()

  else:
    # Initialise new top layer from the backend
    let rc = db.backend.getIdgFn()
    if rc.isErr:
      return rc.error
    db.top = AristoLayerRef(vGen: rc.value)

  AristoError(0)


proc save*(
    db: var AristoDb;                      # Database to be updated
    clear = true;                          # Clear current top level cache
      ): Result[DeltaHistoryRef,AristoError] =
  ## Save top layer into persistent database. There is no check whether the
  ## current layer is fully consistent as a Merkle Patricia Tree. It is
  ## advised to run `hashify()` on the top layer before calling `save()`.
  ##
  ## After successful storage, all parent layers are cleared. The top layer
  ## is also cleared if the `clear` flag is set `true`.
  ##
  ## Upon successful return, the previous state of the backend data is returned
  ## relative to the changes made.
  ##
  let be = db.backend
  if be.isNil:
    return err(SaveBackendMissing)

  let hst = DeltaHistoryRef()              # Change history

  # Record changed `Leaf` nodes into the history table
  for (lky,vid) in db.top.lTab.pairs:
    if vid.isValid:
      # Get previous payload for this vertex
      let rc = db.getVtxBackend vid
      if rc.isErr:
        if rc.error != GetVtxNotFound:
          return err(rc.error)             # Stop
        hst.leafs[lky] = PayloadRef(nil)   # So this is a new leaf vertex
      elif rc.value.vType == Leaf:
        hst.leafs[lky] = rc.value.lData    # Record previous payload
      else:
        hst.leafs[lky] = PayloadRef(nil)   # Was re-puropsed as leaf vertex
    else:
      hst.leafs[lky] = PayloadRef(nil)     # New leaf vertex

  # Save structural and other table entries
  let txFrame = be.putBegFn()
  be.putVtxFn(txFrame, db.top.sTab.pairs.toSeq)
  be.putKeyFn(txFrame, db.top.kMap.pairs.toSeq.mapIt((it[0],it[1].key)))
  be.putIdgFn(txFrame, db.top.vGen)
  let w = be.putEndFn txFrame
  if w != AristoError(0):
    return err(w)

  # Delete stack and clear top
  db.stack.setLen(0)
  if clear:
    db.top = AristoLayerRef(vGen: db.top.vGen)

  ok hst

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
