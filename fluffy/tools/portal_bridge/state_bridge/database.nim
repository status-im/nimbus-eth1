# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/[os, sequtils], results, eth/trie/db, rocksdb

export results, db

const COL_FAMILY_NAME_ACCOUNTS = "A"
const COL_FAMILY_NAME_STORAGE = "S"
const COL_FAMILY_NAME_BYTECODE = "B"

const COL_FAMILY_NAMES =
  [COL_FAMILY_NAME_ACCOUNTS, COL_FAMILY_NAME_STORAGE, COL_FAMILY_NAME_BYTECODE]

type
  AccountsBackend = ref object of RootObj
    cf: ColFamilyReadWrite

  StorageBackend = ref object of RootObj
    cf: ColFamilyReadWrite

  BytecodeBackend = ref object of RootObj
    cf: ColFamilyReadWrite

  DatabaseBackend = AccountsBackend | StorageBackend | BytecodeBackend

  DatabaseRef* = ref object
    db: RocksDbRef
    accountsBackend: AccountsBackend
    storageBackend: StorageBackend
    bytecodeBackend: BytecodeBackend

proc init*(T: type DatabaseRef, dbPath: string): Result[T, string] =
  try:
    createDir(dbPath)
  except OSError, IOError:
    return err("DatabaseRef: cannot create database directory")

  let cfOpts = defaultColFamilyOptions(autoClose = true)
  cfOpts.`compression=` Compression.lz4Compression
  cfOpts.`bottommostCompression=` Compression.zstdCompression

  let
    db =
      ?openRocksDb(
        dbPath,
        columnFamilies = COL_FAMILY_NAMES.mapIt(initColFamilyDescriptor(it, cfOpts)),
      )
    accountsBackend =
      AccountsBackend(cf: db.getColFamily(COL_FAMILY_NAME_ACCOUNTS).get())
    storageBackend = StorageBackend(cf: db.getColFamily(COL_FAMILY_NAME_STORAGE).get())
    bytecodeBackend =
      BytecodeBackend(cf: db.getColFamily(COL_FAMILY_NAME_BYTECODE).get())

  ok(
    T(
      db: db,
      accountsBackend: accountsBackend,
      storageBackend: storageBackend,
      bytecodeBackend: bytecodeBackend,
    )
  )

proc put(dbBackend: DatabaseBackend, key, val: openArray[byte]) {.gcsafe, raises: [].} =
  doAssert dbBackend.cf.put(key, val).isOk()

proc get(
    dbBackend: DatabaseBackend, key: openArray[byte]
): seq[byte] {.gcsafe, raises: [].} =
  dbBackend.cf.get(key).get()

proc del(
    dbBackend: DatabaseBackend, key: openArray[byte]
): bool {.gcsafe, raises: [].} =
  let exists = dbBackend.cf.keyExists(key).get()
  if not exists:
    return false

  dbBackend.cf.delete(key).get()
  return true

proc contains(
    dbBackend: DatabaseBackend, key: openArray[byte]
): bool {.gcsafe, raises: [].} =
  dbBackend.cf.keyExists(key).get()

proc getAccountsBackend*(db: DatabaseRef): TrieDatabaseRef =
  trieDB(db.accountsBackend)

proc getStorageBackend*(db: DatabaseRef): TrieDatabaseRef =
  trieDB(db.storageBackend)

proc getBytecodeBackend*(db: DatabaseRef): TrieDatabaseRef =
  trieDB(db.bytecodeBackend)

# TODO: support for begin and commit, rollback transactions across column families

# TODO: need to support caching a set of updated keys

proc close*(db: DatabaseRef) =
  db.db.close()
