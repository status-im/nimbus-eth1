import
  unittest, macros, os,
  nimcrypto/[keccak, hash], ranges, eth_common/eth_types,
  ../nimbus/db/[storage_types],
  ../nimbus/db/backends/[sqlite_backend, rocksdb_backend]

template dummyInstance(T: type SqliteChainDB): auto =
  sqlite_backend.newChainDB ":memory:"

template dummyInstance(T: type RocksChainDB): auto =
  let tmp = getTempDir() / "nimbus-test-db"
  removeDir(tmp)
  rocksdb_backend.newChainDB(tmp)

template backendTests(DB) =
  suite("storage tests: " & astToStr(DB)):
    setup:
      var db = dummyInstance(DB)

    teardown:
      close(db)

    test "basic insertions and deletions":
      var keyA = @(genericHashKey(keccak256.digest("A")).toOpenArray)
      var keyB = @(blockNumberToHashKey(100.toBlockNumber).toOpenArray)
      var value1 = @[1.byte, 2, 3, 4, 5]
      var value2 = @[7.byte, 8, 9, 10]

      db.put(keyA, value1)

      check:
        keyA in db
        keyB notin db

      db.put(keyB, value2)

      check:
        keyA in db
        keyB in db

      check:
        db.get(keyA) == value1
        db.get(keyB) == value2

      db.del(keyA)
      db.put(keyB, value1)

      check:
        keyA notin db
        keyB in db

      check db.get(keyA) == @[]

      check db.get(keyB) == value1
      db.del(keyA)

backendTests(RocksChainDB)
backendTests(SqliteChainDB)

