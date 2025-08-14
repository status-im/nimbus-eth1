# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import std/[os, sequtils], rocksdb, chronicles

export rocksdb

const
  BaseFolder = "nimbus"
  DataFolder = "aristo"

type
  RocksDbInstanceRef* = ref object ## Shared handle to a single rocksdb instance
    db*: RocksDbReadWriteRef
    baseDir*: string

    sharedBatch*: SharedWriteBatchRef

  SharedWriteBatchRef* = ref object
    batch*: WriteBatchRef
    refs*: int
    commits*: int
    closes*: int
    families*: seq[ColFamilyReadWrite]

func dataDir*(baseDir: string): string =
  baseDir / BaseFolder / DataFolder

func dataDir*(rdb: RocksDbInstanceRef): string =
  rdb.baseDir.dataDir

proc isClosed*(session: SharedWriteBatchRef): bool =
  session == nil or session.batch.isClosed()

proc openWriteBatch*(rdb: RocksDbInstanceRef): SharedWriteBatchRef =
  if rdb.sharedBatch.isClosed():
    rdb.sharedBatch = SharedWriteBatchRef(batch: rdb.db.openWriteBatch(), refs: 1)
  else:
    rdb.sharedBatch.refs += 1
  rdb.sharedBatch

proc close*(session: SharedWriteBatchRef) =
  session.closes += 1

  if session.closes == session.refs:
    session.batch.close()
    session.refs = 0
    session.commits = 0
    session.closes = 0

proc commit*(
    rdb: RocksDbInstanceRef, session: SharedWriteBatchRef, cf: ColFamilyReadWrite
): Result[void, string] =
  session.commits += 1
  session.families.add cf
  if session.commits == session.refs:
    # Write to disk if everyone that opened a session also committed it
    ?rdb.db.write(session.batch)
    # This flush forces memtables to be written to disk, which is necessary given
    # the use of vector memtables which have very bad lookup performance.
    rdb.db.flush(session.families.mapIt(it.handle())).isOkOr:
      # Not sure what to do here - the commit above worked so it would be strange
      # to have an error here
      warn "Could not flush database", error

  ok()

proc open*(
    T: type RocksDbInstanceRef,
    baseDir: string,
    dbOpts: DbOptionsRef,
    cfs: openArray[(string, ColFamilyOptionsRef)],
): Result[RocksDbInstanceRef, string] =
  let dataDir = baseDir.dataDir

  try:
    dataDir.createDir
  except CatchableError as exc:
    return err("Cannot create database directory " & dataDir & ": " & exc.msg)

  var
    descs = cfs.mapIt(it[0].initColFamilyDescriptor(it[1]))
    cfNames = cfs.mapIt(it[0])

  # Must include all column families or openRocksDb will fail
  if (dataDir / "CURRENT").fileExists:
    let hdCFs = dataDir.listColumnFamilies.valueOr:
      raiseAssert "Cannot read existing CFs: " & error

    for name in hdCFs:
      if name notin cfNames:
        descs.add (
          name.initColFamilyDescriptor(defaultColFamilyOptions(autoClose = true))
        )

  ok RocksDbInstanceRef(
    db: ?openRocksDb(dataDir, dbOpts, columnFamilies = descs), baseDir: baseDir
  )

proc close*(rdb: RocksDbInstanceRef, eradicate = false) =
  if rdb.db != nil:
    rdb.db.close()
    rdb.db = nil

  if eradicate:
    try:
      rdb.dataDir.removeDir

      # Remove the base folder if it is empty
      block done:
        for w in rdb.baseDir.walkDirRec:
          # Ignore backup files
          if 0 < w.len and w[^1] != '~':
            break done
        rdb.baseDir.removeDir
    except CatchableError:
      discard
