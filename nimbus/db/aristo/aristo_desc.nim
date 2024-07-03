# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  stew/keyed_queue,
  eth/common,
  results,
  ./aristo_constants,
  ./aristo_desc/[desc_error, desc_identifiers, desc_structural]

from ./aristo_desc/desc_backend
  import BackendRef

# Not auto-exporting backend
export
  aristo_constants, desc_error, desc_identifiers, desc_structural, keyed_queue

const
  accLruSize* = 1024 * 1024
    # LRU cache size for accounts that have storage

type
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
    ## List of peers accessing the same database. This list is layzily
    ## allocated and might be kept with a single entry, i.e. so that
    ## `{centre} == peers`.
    centre: AristoDbRef               ## Link to peer with write permission
    peers: HashSet[AristoDbRef]       ## List of all peers

  AccountKey* = distinct ref Hash256
    # `ref` version of the account path / key
    # `KeyedQueue` is inefficient for large keys, so we have to use this ref
    # workaround to not experience a memory explosion in the account cache
    # TODO rework KeyedQueue to deal with large keys and/or heterogenous lookup

  AristoDbRef* = ref object
    ## Three tier database object supporting distributed instances.
    top*: LayerRef                    ## Database working layer, mutable
    stack*: seq[LayerRef]             ## Stashed immutable parent layers
    balancer*: LayerDeltaRef          ## Baland out concurrent backend access
    backend*: BackendRef              ## Backend database (may well be `nil`)

    txRef*: AristoTxRef               ## Latest active transaction
    txUidGen*: uint                   ## Tx-relative unique number generator
    dudes: DudesRef                   ## Related DB descriptors

    # Debugging data below, might go away in future
    xMap*: Table[HashKey,HashSet[VertexID]] ## For pretty printing/debugging

    accSids*: KeyedQueue[AccountKey, VertexID]
      ## Account path to storage id cache, for contract accounts - storage is
      ## frequently accessed by account path when contracts interact with it -
      ## this cache ensures that we don't have to re-travers the storage trie
      ## path for every such interaction - a better solution would probably be
      ## to cache this in a type exposed to the high-level API

  AristoDbAction* = proc(db: AristoDbRef) {.gcsafe, raises: [].}
    ## Generic call back function/closure.

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

template hash*(a: AccountKey): Hash =
  mixin hash
  hash((ref Hash256)(a)[])

template `==`*(a, b: AccountKey): bool =
  mixin `==`
  (ref Hash256)(a)[] == (ref Hash256)(b)[]

template to*(a: Hash256, T: type AccountKey): T =
  AccountKey((ref Hash256)(data: a.data))

func getOrVoid*[W](tab: Table[W,VertexRef]; w: W): VertexRef =
  tab.getOrDefault(w, VertexRef(nil))

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

func isValid*(pid: PathID): bool =
  pid != VOID_PATH_ID

func isValid*(filter: LayerDeltaRef): bool =
  filter != LayerDeltaRef(nil)

func isValid*(root: Hash256): bool =
  root != EMPTY_ROOT_HASH

func isValid*(key: HashKey): bool =
  assert key.len != 32 or key.to(Hash256).isValid
  0 < key.len

func isValid*(vid: VertexID): bool =
  vid != VertexID(0)

func isValid*(sqv: HashSet[VertexID]): bool =
  sqv != EmptyVidSet

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
  db.dudes.isNil or db.dudes.centre == db

func getCentre*(db: AristoDbRef): AristoDbRef =
  ## Get the centre descriptor among all other descriptors accessing the same
  ## backend database (see comments on `reCentre()` for details.)
  ##
  if db.dudes.isNil: db else: db.dudes.centre

proc reCentre*(db: AristoDbRef): Result[void,AristoError] =
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
  ok()

proc fork*(
    db: AristoDbRef;
    noTopLayer = false;
    noFilter = false;
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
  ## If the argument `noFilter` is set `true` the function will fork directly
  ## off the backend database and ignore any filter.
  ##
  ## If the argument `noTopLayer` is set `true` the function will provide an
  ## uninitalised and inconsistent (!) descriptor object without top layer.
  ## This setting avoids some database lookup for cases where the top layer
  ## is redefined anyway.
  ##
  # Make sure that there is a dudes list
  if db.dudes.isNil:
    db.dudes = DudesRef(centre: db, peers: @[db].toHashSet)

  let clone = AristoDbRef(
    dudes:   db.dudes,
    backend: db.backend)

  if not noFilter:
    clone.balancer = db.balancer # Ref is ok here (filters are immutable)

  if not noTopLayer:
    clone.top = LayerRef.init()
    if not db.balancer.isNil:
      clone.top.delta.vTop = db.balancer.vTop
    else:
      let rc = clone.backend.getTuvFn()
      if rc.isOk:
        clone.top.delta.vTop = rc.value
      elif rc.error != GetTuvNotFound:
        return err(rc.error)

  # Add to peer list of clones
  db.dudes.peers.incl clone

  ok clone

iterator forked*(db: AristoDbRef): AristoDbRef =
  ## Interate over all non centre descriptors (see comments on `reCentre()`
  ## for details.)
  if not db.dudes.isNil:
    for dude in db.getCentre.dudes.peers.items:
      if dude != db.dudes.centre:
        yield dude

func nForked*(db: AristoDbRef): int =
  ## Returns the number of non centre descriptors (see comments on `reCentre()`
  ## for details.) This function is a fast version of `db.forked.toSeq.len`.
  if not db.dudes.isNil:
    return db.dudes.peers.len - 1


proc forget*(db: AristoDbRef): Result[void,AristoError] =
  ## Destruct the non centre argument `db` descriptor (see comments on
  ## `reCentre()` for details.)
  ##
  ## A non centre descriptor should always be destructed after use (see also
  ## comments on `fork()`.)
  ##
  if db.isCentre:
    err(DescNotAllowedOnCentre)
  elif db notin db.dudes.peers:
    err(DescStaleDescriptor)
  else:
    db.dudes.peers.excl db         # Unlink argument `db` from peers list
    ok()

proc forgetOthers*(db: AristoDbRef): Result[void,AristoError] =
  ## For the centre argument `db` descriptor (see comments on `reCentre()`
  ## for details), destruct all other descriptors accessing the same backend.
  ##
  if not db.dudes.isNil:
    if db.dudes.centre != db:
      return err(DescMustBeOnCentre)

    db.dudes = DudesRef(nil)
  ok()

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

iterator rstack*(db: AristoDbRef): LayerRef =
  # Stack in reverse order
  for i in 0..<db.stack.len:
    yield db.stack[db.stack.len - i - 1]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
