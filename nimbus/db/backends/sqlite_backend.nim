import
  sqlite3, ranges, ranges/ptr_arith, ../storage_types

type
  SqliteChainDB* = object
    store: PSqlite3
    selectStmt, insertStmt, deleteStmt: PStmt

  ChainDB* = SqliteChainDB

proc initChainDB*(dbPath: string): ChainDB =
  var s = sqlite3.open(dbPath, result.store)
  if s != SQLITE_OK:
    raiseStorageInitError()

  template execQuery(q: string) =
    var s: Pstmt
    if prepare_v2(result.store, q, q.len.int32, s, nil) == SQLITE_OK:
      if step(s) != SQLITE_DONE or finalize(s) != SQLITE_OK:
        raiseStorageInitError()
    else:
      raiseStorageInitError()

  # TODO: check current version and implement schema versioning
  execQuery "PRAGMA user_version = 1;"

  execQuery """
    CREATE TABLE IF NOT EXISTS trie_nodes(
       key BLOB PRIMARY KEY,
       value BLOB
    );
  """

  template prepare(q: string): PStmt =
    var s: Pstmt
    if prepare_v2(result.store, q, q.len.int32, s, nil) != SQLITE_OK:
      raiseStorageInitError()
    s

  result.selectStmt = prepare "SELECT value FROM trie_nodes WHERE key = ?;"

  if sqlite3.libversion_number() < 3024000:
    result.insertStmt = prepare """
      INSERT OR REPLACE INTO trie_nodes(key, value) VALUES (?, ?);
    """
  else:
    result.insertStmt = prepare """
      INSERT INTO trie_nodes(key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value;
    """

  result.deleteStmt = prepare "DELETE FROM trie_nodes WHERE key = ?;"

proc bindBlob(s: Pstmt, n: int, blob: openarray[byte]): int32 =
  sqlite3.bind_blob(s, n.int32, blob.baseAddr, blob.len.int32, nil)

proc get*(db: ChainDB, key: DbKey): ByteRange =
  template check(op) =
    let status = op
    if status != SQLITE_OK: raiseKeyReadError(key)

  check reset(db.selectStmt)
  check clearBindings(db.selectStmt)
  check bindBlob(db.selectStmt, 1, key.toOpenArray)

  case step(db.selectStmt)
  of SQLITE_ROW:
    var
      resStart = columnBlob(db.selectStmt, 0)
      resLen   = columnBytes(db.selectStmt, 0)
      resSeq   = newSeq[byte](resLen)
    copyMem(resSeq.baseAddr, resStart, resLen)
    return resSeq.toRange
  of SQLITE_DONE:
    return ByteRange()
  else: raiseKeySearchError(key)

proc put*(db: var ChainDB, key: DbKey, value: ByteRange) =
  template check(op) =
    let status = op
    if status != SQLITE_OK: raiseKeyWriteError(key)

  check reset(db.insertStmt)
  check clearBindings(db.insertStmt)
  check bindBlob(db.insertStmt, 1, key.toOpenArray)
  check bindBlob(db.insertStmt, 2, value.toOpenArray)

  if step(db.insertStmt) != SQLITE_DONE:
    raiseKeyWriteError(key)

proc contains*(db: ChainDB, key: DbKey): bool =
  template check(op) =
    let status = op
    if status != SQLITE_OK: raiseKeySearchError(key)

  check reset(db.selectStmt)
  check clearBindings(db.selectStmt)
  check bindBlob(db.selectStmt, 1, key.toOpenArray)

  case step(db.selectStmt)
  of SQLITE_ROW: result = true
  of SQLITE_DONE: result = false
  else: raiseKeySearchError(key)

proc del*(db: var ChainDB, key: DbKey) =
  template check(op) =
    let status = op
    if status != SQLITE_OK: raiseKeyDeletionError(key)

  check reset(db.deleteStmt)
  check clearBindings(db.deleteStmt)
  check bindBlob(db.deleteStmt, 1, key.toOpenArray)

  if step(db.deleteStmt) != SQLITE_DONE:
    raiseKeyDeletionError(key)

proc close*(db: var ChainDB) =
  discard sqlite3.close(db.store)
  reset(db)

