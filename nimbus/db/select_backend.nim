import strutils, eth/db/kvstore

export kvstore

# Database access layer that turns errors in the database into Defects as the
# code that uses it isn't equipped to handle errors of that kind - this should
# be reconsidered when making more changes here.

type DbBackend = enum
  sqlite,
  rocksdb,
  lmdb

const
  nimbus_db_backend* {.strdefine.} = "rocksdb"
  dbBackend = parseEnum[DbBackend](nimbus_db_backend)

type
  ChainDB* = ref object of RootObj
    kv: KvStoreRef

# TODO KvStore is a virtual interface and TrieDB is a virtual interface - one
#      will be enough eventually - unless the TrieDB interface gains operations
#      that are not typical to KvStores
proc get*(db: ChainDB, key: openArray[byte]): seq[byte] =
  var res: seq[byte]
  proc onData(data: openArray[byte]) = res = @data
  if db.kv.get(key, onData).expect("working database"):
    return res

proc put*(db: ChainDB, key, value: openArray[byte]) =
  db.kv.put(key, value).expect("working database")

proc contains*(db: ChainDB, key: openArray[byte]): bool =
  db.kv.contains(key).expect("working database")

proc del*(db: ChainDB, key: openArray[byte]) =
  db.kv.del(key).expect("working database")

when dbBackend == sqlite:
  import eth/db/kvstore_sqlite as database_backend
  proc newChainDB*(path: string): ChainDB =
    ChainDB(kv: kvStore SqKvStore.init(path, "nimbus").tryGet())
elif dbBackend == rocksdb:
  import eth/db/kvstore_rocksdb as database_backend
  proc newChainDB*(path: string): ChainDB =
    ChainDB(kv: kvStore RocksStoreRef.init(path, "nimbus").tryGet())
elif dbBackend == lmdb:
  # TODO This implementation has several issues on restricted platforms, possibly
  #      due to mmap restrictions - see:
  #      https://github.com/status-im/nim-beacon-chain/issues/732
  #      https://github.com/status-im/nim-beacon-chain/issues/688
  # It also has other issues, including exception safety:
  #      https://github.com/status-im/nim-beacon-chain/pull/809

  {.error: "lmdb deprecated, needs reimplementing".}

export database_backend
