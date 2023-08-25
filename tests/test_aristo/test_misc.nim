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
  std/[algorithm, sequtils, strutils],
  eth/common,
  results,
  stew/byteutils,
  unittest2,
  ../../nimbus/db/aristo,
  ../../nimbus/db/aristo/[
    aristo_debug, aristo_desc, aristo_transcode, aristo_vid],
  ../../nimbus/db/aristo/aristo_filter/[filter_desc, filter_scheduler],
  ./test_helpers

type
  TesterDesc = object
    prng: uint32                       ## random state

  QValRef = ref object
    fid: FilterID
    width: uint32

  QTab = Table[QueueID,QValRef]

const
  QidSlotLyo = [(4,0,10),(3,3,10),(3,4,10),(3,5,10)]
  QidSlotLy1 = [(4,0,0),(3,3,0),(3,4,0),(3,5,0)]

  QidSample* = (3 * QidSlotLyo.stats.minCovered) div 2

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template trueOrReturn(expr: untyped): untyped =
  if not (expr):
    check expr
    return

# ---------------------

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

# ---------------------

func sortedPairs(t: QTab): seq[(QueueID,QValRef)] =
  t.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.QueueID).mapIt((it,t[it]))

func fifos(qt: QTab; scd: QidSchedRef): seq[seq[(QueueID,QValRef)]] =
  proc kvp(chn: int, qid: QueueID): (QueueID,QValRef) =
    let
      cid = QueueID((chn.uint64 shl 62) or qid.uint64)
      val = qt.getOrDefault(cid, QValRef(nil))
    (qid, val)

  for i in 0 ..< scd.state.len:
    let
      left =  scd.state[i][0]
      right = scd.state[i][1]
    result.add newSeq[(QueueID,QValRef)](0)
    if left <= right:
      for j in left .. right:
        result[i].add kvp(i, j)
    else:
      for j in left .. scd.ctx.q[i].wrap:
        result[i].add kvp(i, j)
      for j in QueueID(1) .. right:
        result[i].add kvp(i, j)

func flatten(a: seq[seq[(QueueID,QValRef)]]): seq[(QueueID,QValRef)] =
  for w in a:
    result &= w

func pp(val: QValRef): string =
  if val.isNil:
    return "ø"
  result = $val.fid.uint64
  if 0 < val.width:
    result &= ":" & $val.width

func pp(kvp: (QueueID,QValRef)): string =
  kvp[0].pp & "=" & kvp[1].pp

func pp(t: QTab): string =
  "{" & t.sortedPairs.mapIt(it.pp).join(",") & "}"

func pp(t: QTab; scd: QidSchedRef): string =
  "[" & t.fifos(scd).flatten.mapIt(it.pp).join(",") & "]"

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc testVidRecycleLists*(noisy = true; seed = 42): bool =
  ## Transcode VID lists held in `AristoDb` descriptor
  ##
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

    trueOrReturn db.top.vGen.len == expectedVids
    noisy.say "***", "vids=", db.top.vGen.len, " discarded=", count-expectedVids

  # Serialise/deserialise
  block:
    let dbBlob = db.top.vGen.blobify

    # Deserialise
    let
      db1 = newAristoDbRef BackendVoid
      rc = dbBlob.deblobify seq[VertexID]
    if rc.isErr:
      trueOrReturn rc.error == AristoError(0)
    else:
      db1.top.vGen = rc.value

    trueOrReturn db.top.vGen == db1.top.vGen

  # Make sure that recycled numbers are fetched first
  let topVid = db.top.vGen[^1]
  while 1 < db.top.vGen.len:
    let w = db.vidFetch()
    trueOrReturn w < topVid
  trueOrReturn db.top.vGen.len == 1 and db.top.vGen[0] == topVid

  # Get some consecutive vertex IDs
  for n in 0 .. 5:
    let w = db.vidFetch()
    trueOrReturn w == topVid + n
    trueOrReturn db.top.vGen.len == 1

  # Repeat last test after clearing the cache
  db.top.vGen.setLen(0)
  for n in 0 .. 5:
    let w = db.vidFetch()
    trueOrReturn w == VertexID(2) + n # VertexID(1) is default root ID
    trueOrReturn db.top.vGen.len == 1

  # Recycling and re-org tests
  func toVQ(a: seq[int]): seq[VertexID] = a.mapIt(VertexID(it))

  trueOrReturn @[8, 7,  3, 4, 5,  9]    .toVQ.vidReorg == @[3, 4, 5,  7] .toVQ
  trueOrReturn @[8, 7, 6,  3, 4, 5,  9] .toVQ.vidReorg == @[3]           .toVQ
  trueOrReturn @[5, 4, 3,  7]           .toVQ.vidReorg == @[5, 4, 3,  7] .toVQ
  trueOrReturn @[5]                     .toVQ.vidReorg == @[5]           .toVQ
  trueOrReturn @[3, 5]                  .toVQ.vidReorg == @[3, 5]        .toVQ
  trueOrReturn @[4, 5]                  .toVQ.vidReorg == @[4]           .toVQ

  trueOrReturn newSeq[VertexID](0).vidReorg().len == 0

  true


