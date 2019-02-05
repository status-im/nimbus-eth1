import strutils

type DbBackend = enum
  sqlite,
  rocksdb,
  lmdb

const
  nimbus_db_backend* {.strdefine.} = "rocksdb"
  dbBackend = parseEnum[DbBackend](nimbus_db_backend)

when dbBackend == sqlite:
  import eth/trie/backends/sqlite_backend as database_backend
elif dbBackend == rocksdb:
  import eth/trie/backends/rocksdb_backend as database_backend
elif dbBackend == lmdb:
  import eth/trie/backends/lmdb_backend as database_backend

export database_backend
