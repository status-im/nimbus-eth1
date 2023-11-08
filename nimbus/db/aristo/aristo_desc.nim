# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- a Patricia Trie with labeled edges
## ===============================================
##
## These data structures allow to overlay the *Patricia Trie* with *Merkel
## Trie* hashes. See the `README.md` in the `aristo` folder for documentation.
##
## Some semantic explanations;
##
## * HashKey, NodeRef etc. refer to the standard/legacy `Merkle Patricia Tree`
## * VertexID, VertexRef, etc. refer to the `Aristo Trie`
##
{.push raises: [].}

import
  std/[hashes, sets, tables],
  eth/common,
  results,
  ./aristo_constants,
  ./aristo_desc/[desc_error, desc_identifiers, desc_structural]

from ./aristo_desc/desc_backend
  import BackendRef

# Not auto-exporting backend
export
  aristo_constants, desc_error, desc_identifiers, desc_structural

type
  AristoDudes* = HashSet[AristoDbRef]
    ## Descriptor peers asharing the same backend

  AristoTxRef* = ref object
    ## Transaction descriptor
    db*: AristoDbRef                  ## Database descriptor
    parent*: AristoTxRef              ## Previous transaction
    txUid*: uint                      ## Unique ID among transactions
    level*: int                       ## Stack index for this transaction

  MerkleSignRef* = ref object
    ## Simple Merkle signature calculatior for key-value lists
    root*: VertexID
    db*: AristoDbRef
    count*: uint
    error*: AristoError
    errKey*: Blob

  DudesRef = ref object
    case rwOk: bool
    of true:
      roDudes: AristoDudes            ## Read-only peers
      txDudes: AristoDudes            ## Other transaction peers
    else:
      rwDb: AristoDbRef               ## Link to writable descriptor

  AristoDbRef* = ref AristoDbObj
  AristoDbObj* = object
    ## Three tier database object supporting distributed instances.
    top*: LayerRef                    ## Database working layer, mutable
    stack*: seq[LayerRef]             ## Stashed immutable parent layers
    roFilter*: FilterRef              ## Apply read filter (locks writing)
    backend*: BackendRef              ## Backend database (may well be `nil`)

    txRef*: AristoTxRef               ## Latest active transaction
    txUidGen*: uint                   ## Tx-relative unique number generator
    dudes: DudesRef                   ## Related DB descriptors

    # Debugging data below, might go away in future
    xMap*: VidsByLabel                ## For pretty printing, extends `pAmk`

  AristoDbAction* = proc(db: AristoDbRef) {.gcsafe, raises: [].}
    ## Generic call back function/closure.

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func getOrVoid*[W](tab: Table[W,VertexRef]; w: W): VertexRef =
  tab.getOrDefault(w, VertexRef(nil))

func getOrVoid*[W](tab: Table[W,HashLabel]; w: W): HashLabel =
  tab.getOrDefault(w, VOID_HASH_LABEL)

func getOrVoid*[W](tab: Table[W,NodeRef]; w: W): NodeRef =
  tab.getOrDefault(w, NodeRef(nil))

func getOrVoid*[W](tab: Table[W,HashKey]; w: W): HashKey =
  tab.getOrDefault(w, VOID_HASH_KEY)

func getOrVoid*[W](tab: Table[W,VertexID]; w: W): VertexID =
  tab.getOrDefault(w, VertexID(0))

func getOrVoid*[W](tab: Table[W,HashSet[VertexID]]; w: W): HashSet[VertexID] =
  tab.getOrDefault(w, EmptyVidSet)

# --------

func isValid*(vtx: VertexRef): bool =
  vtx != VertexRef(nil) 

func isValid*(nd: NodeRef): bool =
  nd != NodeRef(nil)

func isValid*(pld: PayloadRef): bool =
  pld != PayloadRef(nil)

func isValid*(filter: FilterRef): bool =
  filter != FilterRef(nil)

func isValid*(root: Hash256): bool =
  root != EMPTY_ROOT_HASH

func isValid*(key: HashKey): bool =
  if key.len == 32:
    key.to(Hash256).isValid
  else:
    0 < key.len

func isValid*(vid: VertexID): bool =
  vid != VertexID(0)

