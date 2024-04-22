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
  std/[algorithm, sequtils, sets, strutils],
  eth/common,
  results,
  stew/byteutils,
  stew/endians2,
  unittest2,
  ../../nimbus/db/aristo,
  ../../nimbus/db/aristo/[
    aristo_check, aristo_debug, aristo_desc, aristo_blobify, aristo_layers,
    aristo_vid],
  ../../nimbus/db/aristo/aristo_filter/filter_scheduler,
  ../replay/xcheck,
  ./test_helpers

type
  TesterDesc = object
    prng: uint32                       ## random state

  QValRef = ref object
    fid: FilterID
    width: uint32

  QTabRef = TableRef[QueueID,QValRef]

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

# ---------------------

iterator walkFifo(qt: QTabRef;scd: QidSchedRef): (QueueID,QValRef) =
  ## ...
  proc kvp(chn: int, qid: QueueID): (QueueID,QValRef) =
    let cid = QueueID((chn.uint64 shl 62) or qid.uint64)
    (cid, qt.getOrDefault(cid, QValRef(nil)))

  if not scd.isNil:
    for i in 0 ..< scd.state.len:
      let (left, right) = scd.state[i]
      if left == 0:
        discard
      elif left <= right:
        for j in right.countDown left:
          yield kvp(i, j)
      else:
        for j in right.countDown QueueID(1):
          yield kvp(i, j)
        for j in scd.ctx.q[i].wrap.countDown left:
          yield kvp(i, j)

proc fifos(qt: QTabRef; scd: QidSchedRef): seq[seq[(QueueID,QValRef)]] =
  ## ..
  var lastChn = -1
  for (qid,val) in qt.walkFifo scd:
    let chn = (qid.uint64 shr 62).int
    while lastChn < chn:
      lastChn.inc
      result.add newSeq[(QueueID,QValRef)](0)
    result[^1].add (qid,val)

func sortedPairs(qt: QTabRef): seq[(QueueID,QValRef)] =
  qt.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.QueueID).mapIt((it,qt[it]))

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

proc exec(db: QTabRef; serial: int; instr: seq[QidAction]; relax: bool): bool =
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
          if not relax:
            xCheck not val.isNil
          if not val.isNil:
            if merged.isNil:
              merged = val
            else:
              if relax:
                xCheck merged.fid + merged.width + 1 <= val.fid
              else:
                xCheck merged.fid + merged.width + 1 == val.fid
              merged.width += val.width + 1
            db.del qid
      if not relax:
        xCheck not merged.isNil
      if not merged.isNil:
        db[act.qid] = merged
      hold.setLen(0)

  xCheck saved
  xCheck hold.len == 0

  true


