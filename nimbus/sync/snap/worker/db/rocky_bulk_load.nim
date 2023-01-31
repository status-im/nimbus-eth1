# nimbus-eth1
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Bulk import loader for rocksdb

import
  std/os, # std/[sequtils, strutils],
  eth/common/eth_types,
  rocksdb,
  ../../../../db/[kvstore_rocksdb, select_backend]

{.push raises: [].}

type
  RockyBulkLoadRef* = ref object of RootObj
    when select_backend.dbBackend == select_backend.rocksdb:
      db: RocksStoreRef
      envOption: rocksdb_envoptions_t
      importOption: rocksdb_ingestexternalfileoptions_t
      writer: rocksdb_sstfilewriter_t
      filePath: string
    csError: string

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type RockyBulkLoadRef;
    db: RocksStoreRef;
    envOption: rocksdb_envoptions_t
      ): T =
  ## Create a new bulk load descriptor.
  when select_backend.dbBackend == select_backend.rocksdb:
    result = T(
      db:           db,
      envOption:    envOption,
      importOption: rocksdb_ingestexternalfileoptions_create())

    doAssert not result.importOption.isNil
    doAssert not envOption.isNil
  else:
    T(csError: "rocksdb is unsupported")

proc init*(T: type RockyBulkLoadRef; db: RocksStoreRef): T =
  ## Variant of `init()`
  RockyBulkLoadRef.init(db, rocksdb_envoptions_create())

proc clearCacheFile*(db: RocksStoreRef; fileName: string): bool
    {.gcsafe, raises: [OSError].} =
  ## Remove left-over cache file from an imcomplete previous session. The
  ## return value `true` indicated that a cache file was detected.
  discard
  when select_backend.dbBackend == select_backend.rocksdb:
    let filePath = db.tmpDir / fileName
    if filePath.fileExists:
      filePath.removeFile
      return true

proc destroy*(rbl: RockyBulkLoadRef) {.gcsafe, raises: [OSError].} =
  ## Destructor, free memory resources and delete temporary file. This function
  ## can always be called even though `finish()` will call `destroy()`
  ## automatically if successful.
  ##
  ## Note that after calling `destroy()`, the `RockyBulkLoadRef` descriptor is
  ## reset and must not be used anymore with any function (different from
  ## `destroy()`.)
  ##
  discard
  when select_backend.dbBackend == select_backend.rocksdb:
    if not rbl.writer.isNil:
      rbl.writer.rocksdb_sstfilewriter_destroy()
    if not rbl.envOption.isNil:
      rbl.envOption.rocksdb_envoptions_destroy()
    if not rbl.importOption.isNil:
      rbl.importOption.rocksdb_ingestexternalfileoptions_destroy()
    if 0 < rbl.filePath.len:
      rbl.filePath.removeFile
    rbl[].reset

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc lastError*(rbl: RockyBulkLoadRef): string =
  ## Get last error explainer
  rbl.csError

proc store*(rbl: RockyBulkLoadRef): RocksDBInstance =
  ## Provide the diecriptor for backend functions as defined in `rocksdb`.
  discard
  when select_backend.dbBackend == select_backend.rocksdb:
    rbl.db.store

proc rocksStoreRef*(db: ChainDb): RocksStoreRef =
  ## Pull out underlying rocksdb backend descripto (if any)
  # Current architecture allows only one globally defined persistent type
  discard
  when select_backend.dbBackend == select_backend.rocksdb:
    if not db.isNil:
      return db.rdb

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc begin*(rbl: RockyBulkLoadRef; fileName: string): bool =
  ## Begin a new bulk load session storing data into a temporary cache file
  ## `fileName`. When finished, this file will bi direcly imported into the
  ## database.
  discard
  when select_backend.dbBackend == select_backend.rocksdb:
    rbl.writer = rocksdb_sstfilewriter_create(
      rbl.envOption, rbl.db.store.options)
    if rbl.writer.isNil:
      rbl.csError = "Cannot create sst writer session"
      return false

    rbl.csError = ""
    let filePath = rbl.db.tmpDir / fileName
    var csError: cstring
    rbl.writer.rocksdb_sstfilewriter_open(fileName, addr csError)
    if not csError.isNil:
      rbl.csError = $csError
      return false

    rbl.filePath = filePath
    return  true

proc add*(
    rbl: RockyBulkLoadRef;
    key: openArray[byte];
    val: openArray[byte]
      ): bool =
  ## Append a record to the SST file. Note that consecutive records must be
  ## strictly increasing.
  ##
  ## This function is a wrapper around `rocksdb_sstfilewriter_add()` or
  ## `rocksdb_sstfilewriter_put()` (stragely enough, there are two functions
  ## with exactly the same impementation code.)
  discard
  when select_backend.dbBackend == select_backend.rocksdb:
    var csError: cstring
    rbl.writer.rocksdb_sstfilewriter_add(
      cast[cstring](unsafeAddr key[0]), csize_t(key.len),
      cast[cstring](unsafeAddr val[0]), csize_t(val.len),
      addr csError)
    if csError.isNil:
      return true
    rbl.csError = $csError

proc finish*(
    rbl: RockyBulkLoadRef
      ): Result[int64,void]
      {.gcsafe, raises: [OSError].} =
  ## Commit collected and cached data to the database. This function implies
  ## `destroy()` if successful. Otherwise `destroy()` must be called
  ## explicitely, e.g. after error analysis.
  ##
  ## If successful, the return value is the size of the SST file used if
  ## that value is available. Otherwise, `0` is returned.
  when select_backend.dbBackend == select_backend.rocksdb:
    var csError: cstring
    rbl.writer.rocksdb_sstfilewriter_finish(addr csError)

    if csError.isNil:
      rbl.db.store.db.rocksdb_ingest_external_file(
        [rbl.filePath].allocCStringArray, 1,
        rbl.importOption,
        addr csError)

      if csError.isNil:
        var size: int64
        try:
          var f: File
          if f.open(rbl.filePath):
            size = f.getFileSize
            f.close
        except:
          discard
        rbl.destroy()
        return ok(size)

    rbl.csError = $csError

  err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