func isValid*(lbl: HashLabel): bool =
  lbl.root.isValid and lbl.key.isValid

func isValid*(sqv: HashSet[VertexID]): bool =
  sqv != EmptyVidSet

func isValid*(qid: QueueID): bool =
  qid != QueueID(0)

func isValid*(fid: FilterID): bool =
  fid != FilterID(0)

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

# Hash set helper
func hash*(db: AristoDbRef): Hash =
  ## Table/KeyedQueue/HashSet mixin
  cast[pointer](db).hash

# ------------------------------------------------------------------------------
# Public functions, `dude` related
# ------------------------------------------------------------------------------

func isCentre*(db: AristoDbRef): bool =
  ## This function returns `true` is the argument `db` is the centre (see
  ## comments on `reCentre()` for details.)
  ##
  db.dudes.isNil or db.dudes.rwOk

func getCentre*(db: AristoDbRef): AristoDbRef =
  ## Get the centre descriptor among all other descriptors accessing the same
  ## backend database (see comments on `reCentre()` for details.)
  ##
  if db.dudes.isNil or db.dudes.rwOk:
    db
  else:
    db.dudes.rwDb

proc reCentre*(
    db: AristoDbRef;
    force = false;
      ): Result[void,AristoError] =
  ## Re-focus the `db` argument descriptor so that it becomes the centre.
  ## Nothing is done if the `db` descriptor is the centre, already.
  ##
  ## With several descriptors accessing the same backend database there is a
  ## single one that has write permission for the backend (regardless whether
  ## there is a backend, at all.) The descriptor entity with write permission
  ## is called *the centre*.
  ##
  ## After invoking `reCentre()`, the argument database `db` can only be
  ## destructed by `finish()` which also destructs all other descriptors
  ## accessing the same backend database. Descriptors where `isCentre()`
  ## returns `false` must be single destructed with `forget()`.
  ##
  ## If there is an open transaction spanning several descriptors, the `force`
  ## flag must be set `true` (unless the argument `db` is centre, already.) The
  ## argument `db` must be covered by the transaction span. Then the re-centred
  ## descriptor will also be the centre of the transaction span.
  ##
  if not db.isCentre:
    let parent = db.dudes.rwDb

    # Check for multi-transactions
    if 0 < parent.dudes.txDudes.len:
      if not force:
        return err(CentreTxLocked)
      if db notin parent.dudes.txDudes:
        return err(OutsideTxSpan)
      if db.txRef.isNil or parent.txRef.isNil:
        return err(GarbledTxSpan)

    # Steal dudes list from parent, make the rw-parent a read-only dude
    db.dudes = parent.dudes
    parent.dudes = DudesRef(rwOk: false, rwDb: db)

    # Exclude self
    db.dudes.roDudes.excl db

    # Update dudes
    for w in db.dudes.roDudes:
      # Let all other dudes refer to this one
      w.dudes.rwDb = db

    # Update dudes list (parent was alredy updated)
    db.dudes.roDudes.incl parent

    # Update transaction span
    if 0 < db.dudes.txDudes.len:
      db.dudes.txDudes.excl db
      db.dudes.txDudes.incl parent

  ok()


iterator txSpan*(db: AristoDbRef): AristoDbRef =
  ## Interate over all descriptors belonging to the transaction span if there
  ## is any. Note that the centre descriptor is aways part of the transaction
  ## if there is any.
  ##
  if not db.dudes.isNil:
    let parent = db.getCentre
    if 0 < parent.dudes.txDudes.len:
      yield parent
      for dude in parent.dudes.txDudes.items:
        yield dude

func nTxSpan*(db: AristoDbRef): int =
  ## Returns the number of descriptors belonging to the transaction span. This
  ## function is a fast version of `db.txSpan.toSeq.len`. Note that the
  ## returned numbe is never `1` (either `0` or at least `2`.)
  ##
  if not db.dudes.isNil:
    let parent = db.getCentre
    if 0 < parent.dudes.txDudes.len:
      return 1 + db.getCentre.dudes.txDudes.len