proc validate(db: QTabRef; scd: QidSchedRef; serial: int; relax: bool): bool =
  ## Verify that the round-robin queues in `db` are consecutive and in the
  ## right order.
  var
    step = 1u
    lastVal = FilterID(serial+1)

  for chn,queue in db.fifos scd:
    step *= scd.ctx.q[chn].width + 1        # defined by schedule layout
    for kvp in queue:
      let val = kvp[1]
      if not relax:
        xCheck not val.isNil                # Entries must exist
        xCheck val.fid + step == lastVal    # Item distances must match
      if not val.isNil:
        xCheck val.fid + step <= lastVal    # Item distances must decrease
        xCheck val.width + 1 == step        # Must correspond to `step` size
        lastVal = val.fid

  # Compare database against expected fill state
  if relax:
    xCheck db.len <= scd.len
  else:
    xCheck db.len == scd.len

  proc qFn(qid: QueueID): FilterID =
    let val = db.getOrDefault(qid, QValRef(nil))
    if not val.isNil:
      return val.fid

  # Test filter ID selection
  var lastFid = FilterID(serial + 1)

  xCheck scd.le(lastFid + 0, qFn) == scd[0] # Test fringe condition
  xCheck scd.le(lastFid + 1, qFn) == scd[0] # Test fringe condition

  for (qid,val) in db.fifos(scd).flatten:
    xCheck scd.eq(val.fid, qFn) == qid
    xCheck scd.le(val.fid, qFn) == qid
    for w in val.fid+1 ..< lastFid:
      xCheck scd.le(w, qFn) == qid
      xCheck scd.eq(w, qFn) == QueueID(0)
    lastFid = val.fid

  if FilterID(1) < lastFid:                 # Test fringe condition
    xCheck scd.le(lastFid - 1, qFn) == QueueID(0)

  if FilterID(2) < lastFid:                 # Test fringe condition
    xCheck scd.le(lastFid - 2, qFn) == QueueID(0)

  true

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
  ##    %a      | 10000    |   0   | %a stands for QueueID(10)
  ##    %9      |  9999    |   0   |
  ##    %8      |  9998    |   0   |
  ##    %7      |  9997    |   0   |
  ##            |          |       |
  ##    %1:9    |  9993    |   3   | 9993 + 3 + 1 => 9997, see %7
  ##    %1:8    |  9989    |   3   |
  ##    %1:7    |  9985    |   3   |
  ##    %1:6    |  9981    |   3   | %1:6 stands for QueueID((1 shl 62) + 6)
  ##            |          |       |
  ##    %2:9    |  9961    |  19   | 9961 + 19 + 1 => 9981, see %1:6
  ##    %2:8    |  9941    |  19   |
  ##    %2:7    |  9921    |  19   |
  ##    %2:6    |  9901    |  19   |
  ##    %2:5    |  9881    |  19   |
  ##    %2:4    |  9861    |  19   |
  ##    %2:3    |  9841    |  19   |
  ##            |          |       |
  ##    %3:2    |  9721    | 119   | 9721 + 119 + 1 => 9871, see %2:3
  ##    %3:1    |  9601    | 119   |
  ##    %3:a    |  9481    | 119   |
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
      " ctx=", ctx, " stats=", scd.capacity()

  for n in 1 .. sampleSize:
    let w = scd.addItem()
    let execOk = list.exec(serial=n, instr=w.exec, relax=false)
    xCheck execOk
    scd[] = w.fifo[]
    let validateOk = list.validate(scd, serial=n, relax=false)
    xCheck validateOk:
      show(serial=n, exec=w.exec)

    let fifoID = list.fifos(scd).flatten.mapIt(it[0])
    for j in 0 ..< list.len:
      # Check fifo order
      xCheck fifoID[j] == scd[j]:
        noisy.say "***", "n=", n, " exec=", w.exec.pp,
          " fifoID[", j, "]=", fifoID[j].pp,
          " scd[", j, "]=", scd[j].pp,
          "\n     fifo=", list.pp scd
      # Check random access and reverse
      let qid = scd[j]
      xCheck j == scd[qid]

    if debug:
      show(exec=w.exec)

  # -------------------

  # Mark deleted some entries from database
  var
    nDel = (list.len * reorgPercent) div 100
    delIDs: HashSet[QueueID]
  for n in 0 ..< nDel:
    delIDs.incl scd[n]

  # Delete these entries
  let fetch = scd.fetchItems nDel
  for act in fetch.exec:
    xCheck act.op == HoldQid
    for qid in act.qid .. act.xid:
      xCheck qid in delIDs
      xCheck list.hasKey qid
      delIDs.excl qid
      list.del qid

  xCheck delIDs.len == 0
  scd[] = fetch.fifo[]

  # -------------------

  # Continue adding items
  for n in sampleSize + 1 .. 2 * sampleSize:
    let w = scd.addItem()
    let execOk = list.exec(serial=n, instr=w.exec, relax=true)
    xCheck execOk
    scd[] = w.fifo[]
    let validateOk = list.validate(scd, serial=n, relax=true)
    xCheck validateOk:
      show(serial=n, exec=w.exec)

  # Continue adding items, now strictly
  for n in 2 * sampleSize + 1 .. 3 * sampleSize:
    let w = scd.addItem()
    let execOk = list.exec(serial=n, instr=w.exec, relax=false)
    xCheck execOk
    scd[] = w.fifo[]
    let validateOk = list.validate(scd, serial=n, relax=false)
    xCheck validateOk

  if debug:
    show()

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
