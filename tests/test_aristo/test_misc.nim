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
  std/[algorithm, sequtils, sets, strutils],
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

  QTabRef = TableRef[QueueID,QValRef]

const
  QidSlotLyo = [(4,0,10),(3,3,10),(3,4,10),(3,5,10)]
  QidSlotLy1 = [(4,0,0),(3,3,0),(3,4,0),(3,5,0)]

  QidSample* = (3 * QidSlotLyo.stats.minCovered) div 2

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template xCheck(expr: untyped): untyped =
  ## Note: this check will invoke `expr` twice
  if not (expr):
    check expr
    return

template xCheck(expr: untyped; ifFalse: untyped): untyped =
  ## Note: this check will invoke `expr` twice
  if not (expr):
    ifFalse
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

func sortedPairs(qt: QTabRef): seq[(QueueID,QValRef)] =
  qt.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.QueueID).mapIt((it,qt[it]))

func fifos(qt: QTabRef; scd: QidSchedRef): seq[seq[(QueueID,QValRef)]] =
  proc kvp(chn: int, qid: QueueID): (QueueID,QValRef) =
    let
      cid = QueueID((chn.uint64 shl 62) or qid.uint64)
      val = qt.getOrDefault(cid, QValRef(nil))
    (cid, val)

  for i in 0 ..< scd.state.len:
    let
      left =  scd.state[i][0]
      right = scd.state[i][1]
    result.add newSeq[(QueueID,QValRef)](0)
    if left == 0:
      discard
    elif left <= right:
      for j in right.countDown left:
        result[i].add kvp(i, j)
    else:
      for j in right.countDown QueueID(1):
        result[i].add kvp(i, j)
      for j in scd.ctx.q[i].wrap.countDown left:
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

func pp(qt: QTabRef): string =
  "{" & qt.sortedPairs.mapIt(it.pp).join(",") & "}"

func pp(qt: QTabRef; scd: QidSchedRef): string =
  result = "["
  for w in qt.fifos scd:
    if w.len == 0:
      result &= "ø"
    else:
      result &= w.mapIt(it.pp).join(",")
    result &= ","
  if result[^1] == ',':
    result[^1] = ']'
  else:
    result &= "]"

# ------------------

proc exec(db: QTabRef; serial: int; instr: seq[QidAction]): bool =
  ## ..
  var
    saved: bool
    hold: seq[(QueueID,QueueID)]

  for act in instr:
    case act.op:
    of Oops:
      xCheck act.op != Oops

    of SaveQid:
      xCheck not saved
      db[act.qid] = QValRef(fid: FilterID(serial))
      saved = true

    of DelQid:
      let val = db.getOrDefault(act.qid, QValRef(nil))
      xCheck not val.isNil
      db.del act.qid

    of HoldQid:
      hold.add (act.qid, act.xid)

    of DequQid:
      var merged = QValRef(nil)
      for w in hold:
        for qid in w[0] .. w[1]:
          let val = db.getOrDefault(qid, QValRef(nil))
          xCheck not val.isNil
          if merged.isNil:
            merged = val
          else:
            xCheck merged.fid + merged.width + 1 == val.fid
            merged.width += val.width + 1
          db.del qid
      xCheck not merged.isNil
      db[act.qid] = merged
      hold.setLen(0)

  xCheck saved
  xCheck hold.len == 0

  true


