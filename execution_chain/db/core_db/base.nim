# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/typetraits,
  eth/common/[accounts, base, hashes],
  ../../constants,
  ../[kvt, aristo],
  ./base/[base_desc, base_helpers]

export
  CoreDbAccount,
  CoreDbErrorCode,
  CoreDbError,
  CoreDbPersistentTypes,
  CoreDbRef,
  CoreDbTxRef,
  CoreDbType

import
  ../aristo/[
    aristo_delete, aristo_desc, aristo_fetch, aristo_merge, aristo_part,
    aristo_tx_frame],
  ../kvt/[kvt_desc, kvt_utils, kvt_tx_frame]

# ------------------------------------------------------------------------------
# Public context constructors and administration
# ------------------------------------------------------------------------------

proc baseTxFrame*(db: CoreDbRef): CoreDbTxRef =
  ## The base tx frame is a staging are for reading and writing "almost"
  ## directly from/to the database without using any pending frames - when a
  ## transaction created using `beginTxFrame` is committed, it ultimately ends
  ## up in the base txframe before being persisted to the database with a
  ## persist call.

  CoreDbTxRef(
    aTx: db.mpt.baseTxFrame(),
    kTx: db.kvt.baseTxFrame())

# ------------------------------------------------------------------------------
# Public base descriptor methods
# ------------------------------------------------------------------------------

proc finish*(db: CoreDbRef; eradicate = false) =
  ## Database destructor. If the argument `eradicate` is set `false`, the
  ## database is left as-is and only the in-memory handlers are cleaned up.
  ##
  ## Otherwise the destructor is allowed to remove the database. This feature
  ## depends on the backend database. Currently, only the `AristoDbRocks` type
  ## backend removes the database on `true`.
  ##
  db.kvt.finish(eradicate)
  db.mpt.finish(eradicate)

proc `$$`*(e: CoreDbError): string =
  ## Pretty print error symbol
  ##
  result = $e.error & "("
  result &= (if e.isAristo: "Aristo" else: "Kvt")
  result &= ", ctx=" & $e.ctx & ", error="
  result &= (if e.isAristo: $e.aErr else: $e.kErr)
  result &= ")"

proc persist*(
    db: CoreDbRef;
    txFrame: CoreDbTxRef;
      ) =
  ## This function persists changes up to and including the given frame to the
  ## database.
  ##
  let
    kvtBatch = db.kvt.putBegFn()
    mptBatch = db.mpt.putBegFn()

  if kvtBatch.isOk() and mptBatch.isOk():
    # TODO the `persist` api stages changes but does not actually persist - a
    #      separate "actually-write" api is needed so the changes from both
    #      kvt and ari can be staged and then written together - for this to
    #      happen, we need to expose the shared nature of the write batch
    #      to here and perform a single atomic write.
    #      Because there is nothing in place to handle partial failures (ie
    #      kvt changes written to memory but not to disk because of an aristo
    #      error), we have to panic instead.

    db.kvt.persist(kvtBatch[], txFrame.kTx)
    db.mpt.persist(mptBatch[], txFrame.aTx)

    db.kvt.putEndFn(kvtBatch[]).isOkOr:
      raiseAssert "" & ": " & $error

    db.mpt.putEndFn(mptBatch[]).isOkOr:
      raiseAssert "" & ": " & $error

  else:
    discard kvtBatch.expect("" & ": should always be able to create batch")
    discard mptBatch.expect("" & ": should always be able to create batch")

proc stateBlockNumber*(db: CoreDbTxRef): BlockNumber =
  ## This function returns the block number stored with the latest `persist()`
  ## directive.
  ##
  let rc = db.aTx.fetchLastCheckpoint().valueOr:
    return 0u64

  rc.BlockNumber

proc verify*(
    db: CoreDbRef;
    proof: openArray[seq[byte]];
    root: Hash32;
    path: Hash32;
      ): CoreDbRc[Opt[seq[byte]]] =
  ## Variant of `verify()`.
  let rc = partUntwigPath(proof, root, path).valueOr:
    return err(error.toError("", ProofVerify))

  ok(rc)

# ------------------------------------------------------------------------------
# Public key-value table methods
# ------------------------------------------------------------------------------

# ----------- KVT ---------------

proc get*(kvt: CoreDbTxRef; key: openArray[byte]): CoreDbRc[seq[byte]] =
  ## This function always returns a non-empty `seq[byte]` or an error code.
  let rc = kvt.kTx.get(key)
  if rc.isOk:
    ok(rc.value)
  elif rc.error == GetNotFound:
    err(rc.error.toError("", KvtNotFound))
  else:
    err(rc.error.toError(""))