func inTxSpan*(db: AristoDbRef): bool =
  ## Returns `true` if the argument descriptor `db` belongs to the transaction
  ## span if there is any. Note that the centre descriptor is aways part of
  ## the transaction if there is any.
  ##
  if not db.isCentre:
    return db in db.dudes.rwDb.dudes.txDudes
  elif not db.dudes.isNil:
    return 0 < db.dudes.txDudes.len
  false

proc txSpanSet*(dudes: openArray[AristoDbRef]) =
  ## Define the set of argument descriptors as transaction span.
  ##
  if 0 < dudes.len:
    let parent = dudes[0].getCentre
    if not parent.dudes.isNil:
      parent.dudes.txDudes = dudes.toHashSet - [parent].toHashSet

proc txSpanClear*(db: AristoDbRef) =
  ## Remove all descriptors from the transaction span.
  ##
  if not db.isCentre:
    db.dudes.rwDb.dudes.txDudes.clear
  elif not db.dudes.isNil:
    db.dudes.txDudes.clear
      

proc fork*(
    db: AristoDbRef;
    rawToplayer = false;
      ): Result[AristoDbRef,AristoError] =
  ## This function creates a new empty descriptor accessing the same backend
  ## (if any) database as the argument `db`. This new descriptor joins the
  ## list of descriptors accessing the same backend database.
  ##
  ## After use, any unused non centre descriptor should be destructed via
  ## `forget()`. Not doing so will not only hold memory ressources but might
  ## also cost computing ressources for maintaining and updating backend
  ## filters when writing to the backend database .
  ##
  ## If the argument `rawToplayer` is set `true` the function will provide an
  ## uninitalised and inconsistent (!) top layer. This setting avoids some
  ## database lookup for cases where the top layer is redefined anyway.
  ##
  let clone = AristoDbRef(
    top:      LayerRef(),
    backend:  db.backend)

  if not rawToplayer:
    let rc = clone.backend.getIdgFn()
    if rc.isOk:
      clone.top.vGen = rc.value
    elif rc.error != GetIdgNotFound:
      return err(rc.error)

  # Update dudes list
  if db.dudes.isNil:
    clone.dudes = DudesRef(rwOk: false, rwDb: db)
    db.dudes = DudesRef(rwOk: true, roDudes: [clone].toHashSet)
  else:
    let parent = if db.dudes.rwOk: db else: db.dudes.rwDb
    clone.dudes = DudesRef(rwOk: false, rwDb: parent)
    parent.dudes.roDudes.incl clone

  ok clone

iterator forked*(db: AristoDbRef): AristoDbRef =
  ## Interate over all non centre descriptors (see comments on `reCentre()`
  ## for details.)
  if not db.dudes.isNil:
    for dude in db.getCentre.dudes.roDudes.items:
      yield dude

func nForked*(db: AristoDbRef): int =
  ## Returns the number of non centre descriptors (see comments on `reCentre()`
  ## for details.) This function is a fast version of `db.forked.toSeq.len`.
  if not db.dudes.isNil:
    return db.getCentre.dudes.roDudes.len


proc forget*(db: AristoDbRef): Result[void,AristoError] =
  ## Destruct the non centre argument `db` descriptor (see comments on
  ## `reCentre()` for details.)
  ##
  ## A non centre descriptor should always be destructed after use (see also
  ## comments on `fork()`.)
  ##
  if not db.isNil:
    if db.isCentre:
      return err(NotAllowedOnCentre)

    # Unlink argument `db`
    let parent = db.dudes.rwDb
    if parent.dudes.roDudes.len < 2:
      parent.dudes = DudesRef(nil)
    else:
      parent.dudes.roDudes.excl db
      parent.dudes.txDudes.excl db # might be empty, anyway

    # Clear descriptor so it would not do harm if used wrongly
    db[] = AristoDbObj(top: LayerRef())
  ok()

proc forgetOthers*(db: AristoDbRef): Result[void,AristoError] =
  ## For the centre argument `db` descriptor (see comments on `reCentre()`
  ## for details), destruct all other descriptors accessing the same backend.
  ##
  if not db.isCentre:
    return err(MustBeOnCentre)

  if not db.dudes.isNil:
    for dude in db.dudes.roDudes.items:
      dude[] = AristoDbObj(top: LayerRef())

    db.dudes = DudesRef(nil)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