proc validate(db: QTabRef; scd: QidSchedRef; serial: int): bool =
  ## Verify that the round-robin queues in `db` are consecutive and in the
  ## right order.
  var
    step = 1u
    lastVal = FilterID(serial+1)

  for chn,queue in db.fifos scd:
    step *= scd.ctx.q[chn].width + 1        # defined by schedule layout
    for kvp in queue:
      let (qid,val) = (kvp[0], kvp[1])
      xCheck not val.isNil                  # Entries must exist
      xCheck val.fid + step == lastVal      # Item distances must match
      xCheck val.width + 1 == step          # Must correspond to `step` size
      lastVal = val.fid

  # Compare database against expected fill state
  xCheck db.len == scd.len

  true

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

    xCheck db.top.vGen.len == expectedVids
    noisy.say "***", "vids=", db.top.vGen.len, " discarded=", count-expectedVids

  # Serialise/deserialise
  block:
    let dbBlob = db.top.vGen.blobify

    # Deserialise
    let
      db1 = newAristoDbRef BackendVoid
      rc = dbBlob.deblobify seq[VertexID]
    if rc.isErr:
      xCheck rc.error == AristoError(0)
    else:
      db1.top.vGen = rc.value

    xCheck db.top.vGen == db1.top.vGen

  # Make sure that recycled numbers are fetched first
  let topVid = db.top.vGen[^1]
  while 1 < db.top.vGen.len:
    let w = db.vidFetch()
    xCheck w < topVid
  xCheck db.top.vGen.len == 1 and db.top.vGen[0] == topVid

  # Get some consecutive vertex IDs
  for n in 0 .. 5:
    let w = db.vidFetch()
    xCheck w == topVid + n
    xCheck db.top.vGen.len == 1

  # Repeat last test after clearing the cache
  db.top.vGen.setLen(0)
  for n in 0 .. 5:
    let w = db.vidFetch()
    xCheck w == VertexID(2) + n # VertexID(1) is default root ID
    xCheck db.top.vGen.len == 1

  # Recycling and re-org tests
  func toVQ(a: seq[int]): seq[VertexID] = a.mapIt(VertexID(it))

  xCheck @[8, 7,  3, 4, 5,  9]    .toVQ.vidReorg == @[3, 4, 5,  7] .toVQ
  xCheck @[8, 7, 6,  3, 4, 5,  9] .toVQ.vidReorg == @[3]           .toVQ
  xCheck @[5, 4, 3,  7]           .toVQ.vidReorg == @[5, 4, 3,  7] .toVQ
  xCheck @[5]                     .toVQ.vidReorg == @[5]           .toVQ
  xCheck @[3, 5]                  .toVQ.vidReorg == @[3, 5]        .toVQ
  xCheck @[4, 5]                  .toVQ.vidReorg == @[4]           .toVQ

  xCheck newSeq[VertexID](0).vidReorg().len == 0

  true


proc testQidScheduler*(
    noisy = true;
    layout = QidSlotLyo;
    sampleSize = QidSample;
    reorgPercent = 40
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
    debug = false # or true
  let
    list = newTable[QueueID,QValRef]()
    scd = QidSchedRef.init layout
    ctx = scd.ctx.q

  proc show(serial = 0; exec: seq[QidAction] = @[]) =
    var s = ""
    if 0 < serial:
      s &= "n=" & $serial
    if 0 < exec.len:
      s &= " exec=" & exec.pp
    s &= "" &
      "\n   state=" & scd.state.pp &
      "\n    list=" & list.pp &
      "\n    fifo=" & list.pp(scd) &
      "\n"
    noisy.say "***", s

  if debug:
    noisy.say "***", "sampleSize=", sampleSize,
      " ctx=", ctx, " stats=", scd.ctx.stats

  for n in 1 .. sampleSize:
    let w = scd.addItem()
    let execOk = list.exec(serial=n, instr=w.exec)
    xCheck execOk
    scd[] = w.fifo[]
    let validateOk = list.validate(scd, serial=n)
    xCheck validateOk:
      show(serial=n, exec=w.exec)

    let fifoID = list.fifos(scd).flatten.mapIt(it[0])
    for j in 0 ..< list.len:
      xCheck fifoID[j] == scd[j]:
        noisy.say "***", "n=", n, " exec=", w.exec.pp,
          " fifoID[", j, "]=", fifoID[j].pp,
          " scd[", j, "]=", scd[j].pp,
          "\n     fifo=", list.pp scd

  if debug:
    show()

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
