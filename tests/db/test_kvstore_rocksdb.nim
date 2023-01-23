{.used.}

import
  std/os,
  unittest2,
  chronicles,
  eth/db/kvstore,
  ../../nimbus/db/kvstore_rocksdb,
  eth/../tests/db/test_kvstore

suite "RocksStoreRef":
  test "KvStore interface":
    let tmp = getTempDir() / "nimbus-test-db"
    removeDir(tmp)

    let db = RocksStoreRef.init(tmp, "test")[]
    defer:
      db.close()

    testKvStore(kvStore db, false)
