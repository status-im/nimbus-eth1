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
        namespaces = @[NS_DEFAULT, NS_OTHER])[]
    defer:
      db.close()

    let defaultNs = db.openNamespace(NS_DEFAULT)[]
    testKvStore(kvStore defaultNs, false, false)

    let otherNs = db.openNamespace(NS_OTHER)[]
    testKvStore(kvStore otherNs, false, false)
