# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Aristo (aka Patricia) DB trancoder test

import
  std/sequtils,
  eth/common,
  results,
  stew/byteutils,
  unittest2,
  ../../nimbus/db/aristo,
  ../../nimbus/db/aristo/[aristo_desc, aristo_transcode, aristo_vid],
  ./test_helpers

type
  TesterDesc = object
    prng: uint32                       ## random state

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc posixPrngRand(state: var uint32): byte =
  ## POSIX.1-2001 example of a rand() implementation, see manual page rand(3).
  state = state * 1103515245 + 12345;
  let val = (state shr 16) and 32767    # mod 2^31
  (val shr 8).byte                      # Extract second byte

proc rand[W: SomeInteger|VertexID](ap: var TesterDesc; T: type W): T =
  var a: array[sizeof T,byte]
  for n in 0 ..< sizeof T:
    a[n] = ap.prng.posixPrngRand().byte
  when sizeof(T) == 1:
    let w = uint8.fromBytesBE(a).T
  when sizeof(T) == 2:
    let w = uint16.fromBytesBE(a).T
  when sizeof(T) == 4:
    let w = uint32.fromBytesBE(a).T
  else:
    let w = uint64.fromBytesBE(a).T
  when T is SomeUnsignedInt:
    # That way, `fromBytesBE()` can be applied to `uint`
    result = w
  else:
    # That way the result is independent of endianness
    (addr result).copyMem(unsafeAddr w, sizeof w)

proc vidRand(td: var TesterDesc; bits = 19): VertexID =
  if bits < 64:
    let
      mask = (1u64 shl max(1,bits)) - 1
      rval = td.rand uint64
    (rval and mask).VertexID
  else:
    td.rand VertexID

proc init(T: type TesterDesc; seed: int): TesterDesc =
  result.prng = (seed and 0x7fffffff).uint32

proc `+`(a: VertexID, b: int): VertexID =
  (a.uint64 + b.uint64).VertexID

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc testVidRecycleLists*(noisy = true; seed = 42) =
  ## Transcode VID lists held in `AristoDb` descriptor
  var td = TesterDesc.init seed
  let db = newAristoDbRef BackendVoid

  # Add some randum numbers
  block:
    let first = td.vidRand()
    db.vidDispose first

    var
      expectedVids = 1
      count = 1
    # Feed some numbers used and some discaded
    while expectedVids < 5 or count < 5 + expectedVids:
      count.inc
      let vid = td.vidRand()
      expectedVids += (vid < first).ord
      db.vidDispose vid

    check db.top.vGen.len == expectedVids
    noisy.say "***", "vids=", db.top.vGen.len, " discarded=", count-expectedVids

  # Serialise/deserialise
  block:
    let dbBlob = db.top.vGen.blobify

    # Deserialise
    let
      db1 = newAristoDbRef BackendVoid
      rc = dbBlob.deblobify seq[VertexID]
    if rc.isErr:
      check rc.error == AristoError(0)
    else:
      db1.top.vGen = rc.value

    check db.top.vGen == db1.top.vGen

  # Make sure that recycled numbers are fetched first
  let topVid = db.top.vGen[^1]
  while 1 < db.top.vGen.len:
    let w = db.vidFetch()
    check w < topVid
  check db.top.vGen.len == 1 and db.top.vGen[0] == topVid

  # Get some consecutive vertex IDs
  for n in 0 .. 5:
    let w = db.vidFetch()
    check w == topVid + n
    check db.top.vGen.len == 1

  # Repeat last test after clearing the cache
  db.top.vGen.setLen(0)
  for n in 0 .. 5:
    let w = db.vidFetch()
    check w == VertexID(2) + n # VertexID(1) is default root ID
    check db.top.vGen.len == 1

  # Recycling and re-org tests
  func toVQ(a: seq[int]): seq[VertexID] = a.mapIt(VertexID(it))

  check @[8, 7,  3, 4, 5,  9]    .toVQ.vidReorg == @[3, 4, 5,  7] .toVQ
  check @[8, 7, 6,  3, 4, 5,  9] .toVQ.vidReorg == @[3]           .toVQ
  check @[5, 4, 3,  7]           .toVQ.vidReorg == @[5, 4, 3,  7] .toVQ
  check @[5]                     .toVQ.vidReorg == @[5]           .toVQ
  check @[3, 5]                  .toVQ.vidReorg == @[3, 5]        .toVQ
  check @[4, 5]                  .toVQ.vidReorg == @[4]           .toVQ

  check newSeq[VertexID](0).vidReorg().len == 0

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
