# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Persistent Storage or Cache For Snap Data And MPT Assembly
## ==========================================================
##
## For the moment, this module is a separate RocksDB unit independent
## from `CoreDB`/`Aristo`/`Kvt`. If/when it proves to be useful, it can
## be integrated with KVT, similar to `BeaconHeaderKey` from the
## `header_chain_cache` module.
##
## This module will always pull in the `RocksDB` library. There is no
## in-memory part (which avoids the `RocksDB` library) as provided by the
## `CorrDb` via different `memory` and `persistent` sub-modules.
##
## For the moment, no column families will be used.
##
## Additional assumptions:
##
## * The `CoreDB`/`Aristo`/`Kvt` state database suite is mostly idle,
##   typically it would be empty. This only matters when the MPT assembly
##   needs to be imported. The current state database needs to be cleared
##   before import.
##

{.push raises: [].}

import
  std/[dirs, paths, typetraits],
  pkg/[chronicles, results, rocksdb],
  ../worker_const,
  ./mpt_desc

logScope:
  topics = "snap sync"

type
  MptAsmRef* = ref object
    adb*: RocksDbReadWriteRef
    dir*: Path

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(T: type MptAsmRef, baseDir: string, info: static[string]): Opt[T] =
  if baseDir.len == 0:
    error info & "No base directory for assembly DB"
    return err()

  let asmDir = Path(baseDir) / Path(snapAsmFolder)
  if asmDir.dirExists:
    let bakDir = Path(asmDir.distinctBase & "~")
    block backupOldFolder:
      var excpt = ""
      try:
        bakDir.removeDir()
        asmDir.moveDir bakDir
        break backupOldFolder
      except OSError as e:
        excpt = $e.name & "(" & e.msg & ")"
      except IOError as e:
        excpt = $e.name & "(" & e.msg & ")"
      error info & ": Cannot backup old assembly folder", asmDir, bakDir, excpt
      return err()

  block createSnapFolder:
    var excpt = ""
    try:
      asmDir.createDir()
      break createSnapFolder
    except OSError as e:
      excpt = $e.name & "(" & e.msg & ")"
    except IOError as e:
      excpt = $e.name & "(" & e.msg & ")"
    error info & ": Cannot create assembly folder", asmDir, excpt
    return err()

  let db = T(dir: asmDir)
  db.adb = asmDir.distinctBase.openRocksDb().valueOr:
    error info & ": Cannot create rocksdb assembly DB", asmDir, `error`=error
    return err()

  ok db

proc close*(db: MptAsmRef, eradicate = false) =
  db.adb.close()
  db.adb = nil
  if eradicate:
    try:
      db.dir.removeDir()

      # Remove the base folder if it is empty
      block done:
        for w in db.dir.walkDirRec():
          # Ignore backup files
          let p = w.distinctBase
          if 0 < p.len and p[^1] != '~':
            break done
        db.dir.removeDir()
    except CatchableError:
      discard

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
