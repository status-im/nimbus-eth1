const nimbus_db_backend* {.strdefine.} = "rocksdb"

when nimbus_db_backend == "sqlite":
  import ./backends/sqlite_backend as database_backend
elif nimbus_db_backend == "rocksdb":
  import ./backends/rocksdb_backend as database_backend
else:
  import ./backends/lmdb_backend as database_backend

export database_backend
