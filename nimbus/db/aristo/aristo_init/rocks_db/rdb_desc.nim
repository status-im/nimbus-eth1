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
  eth/common,
  rocksdb,
  stew/[endians2, keyed_queue],
  ../../aristo_desc,
  ../init_common

type
  RdbInst* = object
    admCol*: ColFamilyReadWrite        ## Admin column family handler
    vtxCol*: ColFamilyReadWrite        ## Vertex column family handler
    keyCol*: ColFamilyReadWrite        ## Hash key column family handler
    session*: WriteBatchRef            ## For batched `put()`
    rdKeyLru*: KeyedQueue[VertexID,HashKey] ## Read cache
    rdVtxLru*: KeyedQueue[VertexID,VertexRef] ## Read cache
    basePath*: string                  ## Database directory

  # Alien interface
  RdbGuest* = enum
    ## The guest CF was worth a try, but there are better solutions and this
    ## item will be removed in future.
    GuestFamily0 = "Guest0"            ## Guest family (e.g. for Kvt)
    GuestFamily1 = "Guest1"            ## Ditto
    GuestFamily2 = "Guest2"            ## Ditto

  RdbGuestDbRef* = ref object of GuestDbRef
    ## The guest CF was worth a try, but there are better solutions and this
    ## item will be removed in future.
    guestDb*: ColFamilyReadWrite       ## Pigiback feature references

  AristoCFs* = enum
    ## Column family symbols/handles and names used on the database
    AdmCF = "AriAdm"                   ## Admin column family name
    VtxCF = "AriVtx"                   ## Vertex column family name
    KeyCF = "AriKey"                   ## Hash key column family name

const
  BaseFolder* = "nimbus"               ## Same as for Legacy DB
  DataFolder* = "aristo"               ## Legacy DB has "data"
  RdKeyLruMaxSize* = 4096              ## Max size of read cache for keys
  RdVtxLruMaxSize* = 2048              ## Max size of read cache for vertex IDs

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template logTxt*(info: static[string]): static[string] =
  "RocksDB/" & info

template baseDb*(rdb: RdbInst): RocksDbReadWriteRef =
  rdb.admCol.db


func baseDir*(rdb: RdbInst): string =
  rdb.basePath / BaseFolder

func dataDir*(rdb: RdbInst): string =
  rdb.baseDir / DataFolder


template toOpenArray*(xid: AdminTabID): openArray[byte] =
  xid.uint64.toBytesBE.toOpenArray(0,7)

template toOpenArray*(vid: VertexID): openArray[byte] =
  vid.uint64.toBytesBE.toOpenArray(0,7)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
