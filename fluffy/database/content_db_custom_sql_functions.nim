# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import stew/ptrops, stint, sqlite3_abi, eth/db/kvstore_sqlite3

func xorDistance(a: openArray[byte], b: openArray[byte]): seq[byte] =
  doAssert(a.len == b.len)

  let length = a.len
  var distance: seq[byte] = newSeq[byte](length)
  for i in 0 ..< length:
    distance[i] = a[i] xor b[i]

  return distance

proc xorDistance*(
    ctx: SqliteContext, n: cint, v: SqliteValue
) {.cdecl, gcsafe, raises: [].} =
  doAssert(n == 2)

  let
    ptrs = makeUncheckedArray(v)
    blob1Len = sqlite3_value_bytes(ptrs[][0])
    blob2Len = sqlite3_value_bytes(ptrs[][1])

    bytes = xorDistance(
      makeOpenArray(sqlite3_value_blob(ptrs[][0]), byte, blob1Len),
      makeOpenArray(sqlite3_value_blob(ptrs[][1]), byte, blob2Len),
    )

  sqlite3_result_blob(ctx, baseAddr bytes, cint bytes.len, SQLITE_TRANSIENT)

func isInRadius(contentId: UInt256, localId: UInt256, radius: UInt256): bool =
  let distance = contentId xor localId

  radius > distance

func isInRadius*(
    ctx: SqliteContext, n: cint, v: SqliteValue
) {.cdecl, gcsafe, raises: [].} =
  doAssert(n == 3)

  let
    ptrs = makeUncheckedArray(v)
    blob1Len = sqlite3_value_bytes(ptrs[][0])
    blob2Len = sqlite3_value_bytes(ptrs[][1])
    blob3Len = sqlite3_value_bytes(ptrs[][2])

  doAssert(blob1Len == 32 and blob2Len == 32 and blob3Len == 32)

  let
    localId =
      UInt256.fromBytesBE(makeOpenArray(sqlite3_value_blob(ptrs[][0]), byte, blob1Len))
    contentId =
      UInt256.fromBytesBE(makeOpenArray(sqlite3_value_blob(ptrs[][1]), byte, blob2Len))
    radius =
      UInt256.fromBytesBE(makeOpenArray(sqlite3_value_blob(ptrs[][2]), byte, blob3Len))

  if isInRadius(contentId, localId, radius):
    ctx.sqlite3_result_int(cint 1)
  else:
    ctx.sqlite3_result_int(cint 0)
