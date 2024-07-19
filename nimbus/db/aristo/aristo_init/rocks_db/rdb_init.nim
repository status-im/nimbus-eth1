# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocksdb constructor/destructor for Aristo DB
## ============================================

{.push raises: [].}

import
  std/[sets, sequtils, os],
  rocksdb,
  results,
  ../../aristo_desc,
  ./rdb_desc,
  ../../../opts

# ------------------------------------------------------------------------------
# Private constructor
# ------------------------------------------------------------------------------

proc initImpl(
    rdb: var RdbInst,
    basePath: string,
    dbOpts: DbOptionsRef,
    cfOpts: ColFamilyOptionsRef,
    guestCFs: openArray[ColFamilyDescriptor] = [],
): Result[seq[ColFamilyReadWrite], (AristoError, string)] =
  ## Database backend constructor
  const initFailed = "RocksDB/init() failed"

  rdb.basePath = basePath

  let dataDir = rdb.dataDir
  try:
    dataDir.createDir
  except OSError, IOError:
    return err((RdbBeCantCreateDataDir, ""))

  # Column familiy names to allocate when opening the database. This list
  # might be extended below.
  var useCFs = AristoCFs.mapIt($it).toHashSet

  # The `guestCFs` list must not overwrite `AristoCFs` options
  let guestCFs = guestCFs.filterIt(it.name notin useCFs)

  # If the database exists already, check for missing column families and
  # allocate them for opening. Otherwise rocksdb might reject the peristent
  # database.
  if (dataDir / "CURRENT").fileExists:
    let hdCFs = dataDir.listColumnFamilies.valueOr:
      raiseAssert initFailed & " cannot read existing CFs: " & error
    # Update list of column families for opener.
    useCFs = useCFs + hdCFs.toHashSet

  # The `guestCFs` list might come with a different set of options. So it is
  # temporarily removed from `useCFs` and will be re-added with appropriate
  # options.
  let guestCFq = @guestCFs
  useCFs = useCFs - guestCFs.mapIt(it.name).toHashSet

  # Finalise list of column families
  let cfs = useCFs.toSeq.mapIt(it.initColFamilyDescriptor cfOpts) & guestCFq

  # Open database for the extended family :)
  let baseDb = openRocksDb(dataDir, dbOpts, columnFamilies = cfs).valueOr:
    raiseAssert initFailed & " cannot create base descriptor: " & error

  # Initialise column handlers (this stores implicitely `baseDb`)
  rdb.admCol = baseDb.getColFamily($AdmCF).valueOr:
    raiseAssert initFailed & " cannot initialise AdmCF descriptor: " & error
  rdb.vtxCol = baseDb.getColFamily($VtxCF).valueOr:
    raiseAssert initFailed & " cannot initialise VtxCF descriptor: " & error
  rdb.keyCol = baseDb.getColFamily($KeyCF).valueOr:
    raiseAssert initFailed & " cannot initialise KeyCF descriptor: " & error

  ok(guestCFs.mapIt(baseDb.getColFamily(it.name).expect("loaded cf")))

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    rdb: var RdbInst,
    basePath: string,
    dbOpts: DbOptionsRef,
    cfOpts: ColFamilyOptionsRef,
    guestCFs: openArray[ColFamilyDescriptor],
): Result[seq[ColFamilyReadWrite], (AristoError, string)] =
  ## Temporarily define a guest CF list here.
  rdb.initImpl(basePath, dbOpts, cfOpts, guestCFs)

proc destroy*(rdb: var RdbInst, eradicate: bool) =
  ## Destructor
  rdb.baseDb.close()

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
