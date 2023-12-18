# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- key-value table
## =========================
##
{.push raises: [].}

import
  std/[hashes, sets, tables],
  eth/common,
  results,
  ./kvt_constants,
  ./kvt_desc/[desc_error, desc_structural]

from ./kvt_desc/desc_backend
  import BackendRef

# Not auto-exporting backend
export
  kvt_constants, desc_error, desc_structural

type
  KvtDudes* = HashSet[KvtDbRef]
    ## Descriptor peers asharing the same backend

  KvtTxRef* = ref object
    ## Transaction descriptor
    db*: KvtDbRef                     ## Database descriptor
    parent*: KvtTxRef                 ## Previous transaction
    txUid*: uint                      ## Unique ID among transactions
    level*: int                       ## Stack index for this transaction

  DudesRef = ref object
    case rwOk: bool
    of true:
      roDudes: KvtDudes               ## Read-only peers
    else:
      rwDb: KvtDbRef                  ## Link to writable descriptor

  KvtDbRef* = ref KvtDbObj
  KvtDbObj* = object
    ## Three tier database object supporting distributed instances.
    top*: LayerRef                    ## Database working layer, mutable
    stack*: seq[LayerRef]             ## Stashed immutable parent layers
    backend*: BackendRef              ## Backend database (may well be `nil`)

    txRef*: KvtTxRef                  ## Latest active transaction
    txUidGen*: uint                   ## Tx-relative unique number generator
    dudes: DudesRef                   ## Related DB descriptors

    # Debugging data below, might go away in future
    xIdGen*: uint64
    xMap*: Table[Blob,uint64]         ## For pretty printing
    pAmx*: Table[uint64,Blob]         ## For pretty printing

  KvtDbAction* = proc(db: KvtDbRef) {.gcsafe, raises: [].}
    ## Generic call back function/closure.

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func getOrVoid*(tab: Table[Blob,Blob]; w: Blob): Blob =
  tab.getOrDefault(w, EmptyBlob)

func isValid*(key: Blob): bool =
  key != EmptyBlob

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

# Hash set helper
func hash*(db: KvtDbRef): Hash =
  ## Table/KeyedQueue/HashSet mixin
  cast[pointer](db).hash

# ------------------------------------------------------------------------------
# Public functions, `dude` related
# ------------------------------------------------------------------------------

func isCentre*(db: KvtDbRef): bool =
  ## This function returns `true` is the argument `db` is the centre (see
  ## comments on `reCentre()` for details.)
  ##
  db.dudes.isNil or db.dudes.rwOk

func getCentre*(db: KvtDbRef): KvtDbRef =
  ## Get the centre descriptor among all other descriptors accessing the same
  ## backend database (see comments on `reCentre()` for details.)
  ##
  if db.dudes.isNil or db.dudes.rwOk:
    db
  else:
    db.dudes.rwDb

proc reCentre*(db: KvtDbRef) =
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
  if not db.isCentre:
    let parent = db.dudes.rwDb

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


proc fork*(
    db: KvtDbRef;
      ): Result[KvtDbRef,KvtError] =
  ## This function creates a new empty descriptor accessing the same backend
  ## (if any) database as the argument `db`. This new descriptor joins the
  ## list of descriptors accessing the same backend database.
  ##
  ## After use, any unused non centre descriptor should be destructed via
  ## `forget()`. Not doing so will not only hold memory ressources but might
  ## also cost computing ressources for maintaining and updating backend
  ## filters when writing to the backend database .
  ##
  let clone = KvtDbRef(
    top:      LayerRef(),
    backend:  db.backend)

  # Update dudes list
  if db.dudes.isNil:
    clone.dudes = DudesRef(rwOk: false, rwDb: db)
    db.dudes = DudesRef(rwOk: true, roDudes: [clone].toHashSet)
  else:
    let parent = if db.dudes.rwOk: db else: db.dudes.rwDb
    clone.dudes = DudesRef(rwOk: false, rwDb: parent)
    parent.dudes.roDudes.incl clone

  ok clone

iterator forked*(db: KvtDbRef): KvtDbRef =
  ## Interate over all non centre descriptors (see comments on `reCentre()`
  ## for details.)
  if not db.dudes.isNil:
    for dude in db.getCentre.dudes.roDudes.items:
      yield dude

func nForked*(db: KvtDbRef): int =
  ## Returns the number of non centre descriptors (see comments on `reCentre()`
  ## for details.) This function is a fast version of `db.forked.toSeq.len`.
  if not db.dudes.isNil:
    return db.getCentre.dudes.roDudes.len


proc forget*(db: KvtDbRef): Result[void,KvtError] =
  ## Destruct the non centre argument `db` descriptor (see comments on
  ## `reCentre()` for details.)
  ##
  ## A non centre descriptor should always be destructed after use (see also
  ## comments on `fork()`.)
  ##
  if db.isCentre:
    return err(NotAllowedOnCentre)

  # Unlink argument `db`
  let parent = db.dudes.rwDb
  if parent.dudes.roDudes.len < 2:
    parent.dudes = DudesRef(nil)
  else:
    parent.dudes.roDudes.excl db

  # Clear descriptor so it would not do harm if used wrongly
  db[] = KvtDbObj(top: LayerRef())
  ok()

proc forgetOthers*(db: KvtDbRef): Result[void,KvtError] =
  ## For the centre argument `db` descriptor (see comments on `reCentre()`
  ## for details), destruct all other descriptors accessing the same backend.
  ##
  if not db.isCentre:
    return err(MustBeOnCentre)

  if not db.dudes.isNil:
    for dude in db.dudes.roDudes.items:
      dude[] = KvtDbObj(top: LayerRef())

    db.dudes = DudesRef(nil)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
