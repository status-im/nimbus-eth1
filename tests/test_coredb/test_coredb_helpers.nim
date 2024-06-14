# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Some extended rocksdb backend modes for testing

import
  std/sequtils,
  ../../nimbus/db/core_db/backend/aristo_rocksdb,
  ../../nimbus/db/[core_db, opts]

type
  CdbTypeEx* = enum
    CdbOoops
    CdbAristoMemory = AristoDbMemory ## Memory backend emulator
    CdbAristoRocks  = AristoDbRocks  ## RocksDB backend
    CdbAristoVoid   = AristoDbVoid   ## No backend
    CdbAristoDualRocks               ## Dual RocksDB backends for Kvt & Aristo

func to*(cdb: CoreDbType; T: type CdbTypeEx): T =
  case cdb:
  # Let the compiler find out whether the enum is complete
  of Ooops, AristoDbMemory, AristoDbRocks, AristoDbVoid:
    return CdbTypeEx(cdb.ord)

const
  CdbTypeExPersistent* =
    CoreDbPersistentTypes.mapIt(it.to(CdbTypeEx)) & @[CdbAristoDualRocks]

func `$`*(w: CdbTypeEx): string =
  case w:
  of CdbOoops, CdbAristoMemory, CdbAristoRocks, CdbAristoVoid:
    $CoreDbType(w.ord)
  of CdbAristoDualRocks:
    "CdbAristoDualRocks"

proc newCdbAriAristoDualRocks*(path: string, opts: DbOptions): CoreDbRef =
  ## For debugging, there is the `AristoDbDualRocks` database with split
  ## backends for `Aristo` and `KVT`. This database is not compatible with
  ## `AristoDbRocks` so it cannot be reliably switched between both versions
  ## with consecutive sessions.
  newAristoDualRocksDbCoreDbRef path, opts

# End