proc getOrEmpty*(kvt: CoreDbTxRef; key: openArray[byte]): CoreDbRc[seq[byte]] =
  ## Variant of `get()` returning an empty `seq[byte]` if the key is not found
  ## on the database.
  ##
  let rc = kvt.kTx.get(key)
  if rc.isOk:
    ok(rc.value)
  elif rc.error == GetNotFound:
    CoreDbRc[seq[byte]].ok(EmptyBlob)
  else:
    err(rc.error.toError(""))

proc len*(kvt: CoreDbTxRef; key: openArray[byte]): CoreDbRc[int] =
  ## This function returns the size of the value associated with `key`.
  let rc = kvt.kTx.len(key)
  if rc.isOk:
    ok(rc.value)
  elif rc.error == GetNotFound:
    err(rc.error.toError("", KvtNotFound))
  else:
    err(rc.error.toError(""))

proc del*(kvt: CoreDbTxRef; key: openArray[byte]): CoreDbRc[void] =
  kvt.kTx.del(key).isOkOr:
    return err(error.toError(""))

  ok()

proc put*(
    kvt: CoreDbTxRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  kvt.kTx.put(key, val).isOkOr:
    return err(error.toError(""))

  ok()

proc hasKeyRc*(kvt: CoreDbTxRef; key: openArray[byte]): CoreDbRc[bool] =
  ## For the argument `key` return `true` if `get()` returned a value on
  ## that argument, `false` if it returned `GetNotFound`, and an error
  ## otherwise.
  ##
  let rc = kvt.kTx.hasKeyRc(key).valueOr:
    return err(error.toError(""))

  ok(rc)

proc hasKey*(kvt: CoreDbTxRef; key: openArray[byte]): bool =
  ## Simplified version of `hasKeyRc` where `false` is returned instead of
  ## an error.
  ##
  ## This function prototype is in line with the `hasKey` function for
  ## `Tables`.
  ##
  result = kvt.kTx.hasKeyRc(key).valueOr: false

# ------------------------------------------------------------------------------
# Public methods for accounts
# ------------------------------------------------------------------------------

# ----------- accounts ---------------

proc proof*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): CoreDbRc[(seq[seq[byte]],bool)] =
  ## On the accounts MPT, collect the nodes along the `accPath` interpreted as
  ## path. Return these path nodes as a chain of rlp-encoded blobs followed
  ## by a bool value which is `true` if the `key` path exists in the database,
  ## and `false` otherwise. In the latter case, the chain of rlp-encoded blobs
  ## are the nodes proving that the `key` path does not exist.
  ##
  let rc = acc.aTx.partAccountTwig(accPath).valueOr:
    return err(error.toError("", ProofCreate))

  ok(rc)

proc fetch*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): CoreDbRc[CoreDbAccount] =
  ## Fetch the account data record for the particular account indexed by
  ## the key `accPath`.
  ##
  let rc = acc.aTx.fetchAccountRecord(accPath)
  if rc.isOk:
    ok(rc.value)
  elif rc.error == FetchPathNotFound:
    err(rc.error.toError("", AccNotFound))
  else:
    err(rc.error.toError(""))

proc delete*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): CoreDbRc[void] =
  ## Delete the particular account indexed by the key `accPath`. This
  ## will also destroy an associated storage area.
  ##
  let rc = acc.aTx.deleteAccountRecord(accPath)
  if rc.isOk:
    ok()
  elif rc.error == DelPathNotFound:
    # TODO: Would it be conseqient to just return `ok()` here?
    err(rc.error.toError("", AccNotFound))
  else:
    err(rc.error.toError(""))

proc clearStorage*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): CoreDbRc[void] =
  ## Delete all data slots from the storage area associated with the
  ## particular account indexed by the key `accPath`.
  ##
  let rc = acc.aTx.deleteStorageTree(accPath)
  if rc.isOk or rc.error in {DelStoRootMissing,DelStoAccMissing}:
    ok()
  else:
    err(rc.error.toError(""))

proc merge*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    accRec: CoreDbAccount;
      ): CoreDbRc[void] =
  ## Add or update the argument account data record `account`. Note that the
  ## `account` argument uniquely idendifies the particular account address.
  ##
  acc.aTx.mergeAccountRecord(accPath, accRec).isOkOr:
    return err(error.toError(""))

  ok()

proc hasPath*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  let rc = acc.aTx.hasPathAccount(accPath).valueOr:
    return err(error.toError(""))

  ok(rc)

proc getStateRoot*(acc: CoreDbTxRef): CoreDbRc[Hash32] =
  ## This function retrieves the Merkle state hash of the accounts
  ## column (if available.)
  let rc = acc.aTx.fetchStateRoot().valueOr:
    return err(error.toError(""))

  ok(rc)

# ------------ storage ---------------

