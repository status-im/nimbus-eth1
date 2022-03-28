{.used.}

import
  std/os,
  unittest2,
  chronicles,
  eth/db/kvstore,
  ../../nimbus/db/kvstore_rocksdb,
  eth/../tests/db/test_kvstore

proc kvstorerocksdbMain*() =
  suite "RocksStoreRef":
    test "KvStore interface":
      debugecho "a"
      let tmp = getTempDir() / "nimbus-test-db"
      removeDir(tmp)

      debugecho "b"
      let db = RocksStoreRef.init(tmp, "test")[]
      debugEcho "c"
      defer:
        debugEcho "f"
        db.close()

      debugEcho "d"

      testKvStore(kvStore db, false)
      debugecho "e"