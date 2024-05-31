# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Aristo (aka Patricia) DB trancoder test

import
  std/[sequtils, sets],
  eth/common,
  results,
  stew/byteutils,
  stew/endians2,
  unittest2,
  ../../nimbus/db/aristo,
  ../../nimbus/db/aristo/[
    aristo_check, aristo_debug, aristo_desc, aristo_blobify, aristo_layers,
    aristo_vid],
  ../replay/xcheck,
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

proc testVidRecycleLists*(noisy = true; seed = 42): bool =
  ## Transcode VID lists held in `AristoDb` descriptor
  ##
  var td = TesterDesc.init seed
  let db = AristoDbRef.init()

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

    xCheck db.vGen.len == expectedVids:
      noisy.say "***", "vids=", db.vGen.len, " discarded=", count-expectedVids

  # Serialise/deserialise
  block:
    let dbBlob = db.vGen.blobify

    # Deserialise
    let
      db1 = AristoDbRef.init()
      rc = dbBlob.deblobify seq[VertexID]
    xCheckRc rc.error == 0
    db1.top.final.vGen = rc.value

    xCheck db.vGen == db1.vGen

  # Make sure that recycled numbers are fetched first
  let topVid = db.vGen[^1]
  while 1 < db.vGen.len:
    let w = db.vidFetch()
    xCheck w < topVid
  xCheck db.vGen.len == 1 and db.vGen[0] == topVid

  # Get some consecutive vertex IDs
  for n in 0 .. 5:
    let w = db.vidFetch()
    xCheck w == topVid + n
    xCheck db.vGen.len == 1

  # Repeat last test after clearing the cache
  db.top.final.vGen.setLen(0)
  for n in 0 .. 5:
    let w = db.vidFetch()
    xCheck w == VertexID(LEAST_FREE_VID) + n # VertexID(1) is default root ID
    xCheck db.vGen.len == 1

  # Recycling and re-org tests
  func toVQ(a: seq[int]): seq[VertexID] = a.mapIt(VertexID(LEAST_FREE_VID+it))

  # Heuristic prevents from re-org
  xCheck @[8, 7, 3, 4, 5, 9]    .toVQ.vidReorg == @[8, 7, 3, 4, 5, 9]   .toVQ
  xCheck @[8, 7, 6, 3, 4, 5, 9] .toVQ.vidReorg == @[8, 7, 6, 3, 4, 5, 9].toVQ
  xCheck @[5, 4, 3, 7]          .toVQ.vidReorg == @[5, 4, 3, 7]         .toVQ
  xCheck @[5]                   .toVQ.vidReorg == @[5]                  .toVQ
  xCheck @[3, 5]                .toVQ.vidReorg == @[3, 5]               .toVQ
  xCheck @[4, 5]                .toVQ.vidReorg == @[4, 5]               .toVQ

  # performing re-org
  xCheck @[5, 7, 3, 4, 8, 9]    .toVQ.vidReorg == @[5, 4, 3, 7] .toVQ
  xCheck @[5, 7, 6, 3, 4, 8, 9] .toVQ.vidReorg == @[3]          .toVQ
  xCheck @[3, 4, 5, 7]          .toVQ.vidReorg == @[5, 4, 3, 7] .toVQ

  xCheck newSeq[VertexID](0).vidReorg().len == 0

  true


proc testShortKeys*(
    noisy = true;
      ): bool =
  ## Check for some pathological cases
  func x(s: string): Blob = s.hexToSeqByte
  func k(s: string): HashKey = HashKey.fromBytes(s.x).value

  let samples = [
    # From InvalidBlocks/bc4895-withdrawals/twoIdenticalIndex.json
    [("80".x,
      "da808094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
      "27f166f1d7c789251299535cb176ba34116e44894476a7886fe5d73d9be5c973".k),
     ("01".x,
      "da028094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
      "81eac5f476f48feb289af40ee764015f6b49036760438ea45df90d5342b6ae61".k),
     ("02".x,
      "da018094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
      "463769ae507fcc6d6231c8888425191c5622f330fdd4b78a7b24c4521137b573".k),
     ("03".x,
      "da028094c94f5374fce5edbc8e2a8697c15331677e6ebf0b822710".x,
      "a95b9a7b58a6b3cb4001eb0be67951c5517141cb0183a255b5cae027a7b10b36".k)]]

  let gossip = false # or noisy

  for n,sample in samples:
    let sig = merkleSignBegin()
    var inx = -1
    for (k,v,r) in sample:
      inx.inc
      sig.merkleSignAdd(k,v)
      gossip.say "*** testShortkeys (1)", "n=", n, " inx=", inx,
        "\n    k=", k.toHex, " v=", v.toHex,
        "\n    r=", r.pp(sig),
        "\n    ", sig.pp(),
        "\n"
      let w = sig.merkleSignCommit().value
      gossip.say "*** testShortkeys (2)", "n=", n, " inx=", inx,
        "\n    k=", k.toHex, " v=", v.toHex,
        "\n    r=", r.pp(sig),
        "\n    R=", w.pp(sig),
        "\n    ", sig.pp(),
        "\n    ----------------",
        "\n"
      let rc = sig.db.check
      xCheckRc rc.error == (0,0)
      xCheck r == w

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