proc slotProof*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ): CoreDbRc[(seq[seq[byte]],bool)] =
  ## On the storage MPT related to the argument account `acPath`, collect the
  ## nodes along the `stoPath` interpreted as path. Return these path nodes as
  ## a chain of rlp-encoded blobs followed by a bool value which is `true` if
  ## the `key` path exists in the database, and `false` otherwise. In the
  ## latter case, the chain of rlp-encoded blobs are the nodes proving that
  ## the `key` path does not exist.
  ##
  ## Note that the function always returns an error unless the `accPath` is
  ## valid.
  ##
  let rc = acc.aTx.partStorageTwig(accPath, stoPath).valueOr:
    return err(error.toError("", ProofCreate))

  ok(rc)

proc slotFetch*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ):  CoreDbRc[UInt256] =
  ## Like `fetch()` but with cascaded index `(accPath,slot)`.
  let rc = acc.aTx.fetchStorageData(accPath, stoPath)
  if rc.isOk:
    ok(rc.value)
  elif rc.error == FetchPathNotFound:
    err(rc.error.toError("", StoNotFound))
  else:
    err(rc.error.toError(""))

proc slotDelete*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ):  CoreDbRc[void] =
  ## Like `delete()` but with cascaded index `(accPath,slot)`.
  let rc = acc.aTx.deleteStorageData(accPath, stoPath)
  if rc.isOk or rc.error == DelStoRootMissing:
    # The second `if` clause is insane but legit: A storage column was
    # announced for an account but no data have been added, yet.
    ok()
  elif rc.error == DelPathNotFound:
    err(rc.error.toError("", StoNotFound))
  else:
    err(rc.error.toError(""))

proc slotHasPath*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ): CoreDbRc[bool] =
  ## Like `hasPath()` but with cascaded index `(accPath,slot)`.
  let rc = acc.aTx.hasPathStorage(accPath, stoPath).valueOr:
    return err(error.toError(""))

  ok(rc)

proc slotMerge*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    stoPath: Hash32;
    stoData: UInt256;
      ): CoreDbRc[void] =
  ## Like `merge()` but with cascaded index `(accPath,slot)`.
  acc.aTx.mergeStorageData(accPath, stoPath, stoData).isOkOr:
    return err(error.toError(""))

  ok()

proc slotStorageRoot*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): CoreDbRc[Hash32] =
  ## This function retrieves the Merkle state hash of the storage data
  ## column (if available) related to the account  indexed by the key
  ## `accPath`.`.
  ##
  let rc = acc.aTx.fetchStorageRoot(accPath).valueOr:
    return err(error.toError(""))

  ok(rc)

proc slotStorageEmpty*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): CoreDbRc[bool] =
  ## This function returns `true` if the storage data column is empty or
  ## missing.
  ##
  let rc = acc.aTx.hasStorageData(accPath).valueOr:
    return err(error.toError(""))

  ok(not rc)

proc slotStorageEmptyOrVoid*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): bool =
  ## Convenience wrapper, returns `true` where `slotStorageEmpty()` would fail.
  let rc = acc.aTx.hasStorageData(accPath).valueOr:
    return true

  not rc

# ------------- other ----------------

proc recast*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    accRec: CoreDbAccount;
      ): CoreDbRc[Account] =
  ## Complete the argument `accRec` to the portable Ethereum representation
  ## of an account statement. This conversion may fail if the storage colState
  ## hash (see `slotStorageRoot()` above) is currently unavailable.
  ##
  let rc = acc.aTx.fetchStorageRoot(accPath).valueOr:
    return err(error.toError(""))

  ok Account(
    nonce:       accRec.nonce,
    balance:     accRec.balance,
    codeHash:    accRec.codeHash,
    storageRoot: rc)

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

proc txFrameBegin*(db: CoreDbRef): CoreDbTxRef =
  ## Constructor
  ##
  let
    kTx = db.kvt.txFrameBegin(nil)
    aTx = db.mpt.txFrameBegin(nil)

  CoreDbTxRef(kTx: kTx, aTx: aTx)

proc txFrameBegin*(parent: CoreDbTxRef): CoreDbTxRef =
  ## Constructor
  ##
  let
    kTx = parent.kTx.db.txFrameBegin(parent.kTx)
    aTx = parent.aTx.db.txFrameBegin(parent.aTx)

  CoreDbTxRef(kTx: kTx, aTx: aTx)

proc checkpoint*(tx: CoreDbTxRef, blockNumber: BlockNumber, skipSnapshot = false) =
  tx.aTx.checkpoint(blockNumber, skipSnapshot)

proc dispose*(tx: CoreDbTxRef) =
  tx.aTx.dispose()
  tx.kTx.dispose()
  tx[].reset()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
