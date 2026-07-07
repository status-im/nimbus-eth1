# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[dirs, paths, typetraits],
  pkg/[chronicles, chronos, eth/common, results, rocksdb],
  #pkg/stew/[byteutils, interval_set],
  ../../../../wire_protocol/snap/snap_types,
  ../../[state_db, worker_const],
  ./cache_desc,
  ../mpt_desc

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private constructor helpers
# ------------------------------------------------------------------------------

proc closeDb(db: MptAsmRef) =
  if not db.adb.isNil:
    db.adb.close()
    db.adb = RocksDbReadWriteRef(nil)

proc openDb(db: MptAsmRef; info: static[string]): bool =
  db.adb = db.dir.distinctBase.openRocksDb().valueOr:
    error info & ": Cannot create assembly DB", dir=db.dir, `error`=error
    return false
  true

proc newDbFolder(db: MptAsmRef; info: static[string]): bool =
  if db.dir.dirExists:
    let bakDir = Path(db.dir.distinctBase & "~")
    block backupOldFolder:
      var excpt = ""
      try:
        bakDir.removeDir()
        db.dir.moveDir bakDir
        break backupOldFolder
      except OSError as e:
        excpt = $e.name & "(" & e.msg & ")"
      except IOError as e:
        excpt = $e.name & "(" & e.msg & ")"
      error info & ": Cannot backup DB folder", dir=db.dir, bakDir, excpt
      return false

  block createSnapFolder:
    var excpt = ""
    try:
      db.dir.createDir()
      break createSnapFolder
    except OSError as e:
      excpt = $e.name & "(" & e.msg & ")"
    except IOError as e:
      excpt = $e.name & "(" & e.msg & ")"
    error info & ": Cannot create assembly folder", dir=db.dir, excpt
    return false

  true

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc close*(db: MptAsmRef, wipe = false) =
  ## Close database unless done yet. If the argument `wipe` is set
  ## `true`, then the database will be physically deleted.
  ##
  db.closeDb()
  if wipe:
    try:
      db.dir.removeDir()

      # Remove the base folder if it is empty
      block done:
        for w in db.dir.parentDir.walkDirRec():
          # Ignore backup files
          let p = w.distinctBase
          if 0 < p.len and p[^1] != '~':
            break done
        db.dir.removeDir()
    except CatchableError:
      discard

proc clear*(db: MptAsmRef; info: static[string]): bool =
  ## Close database and move it to a backup directory, then re-open a new
  ## database. Any previous backup database will be deleted.
  ##
  ## This function returns the argument true if database backup and
  ## re-open succeeded, and `false` otherwise.
  ##
  db.closeDb()
  db.newDbFolder(info) and db.openDb(info)

proc init*(
    T: type MptAsmRef;
    baseDir: string;
    info: static[string];
      ): Opt[T] =
  ## Create or open an existing database. If the ergument `newDb` is set
  ## `false`, the database is opened. Otherwise, `MptAsmRef.init(dir,true)`
  ## is roughly equivalent to
  ## ::
  ##   let db = MptAsmRef.init(dir,false).expect "value"
  ##   discard db.clear()
  ##
  if baseDir.len == 0:
    error info & ": No base directory for assembly DB"

  else:
    let db = T(dir: Path(baseDir) / Path(snapAsmFolder))
    if db.openDb(info):
      return ok db

  err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
