# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/[os, tables, sequtils], results, eth/trie/db, rocksdb

export results, db

const COL_FAMILY_NAME_ACCOUNTS = "A"
const COL_FAMILY_NAME_STORAGE = "S"
const COL_FAMILY_NAME_BYTECODE = "B"
const COL_FAMILY_NAME_PREIMAGES = "P"

const COL_FAMILY_NAMES = [
  COL_FAMILY_NAME_ACCOUNTS, COL_FAMILY_NAME_STORAGE, COL_FAMILY_NAME_BYTECODE,
  COL_FAMILY_NAME_PREIMAGES,
]

type
  AccountsBackendRef = ref object of RootObj
    cfHandle: ColFamilyHandleRef
    tx: TransactionRef
    updatedCache: TrieDatabaseRef

  StorageBackendRef = ref object of RootObj
    cfHandle: ColFamilyHandleRef
    tx: TransactionRef
    updatedCache: TrieDatabaseRef

  BytecodeBackendRef = ref object of RootObj
    cfHandle: ColFamilyHandleRef
    tx: TransactionRef
    updatedCache: TrieDatabaseRef

  DatabaseBackendRef = AccountsBackendRef | StorageBackendRef | BytecodeBackendRef

  DatabaseRef* = ref object
    rocksDb: OptimisticTxDbRef
    pendingTransaction: TransactionRef
    accountsBackend: AccountsBackendRef
    storageBackend: StorageBackendRef
    bytecodeBackend: BytecodeBackendRef

proc init*(T: type DatabaseRef, baseDir: string): Result[T, string] =
  let dbPath = baseDir / "db"

  try:
    createDir(dbPath)
  except OSError, IOError:
    return err("DatabaseRef: cannot create database directory")

  let cfOpts = defaultColFamilyOptions(autoClose = true)
  cfOpts.`compression=` Compression.lz4Compression
  cfOpts.`bottommostCompression=` Compression.zstdCompression

  let
    db =
      ?openOptimisticTxDb(
        dbPath,
        columnFamilies = COL_FAMILY_NAMES.mapIt(initColFamilyDescriptor(it, cfOpts)),
      )
    accountsBackend = AccountsBackendRef(
      cfHandle: db.getColFamilyHandle(COL_FAMILY_NAME_ACCOUNTS).get()
    )
    storageBackend =
      StorageBackendRef(cfHandle: db.getColFamilyHandle(COL_FAMILY_NAME_STORAGE).get())
    bytecodeBackend = BytecodeBackendRef(
      cfHandle: db.getColFamilyHandle(COL_FAMILY_NAME_BYTECODE).get()
    )

  ok(
    T(
      rocksDb: db,
      pendingTransaction: nil,
      accountsBackend: accountsBackend,
      storageBackend: storageBackend,
      bytecodeBackend: bytecodeBackend,
    )
  )

proc onData(data: openArray[byte]) {.gcsafe, raises: [].} =
  discard # noop used to check if key exists

proc contains(
    dbBackend: DatabaseBackendRef, key: openArray[byte]
): bool {.gcsafe, raises: [].} =
  dbBackend.tx.get(key, onData, dbBackend.cfHandle).get()

proc put(
    dbBackend: DatabaseBackendRef, key, val: openArray[byte]
) {.gcsafe, raises: [].} =
  doAssert dbBackend.tx.put(key, val, dbBackend.cfHandle).isOk()
  if not dbBackend.updatedCache.isNil():
    dbBackend.updatedCache.put(key, val)

proc get(
    dbBackend: DatabaseBackendRef, key: openArray[byte]
): seq[byte] {.gcsafe, raises: [].} =
  if dbBackend.contains(key):
    dbBackend.tx.get(key, dbBackend.cfHandle).get()
  else:
    @[]

proc del(
    dbBackend: DatabaseBackendRef, key: openArray[byte]
): bool {.gcsafe, raises: [].} =
  if dbBackend.contains(key):
    doAssert dbBackend.tx.delete(key, dbBackend.cfHandle).isOk()

    if not dbBackend.updatedCache.isNil():
      dbBackend.updatedCache.del(key)
    true
  else:
    false

proc getAccountsBackend*(db: DatabaseRef): TrieDatabaseRef {.inline.} =
  trieDB(db.accountsBackend)

proc getStorageBackend*(db: DatabaseRef): TrieDatabaseRef {.inline.} =
  trieDB(db.storageBackend)

proc getBytecodeBackend*(db: DatabaseRef): TrieDatabaseRef {.inline.} =
  trieDB(db.bytecodeBackend)

proc getAccountsUpdatedCache*(db: DatabaseRef): TrieDatabaseRef {.inline.} =
  db.accountsBackend.updatedCache

proc getStorageUpdatedCache*(db: DatabaseRef): TrieDatabaseRef {.inline.} =
  db.storageBackend.updatedCache

proc getBytecodeUpdatedCache*(db: DatabaseRef): TrieDatabaseRef {.inline.} =
  db.bytecodeBackend.updatedCache

proc put*(db: DatabaseRef, key, val: openArray[byte]) =
  let tx = db.rocksDb.beginTransaction()
  defer:
    tx.close()

  # using default column family
  doAssert tx.put(key, val).isOk()
  doAssert tx.commit().isOk()

proc get*(db: DatabaseRef, key: openArray[byte]): seq[byte] =
  let tx = db.rocksDb.beginTransaction()
  defer:
    tx.close()

  # using default column family
  if tx.get(key, onData).get():
    tx.get(key).get()
  else:
    @[]

proc beginTransaction*(db: DatabaseRef): Result[void, string] =
  if not db.pendingTransaction.isNil():
    return err("DatabaseRef: Pending transaction already in progress")

  let tx = db.rocksDb.beginTransaction()
  db.pendingTransaction = tx
  db.accountsBackend.tx = tx
  db.storageBackend.tx = tx
  db.bytecodeBackend.tx = tx

  db.accountsBackend.updatedCache = newMemoryDB()
  db.storageBackend.updatedCache = newMemoryDB()
  db.bytecodeBackend.updatedCache = newMemoryDB()

  ok()

proc commitTransaction*(db: DatabaseRef): Result[void, string] =
  if db.pendingTransaction.isNil():
    return err("DatabaseRef: No pending transaction")

  ?db.pendingTransaction.commit()

  db.pendingTransaction.close()
  db.pendingTransaction = nil

  ok()

proc rollbackTransaction*(db: DatabaseRef): Result[void, string] =
  if db.pendingTransaction.isNil():
    return err("DatabaseRef: No pending transaction")

  ?db.pendingTransaction.rollback()

  db.pendingTransaction.close()
  db.pendingTransaction = nil

  ok()

template withTransaction*(db: DatabaseRef, body: untyped): auto =
  db.beginTransaction().expect("Transaction should be started")
  try:
    body
  finally:
    db.commitTransaction().expect("Transaction should be commited")

proc close*(db: DatabaseRef) =
  if not db.pendingTransaction.isNil():
    discard db.rollbackTransaction()

  db.rocksDb.close()
