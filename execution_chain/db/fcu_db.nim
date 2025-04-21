# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  eth/common/hashes,
  stew/endians2,
  stew/assign2,
  results,
  ./core_db/base,
  ./storage_types

type
  FcuHashAndNumber* = object
    hash*: Hash32
    number*: uint64

const
  headKey = fcuKey 0
  finKey  = fcuKey 1
  safeKey = fcuKey 2
  DataLen = sizeof(Hash32) + sizeof(uint64)

template fcuReadImpl(key: DbKey, name: string): auto =
  let data = db.getOrEmpty(key.toOpenArray).valueOr:
    return err($error)
  if data.len != DataLen:
    return err("no " & name & " block hash and number")
  ok(FcuHashAndNumber(
    hash: Hash32.copyFrom(data.toOpenArray(sizeof(uint64), data.len-1)),
    number: uint64.fromBytesBE(data),
  ))

template fcuWriteImpl(key: DbKey, hash: Hash32, number: uint64): auto =
  var data: array[DataLen, byte]
  assign(data, number.toBytesBE)
  assign(data.toOpenArray(sizeof(uint64), data.len-1), hash.data)
  db.put(key.toOpenArray, data).isOkOr:
    return err($error)
  ok()

proc fcuHead*(db: CoreDbTxRef): Result[FcuHashAndNumber, string] =
  fcuReadImpl(headKey, "head")

proc fcuHead*(db: CoreDbTxRef, hash: Hash32, number: uint64): Result[void, string] =
  fcuWriteImpl(headKey, hash, number)

template fcuHead*(db: CoreDbTxRef, head: FcuHashAndNumber): auto =
  fcuHead(db, head.hash, head.number)

proc fcuFinalized*(db: CoreDbTxRef): Result[FcuHashAndNumber, string] =
  fcuReadImpl(finKey, "finalized")

proc fcuFinalized*(db: CoreDbTxRef, hash: Hash32, number: uint64): Result[void, string] =
  fcuWriteImpl(finKey, hash, number)

template fcuFinalized*(db: CoreDbTxRef, finalized: FcuHashAndNumber): auto =
  fcuFinalized(db, finalized.hash, finalized.number)

proc fcuSafe*(db: CoreDbTxRef): Result[FcuHashAndNumber, string] =
  fcuReadImpl(safeKey, "safe")

proc fcuSafe*(db: CoreDbTxRef, hash: Hash32, number: uint64): Result[void, string] =
  fcuWriteImpl(safeKey, hash, number)

template fcuSafe*(db: CoreDbTxRef, safe: FcuHashAndNumber): auto =
  fcuSafe(db, safe.hash, safe.number)
