# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  KvtTxRef* = ref object
    ## Transaction descriptor
    db*: KvtDbRef                     ## Database descriptor
    parent*: KvtTxRef                 ## Previous transaction
    txUid*: uint                      ## Unique ID among transactions
    level*: int                       ## Stack index for this transaction

  DudesRef = ref object
    ## List of peers accessing the same database. This list is layzily
    ## allocated and might be kept with a single entry, i.e. so that
    ## `{centre} == peers`.
    centre: KvtDbRef                  ## Link to peer with write permission
    peers: HashSet[KvtDbRef]          ## List of all peers

  KvtDbRef* = ref KvtDbObj
  KvtDbObj* = object
    ## Three tier database object supporting distributed instances.
    top*: LayerRef                    ## Database working layer, mutable
    stack*: seq[LayerRef]             ## Stashed immutable parent layers
    roFilter*: LayerDeltaRef          ## Apply read filter (locks writing)
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
  db.dudes.isNil or db.dudes.centre == db

func getCentre*(db: KvtDbRef): KvtDbRef =
  ## Get the centre descriptor among all other descriptors accessing the same
  ## backend database (see comments on `reCentre()` for details.)
  ##
  if db.dudes.isNil: db else: db.dudes.centre

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
  if not db.dudes.isNil:
    db.dudes.centre = db

proc fork*(
    db: KvtDbRef;
    noTopLayer = false;
    noFilter = false;
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
  ## If the argument `noFilter` is set `true` the function will fork directly
  ## off the backend database and ignore any filter.
  ##
  # Make sure that there is a dudes list
  if db.dudes.isNil:
    db.dudes = DudesRef(centre: db, peers: @[db].toHashSet)

  let clone = KvtDbRef(
    backend: db.backend,
    dudes:   db.dudes)

  if not noFilter:
    clone.roFilter = db.roFilter # Ref is ok here (filters are immutable)

  if not noTopLayer:
    clone.top = LayerRef.init()

  # Add to peer list of clones
  db.dudes.peers.incl clone

  ok clone

iterator forked*(db: KvtDbRef): KvtDbRef =
  ## Interate over all non centre descriptors (see comments on `reCentre()`
  ## for details.)
  if not db.dudes.isNil:
    for dude in db.dudes.peers.items:
      if dude != db.dudes.centre:
        yield dude

func nForked*(db: KvtDbRef): int =
  ## Returns the number of non centre descriptors (see comments on `reCentre()`
  ## for details.) This function is a fast version of `db.forked.toSeq.len`.
  if not db.dudes.isNil:
    return db.dudes.peers.len - 1


proc forget*(db: KvtDbRef): Result[void,KvtError] =
  ## Destruct the non centre argument `db` descriptor (see comments on
  ## `reCentre()` for details.)
  ##
  ## A non centre descriptor should always be destructed after use (see also
  ## comments on `fork()`.)
  ##
  if db.isCentre:
    err(NotAllowedOnCentre)
  elif db notin db.dudes.peers:
    err(StaleDescriptor)
  else:
    db.dudes.peers.excl db         # Unlink argument `db` from peers list
    ok()

proc forgetOthers*(db: KvtDbRef): Result[void,KvtError] =
  ## For the centre argument `db` descriptor (see comments on `reCentre()`
  ## for details), release all other descriptors accessing the same backend.
  ##
  if not db.dudes.isNil:
    if db.dudes.centre != db:
      return err(MustBeOnCentre)

    db.dudes = DudesRef(nil)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
