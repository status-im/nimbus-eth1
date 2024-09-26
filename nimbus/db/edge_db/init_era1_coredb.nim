# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/sets,
  pkg/eth/[common, rlp],
  pkg/results,
  ./db_desc,
  ".."/[core_db, era1_db, storage_types]

type
  EdgeE1CdbRef = ref object of EdgeDbGetRef
    era1: Era1DbRef
    cdb: CoreDbRef

  EdgeE1CdbDbg = ref object of EdgeE1CdbRef
    ## For debugging. Keys in the `e1xcpt` set are not found by the `Era1`
    ## driver.
    e1xcpt: HashSet[BlockNumber]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc getBlockHash(
    w: EdgeDbGetRef;
    k: uint64;
      ): Result[Hash256,EdgeDbError] =
  var hash: Hash256
  if EdgeE1CdbRef(w).cdb.getBlockHash(BlockNumber(k), hash):
    return ok(hash)
  err(EdgeKeyNotFound)

proc getBlockHeader(
    w: EdgeDbGetRef;
    h: Hash256;
      ): Result[BlockHeader,EdgeDbError] =
  var header: BlockHeader
  if EdgeE1CdbRef(w).cdb.getBlockHeader(h, header):
    return ok(header)
  err(EdgeKeyNotFound)

proc getBlockBody(
    w: EdgeDbGetRef;
    h: Hash256;
      ): Result[BlockBody,EdgeDbError] =
  var body: BlockBody
  if EdgeE1CdbRef(w).cdb.getBlockBody(h, body):
    return ok(body)
  err(EdgeKeyNotFound)

# ------------------------------------------------------------------------------
# Private drivers
# ------------------------------------------------------------------------------

proc blobGetUnsupported(
    dsc: EdgeDbGetRef;
    col: EdgeDbColumn;
    key: openArray[byte];
      ): Result[Blob,EdgeDbError] =
  err(EdgeKeyTypeUnsupported)


proc getEra1Obj(
    dsc: EdgeDbGetRef;
    col: EdgeDbColumn;
    key: uint64;
      ): Result[Blob,EdgeDbError] =
  case col:
  of EthBlockData:
    let w = EdgeE1CdbRef(dsc).era1.getEthBlock(key).valueOr:
      return err(EdgeKeyNotFound)
    ok(rlp.encode w)

  of EthHeaderData:
    let w = EdgeE1CdbRef(dsc).era1.getBlockTuple(key).valueOr:
      return err(EdgeKeyNotFound)
    ok(rlp.encode w.header)

  of EthBodyData:
    let w = EdgeE1CdbRef(dsc).era1.getBlockTuple(key).valueOr:
      return err(EdgeKeyNotFound)
    ok(rlp.encode w.body)

  else:
    err(EdgeColUnsupported)


proc getCoreDbObj(
    dsc: EdgeDbGetRef;
    col: EdgeDbColumn;
    key: uint64;
      ): Result[Blob,EdgeDbError] =
  case col:
  of EthBlockData:
    let h = ? dsc.getBlockHash(key)
    ok(rlp.encode EthBlock.init(? dsc.getBlockHeader(h), ? dsc.getBlockBody(h)))

  of EthHeaderData:
    let
      h = ? dsc.getBlockHash(key)
      kvt =  EdgeE1CdbRef(dsc).cdb.ctx.getKvt()

      # Fetching directly from the DB avoids re-encoding the header object
      data = kvt.get(genericHashKey(h).toOpenArray).valueOr:
        return err(EdgeKeyNotFound)
    ok(data)

  of EthBodyData:
    ok(rlp.encode(? dsc.getBlockBody(? dsc.getBlockHash(key))))

  else:
    err(EdgeColUnsupported)

# ------------------------------------------------------------------------------
# Public constructor (debuging version)
# ------------------------------------------------------------------------------

proc init*(
    T: type EdgeDbRef;
    era1: Era1DbRef;
    e1xcpt: HashSet[BlockNumber];
    cdb: CoreDbRef;
      ): T =
  ## Initalise for trying `Era1` first, then `CoreDb`. This goes with some
  ## exceptions for `Era1`. If an argument key is in `excpt` if will not be
  ## found by the `Era1` driver.
  ##
  ## This constructor is mainly designed for debugging.
  ##
  proc getEra1Expt(
      dsc: EdgeDbGetRef;
      col: EdgeDbColumn;
      key: uint64;
        ): Result[Blob,EdgeDbError] =
    if key in EdgeE1CdbDbg(dsc).e1xcpt:
      return err(EdgeKeyNotFound)
    dsc.getEra1Obj(col, key)

  T(getDesc:      EdgeE1CdbDbg(era1: era1, cdb: cdb, e1xcpt: e1xcpt),
    uintGetFns:   @[EdgeDbUintGetFn(getEra1Expt),
                    EdgeDbUintGetFn(getCoreDbObj)],
    blobGetFns:   @[EdgeDbBlobGetFn(blobGetUnsupported)],
    uintGetPolFn: uintGetSeqentiallyUntilFound,
    blobGetPolFn: blobGetSeqentiallyUntilFound)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type EdgeDbRef;
    era1: Era1DbRef;
    cdb: CoreDbRef;
      ): T =
  ## Initalise for trying `Era1` first, then `CoreDb`.
  ##
  T(getDesc:      EdgeE1CdbRef(era1: era1, cdb: cdb),
    uintGetFns:   @[EdgeDbUintGetFn(getEra1Obj),
                    EdgeDbUintGetFn(getCoreDbObj)],
    blobGetFns:   @[EdgeDbBlobGetFn(blobGetUnsupported)],
    uintGetPolFn: uintGetSeqentiallyUntilFound,
    blobGetPolFn: blobGetSeqentiallyUntilFound)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
