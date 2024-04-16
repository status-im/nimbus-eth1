# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB internal driver descriptor
## ===================================

{.push raises: [].}

import
  std/os,
  rocksdb,
  stew/endians2,
  ../../aristo_desc,
  ../init_common

type
  RdbInst* = object
    store*: ColFamilyReadWrite       ## Rocks DB database handler
    session*: WriteBatchRef          ## For batched `put()`
    basePath*: string                ## Database directory
    noFq*: bool                      ## No filter queues available

  RdbGuestDbRef* = ref object of GuestDbRef
    guestDb*: ColFamilyReadWrite     ## Pigiback feature reference

  RdbKey* = array[1 + sizeof VertexID, byte]
    ## Sub-table key, <pfx> + VertexID

const
  GuestFamily* = "Guest"             ## Guest family (e.g. for Kvt)
  AristoFamily* = "Aristo"           ## RocksDB column family
  BaseFolder* = "nimbus"             ## Same as for Legacy DB
  DataFolder* = "aristo"             ## Legacy DB has "data"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template logTxt*(info: static[string]): static[string] =
  "RocksDB/" & info


func baseDir*(rdb: RdbInst): string =
  rdb.basePath / BaseFolder

func dataDir*(rdb: RdbInst): string =
  rdb.baseDir / DataFolder

func toRdbKey*(id: uint64; pfx: StorageType): RdbKey =
  let idKey = id.toBytesBE
  result[0] = pfx.ord.byte
  copyMem(addr result[1], unsafeAddr idKey, sizeof idKey)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
