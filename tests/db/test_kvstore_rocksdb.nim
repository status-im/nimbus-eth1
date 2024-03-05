# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.


{.used.}

import
  std/os,
  unittest2,
  eth/db/kvstore,
  ../../nimbus/db/kvstore_rocksdb,
  eth/../tests/db/test_kvstore

suite "KvStore RocksDb Tests":
  const
    NS_DEFAULT = "default"
    NS_OTHER = "other"
    key = [0'u8, 1, 2, 3]
    value = [3'u8, 2, 1, 0]
    value2 = [5'u8, 2, 1, 0]
    key2 = [255'u8, 255]

  test "RocksStoreRef KvStore interface":
    let tmp = getTempDir() / "nimbus-test-db"
    removeDir(tmp)

    let db = RocksStoreRef.init(tmp, "test")[]
    defer:
      db.close()

    testKvStore(kvStore db, false, false)

  test "RocksNamespaceRef KvStore interface - default namespace":
    let tmp = getTempDir() / "nimbus-test-db"
    removeDir(tmp)

    let db = RocksStoreRef.init(tmp, "test")[]
    defer:
      db.close()

    let defaultNs = db.openNamespace(NS_DEFAULT)[]
    testKvStore(kvStore defaultNs, false, false)

  test "RocksNamespaceRef KvStore interface - multiple namespace":
    let tmp = getTempDir() / "nimbus-test-db"
    removeDir(tmp)

    let db = RocksStoreRef.init(tmp, "test",
        readOnly = false,
        namespaces = @[NS_DEFAULT, NS_OTHER])[]
    defer:
      db.close()

    let defaultNs = db.openNamespace(NS_DEFAULT)[]
    testKvStore(kvStore defaultNs, false, false)

    let otherNs = db.openNamespace(NS_OTHER)[]
    testKvStore(kvStore otherNs, false, false)

  test "RocksStoreRef - read-only":
    let tmp = getTempDir() / "nimbus-test-db"
    removeDir(tmp)

    let db = RocksStoreRef.init(tmp, "test")[]
    check db.put(key, value).isOk()

    # We need to open the db in read-only mode after writing to the database
    # otherwise we won't see the updates.
    let readOnlyDb = RocksStoreRef.init(tmp, "test", readOnly = true)[]
    defer:
      readOnlyDb.close()
      db.close()

    check:
      readOnlyDb.contains(key)[] == true
      readOnlyDb.contains(key2)[] == false

  test "RocksNamespaceRef - read-only":
    let tmp = getTempDir() / "nimbus-test-db"
    removeDir(tmp)

    let db = RocksStoreRef.init(tmp, "test",
        namespaces = @[NS_DEFAULT, NS_OTHER])[]
    let ns = db.openNamespace(NS_OTHER)[]
    check ns.put(key, value).isOk()

    # We need to open the db in read-only mode after writing to the database
    # otherwise we won't see the updates.
    let readOnlyDb = RocksStoreRef.init(tmp, "test",
        readOnly = true,
        namespaces = @[NS_DEFAULT, NS_OTHER])[]
    defer:
      readOnlyDb.close()
      db.close()

    let defaultNs = db.openNamespace(NS_DEFAULT)[]
    check:
      defaultNs.contains(key)[] == false
      defaultNs.contains(key2)[] == false

    let otherNs = db.openNamespace(NS_OTHER)[]
    check:
      otherNs.contains(key)[] == true
      otherNs.contains(key2)[] == false