proc testQidScheduler*(
    noisy = true;
    layout = QidSlotLyo;
    sampleSize = QidSample;
      ): bool =
  ##
  ## Example table for `QidSlotLyo` layout after 10_000 cycles
  ## ::
  ##    QueueID |       QValRef    |
  ##            | FilterID | width | comment
  ##    --------+----------+-------+----------------------------------
  ##    %7      |  9997    |   0   | %7 stands for QueueID(7)
  ##    %8      |  9998    |   0   |
  ##    %9      |  9999    |   0   |
  ##    %a      | 10000    |   0   |
  ##            |          |       |
  ##    %1:6    |  9981    |   3   | %1:6 stands for QueueID((1 shl 62) + 6)
  ##    %1:7    |  9985    |   3   |
  ##    %1:8    |  9989    |   3   |
  ##    %1:9    |  9993    |   3   | 9993 + 3 + 1 => 9997, see %7
  ##            |          |       |
  ##    %2:3    |  9841    |  19   |
  ##    %2:4    |  9861    |  19   |
  ##    %2:5    |  9881    |  19   |
  ##    %2:6    |  9901    |  19   |
  ##    %2:7    |  9921    |  19   |
  ##    %2:8    |  9941    |  19   |
  ##    %2:9    |  9961    |  19   | 9961 + 19 + 1 => 9981, see %1:6
  ##            |          |       |
  ##    %3:a    |  9481    | 119   |
  ##    %3:1    |  9601    | 119   |
  ##    %3:2    |  9721    | 119   | 9721 + 119 + 1 => 9871, see %2:3
  ##
  var
    list: Qtab
    debug = false # or true
  let
    scd = QidSchedRef.init layout
    ctx = scd.ctx.q

  if debug:
    noisy.say "***", "testFilterSchedule",
      " ctx=", ctx,
      " stats=", scd.ctx.stats

  for n in 1 .. sampleSize:
    let w = scd.addItem()

    if debug and false:
      noisy.say "***", "testFilterSchedule",
        " n=", n,
        " => ", w.exec.pp,
        " / ", w.fifo.state.pp

    var
      saved = false
      hold: seq[(QueueID,QueueID)]
    for act in w.exec:
      case act.op:
      of Oops:
        noisy.say "***", "testFilterSchedule", " n=", n, " act=", act.pp

      of SaveQid:
        if saved:
          noisy.say "***", "testFilterSchedule", " n=", n, " act=", act.pp,
            " hold=", hold.pp, " state=", scd.state.pp, " fifo=", list.pp scd
          check not saved
          return
        list[act.qid] = QValRef(fid: FilterID(n))
        saved = true

      of HoldQid:
        hold.add (act.qid, act.xid)

      of DequQid:
        var merged = QValRef(nil)
        for w in hold:
          for qid in w[0] .. w[1]:
            let val = list.getOrDefault(qid, QValRef(nil))
            if val.isNil:
              noisy.say "***", "testFilterSchedule", " n=", n, " act=", act.pp,
               " hold=", hold.pp, " state=", scd.state.pp, " fifo=", list.pp scd
              check not val.isNil
              return
            if merged.isNil:
              merged = val
            elif merged.fid + merged.width + 1 == val.fid:
              merged.width += val.width + 1
            else:
              noisy.say "***", "testFilterSchedule", " n=", n, " act=", act.pp,
               " hold=", hold.pp, " state=", scd.state.pp, " fifo=", list.pp scd
              check merged.fid + merged.width + 1 == val.fid
              return
            list.del qid
        if merged.isNil:
          noisy.say "***", "testFilterSchedule", " n=", n, " act=", act.pp,
            " hold=", hold.pp, " state=", scd.state.pp, " fifo=", list.pp scd
          check not merged.isNil
          return
        list[act.qid] = merged
        hold.setLen(0)

    scd[] = w.fifo[]

    # Verify that the round-robin queues in `list` are consecutive and in the
    # right order.
    var
      botVal = FilterID(0)
      step = 1u
    for chn,queue in list.fifos scd:
      var lastVal = FilterID(0)
      step *= ctx[chn].width + 1 # defined by schedule layout

      for kvp in queue:
        let (qid,val) = (kvp[0], kvp[1])

        # Entries must exist
        if val.isNil:
          noisy.say "***", "testFilterSchedule", " n=", n, " chn=", chn,
            " exec=", w.exec.pp, " kvp=", kvp.pp, " fifo=", list.pp scd
          check not val.isNil
          return

        # Fid value fields must increase witin a sub-queue.
        if val.fid <= lastVal:
          noisy.say "***", "testFilterSchedule", " n=", n, " chn=", chn,
            " exec=", w.exec.pp, " kvp=", kvp.pp, " fifo=", list.pp scd
          check lastVal < val.fid
          return

        # Width value must correspond to `step` size
        if val.width + 1 != step:
          noisy.say "***", "testFilterSchedule", " n=", n, " chn=", chn,
            " exec=", w.exec.pp, " kvp=", kvp.pp, " fifo=", list.pp scd
          check val.width + 1 == step
          return

        # Item distances must match the step width
        if lastVal != 0:
          let dist = val.fid - lastVal
          if dist != step.uint64:
            noisy.say "***", "testFilterSchedule", " n=", n, " chn=", chn,
              " exec=", w.exec.pp, " kvp=", kvp.pp, " fifo=", list.pp scd
            check dist == step.uint64
            return
        lastVal = val.fid

      # The top value of the current queue must be smaller than the
      # bottom value of the previous one
      if 0 < chn and botVal != queue[^1][1].fid + step.uint64:
        noisy.say "***", "testFilterSchedule", " n=", n, " chn=", chn,
          " exec=", w.exec.pp, " step=", step, " fifo=", list.pp scd
        check botVal == queue[^1][1].fid + step.uint64
        return
      botVal = queue[0][1].fid

    if debug:
     noisy.say "***", "testFilterSchedule",
        " n=", n,
        "\n     exec=", w.exec.pp,
        "\n    state=", scd.state.pp,
        "\n     list=", list.pp,
        "\n     fifo=", list.pp scd,
        "\n"

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
