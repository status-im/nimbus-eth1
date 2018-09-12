
import ../nimbus/db/backends/caching_backend, eth_trie, eth_trie/memdb, unittest

let
  key1 = [0.byte, 0, 1]
  key2 = [0.byte, 0, 2]
  key3 = [0.byte, 0, 3]
  key4 = [0.byte, 0, 4]
  value1 = [1.byte, 0, 1]
  value2 = [1.byte, 0, 2]
  value3 = [1.byte, 0, 3]
  value4 = [1.byte, 0, 4]

suite "Caching DB backend":
  test "Basic test":
    let mdb = newMemDB()
    mdb.put(key1, value1)
    mdb.put(key2, value2)
    let cdb = newCachingDB(trieDB(mdb))
    check:
      cdb.get(key1) == @value1
      cdb.get(key2) == @value2

    cdb.del(key1)
    check:
      key1 notin cdb
      mdb.get(key1) == @value1

    cdb.put(key3, value3)
    check:
      cdb.get(key3) == @value3
      key3 notin mdb

    cdb.put(key4, value4)
    cdb.del(key4)
    check(key4 notin cdb)

    cdb.commit()

    check:
      key1 notin mdb
      mdb.get(key2) == @value2
      mdb.get(key3) == @value3
      key4 notin mdb

