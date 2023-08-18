# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB store data record
## ==========================

{.push raises: [].}

import
  std/[algorithm, os, sequtils, sets, tables],
  chronicles,
  eth/common,
  rocksdb,
  stew/results,
  "../.."/[aristo_constants, aristo_desc],
  ../aristo_init_common,
  ./rdb_desc

logScope:
  topics = "aristo-backend"

type
  RdbPutSession = object
    writer: rocksdb_sstfilewriter_t
    sstPath: string
    nRecords: int

const
  extraTraceMessages = false or true
    ## Enable additional logging noise

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "RocksDB/put " & info

proc getFileSize(fileName: string): int64 =
  var f: File
  if f.open fileName:
    defer: f.close
    try:
      result = f.getFileSize
    except:
      discard

proc rmFileIgnExpt(fileName: string) =
  try:
    fileName.removeFile
  except:
    discard

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc destroy(rps: RdbPutSession) =
  rps.writer.rocksdb_sstfilewriter_destroy()
  rps.sstPath.rmFileIgnExpt

proc begin(
    rdb: var RdbInst;
      ): Result[RdbPutSession,(AristoError,string)] =
  ## Begin a new bulk load session storing data into a temporary cache file
  ## `fileName`. When finished, this file will bi direcly imported into the
  ## database.
  var csError: cstring

  var session = RdbPutSession(
    writer: rocksdb_sstfilewriter_create(rdb.envOpt, rdb.store.options),
    sstPath: rdb.basePath / BaseFolder / TempFolder / SstCache)

  if session.writer.isNil:
    return err((RdbBeCreateSstWriter, "Cannot create sst writer session"))

  session.sstPath.rmFileIgnExpt

  session.writer.rocksdb_sstfilewriter_open(
    session.sstPath.cstring, addr csError)
  if not csError.isNil:
    session.destroy()
    return err((RdbBeOpenSstWriter, $csError))

  ok session


proc add(
    session: var RdbPutSession;
    key: openArray[byte];
    val: openArray[byte];
      ): Result[void,(AristoError,string)] =
  ## Append a record to the SST file. Note that consecutive records must be
  ## strictly increasing.
  ##
  ## This function is a wrapper around `rocksdb_sstfilewriter_add()` or
  ## `rocksdb_sstfilewriter_put()` (stragely enough, there are two functions
  ## with exactly the same impementation code.)
  var csError: cstring

  session.writer.rocksdb_sstfilewriter_add(
    cast[cstring](unsafeAddr key[0]), csize_t(key.len),
    cast[cstring](unsafeAddr val[0]), csize_t(val.len), addr csError)
  if not csError.isNil:
    return err((RdbBeAddSstWriter, $csError))

  session.nRecords.inc
  ok()


proc commit(
    rdb: var RdbInst;
    session: RdbPutSession;
      ): Result[void,(AristoError,string)] =
  ## Commit collected and cached data to the database. This function implies
  ## `destroy()` if successful. Otherwise `destroy()` must be called
  ## explicitely, e.g. after error analysis.
  var csError: cstring

  if 0 < session.nRecords:
    session.writer.rocksdb_sstfilewriter_finish(addr csError)
    if not csError.isNil:
      return err((RdbBeFinishSstWriter, $csError))

    rdb.store.db.rocksdb_ingest_external_file(
      [session.sstPath].allocCStringArray, 1, rdb.impOpt, addr csError)
    if not csError.isNil:
      return err((RdbBeIngestSstWriter, $csError))

    when extraTraceMessages:
      let fileSize = session.sstPath.getFileSize
      trace logTxt "finished sst", fileSize

  session.destroy()
  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc put*(
    rdb: var RdbInst;
    tabs: RdbTabs,
      ): Result[void,(AristoError,string)] =

  var session = block:
    let rc = rdb.begin()
    if rc.isErr:
      return err(rc.error)
    rc.value

  # Vertices with empty table values will be deleted
  var delKey: HashSet[RdbKey]

  for pfx in low(StorageType) .. high(StorageType):
    when extraTraceMessages:
      trace logTxt "sub-table", pfx, nItems=tabs[pfx].len

    for vid in tabs[pfx].keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
      let
        key = vid.toRdbKey pfx
        val = tabs[pfx].getOrDefault(vid, EmptyBlob)
      if val.len == 0:
        delKey.incl key
      else:
        let rc = session.add(key, val)
        if rc.isErr:
          session.destroy()
          return err(rc.error)

  block:
    let rc = rdb.commit session
    if rc.isErr:
      trace logTxt "commit error", error=rc.error[0], info=rc.error[1]
      return err(rc.error)

  # Delete vertices after successful updating veritces with non-zero values.
  for key in delKey:
    let rc = rdb.store.del key
    if rc.isErr:
      return err((RdbBeDriverDelError,rc.error))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
