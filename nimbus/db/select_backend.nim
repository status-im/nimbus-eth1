import strutils

type DbBackend = enum
  sqlite,
  rocksdb,
  lmdb

const
  nimbus_db_backend* {.strdefine.} = "rocksdb"
  dbBackend = parseEnum[DbBackend](nimbus_db_backend)

when dbBackend == sqlite:
  import ./backends/sqlite_backend as database_backend
elif dbBackend == rocksdb:
  import ./backends/rocksdb_backend as database_backend
elif dbBackend == lmdb:
  import ./backends/lmdb_backend as database_backend

export database_backend
