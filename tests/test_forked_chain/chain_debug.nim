# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Test and verifier toolkit for `ForkedChainRef`

{.push raises: [].}

import
  std/[algorithm, sequtils, sets, strutils, tables],
  pkg/chronicles,
  pkg/stew/interval_set,
  ../../nimbus/common,
  ../../nimbus/sync/beacon/worker/helpers,
  ../../nimbus/core/chain/forked_chain/chain_desc,
  ../../nimbus/core/chain/forked_chain/chain_branch

logScope: topics = "forked-chain"

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

func header(h: Hash32; c: ForkedChainRef): Header =
  c.hashToBlock.withValue(h, loc):
    return loc[].header

func cmp(c: ForkedChainRef; _: type CursorDesc): auto =
  return func(x,y: CursorDesc): int =
    result = cmp(x.forkJunction, y.forkJunction)
    if result == 0:
      result = cmp(x.hash.header(c).number, y.hash.header(c).number)

func cmp(c: ForkedChainRef; _: type seq[Hash32]): auto =
  return func(x,y: seq[Hash32]): int =
    result = cmp(x[0].header(c).number, y[0].header(c).number)
    if result == 0:
      result = cmp(x[^1].header(c).number, y[^1].header(c).number)

# ----------------

func baseChains(c: ForkedChainRef): seq[seq[Hash32]] =
  # find leafs
  var leafs = c.blocks.pairs.toSeq.mapIt((it[0],it[1].blk.header)).toTable
  for w in c.blocks.values:
    leafs.del w.blk.header.parentHash
  # Assemble separate chain per leaf
  for (k,v) in leafs.pairs:
    var
      q = @[k]
      w = v.parentHash
    while true:
      c.blocks.withValue(w, val):
        q.add w
        w = val.blk.header.parentHash
      do:
        break
    result.add q.reversed

func baseChainsSorted(c: ForkedChainRef): seq[seq[Hash32]] =
  c.baseChains.sorted(c.cmp seq[Hash32])

# ----------------

func cnStr(q: openArray[Hash32]; c: ForkedChainRef): string =
  let (a,b) = (q[0].header(c).number, q[^1].header(c).number)
  result = a.bnStr
  if a != b:
    result &= "<<" & b.bnStr

func ppImpl[T: Block|Header](q: openArray[T]): string =
  func number(b: Block): BlockNumber = b.header.number
  let bns = IntervalSetRef[BlockNumber,uint64].init()
  for w in q:
    discard bns.merge(w.number,w.number)
  let (a,b) = (bns.total, q.len.uint64 - bns.total)
  "{" & bns.increasing.toSeq.mapIt($it).join(",") & "}[#" & $a & "+" & $b & "]"

# ------------------------------------------------------------------------------
# Public pretty printers
# ------------------------------------------------------------------------------

# Pretty printers
func pp*(n: BlockNumber): string = n.bnStr
func pp*(h: Header): string = h.bnStr
func pp*(b: Block): string = b.bnStr
func pp*(h: Hash32): string = h.short
func pp*(d: BlockDesc): string = d.blk.header.pp
func pp*(d: ptr BlockDesc): string = d[].pp

func pp*(q: openArray[Block]): string = q.ppImpl
func pp*(q: openArray[Header]): string = q.ppImpl

func pp*(rc: Result[Header,string]): string =
  if rc.isOk: rc.value.pp else: "err(" &  rc.error & ")"

# --------------------

func pp*(h: Hash32; c: ForkedChainRef): string =
  c.blocks.withValue(h, val) do:
    return val.blk.header.pp
  if h == c.baseHash:
    return c.baseHeader.pp
  h.short

func pp*(d: CursorDesc; c: ForkedChainRef): string =
  let (a,b) = (d.forkJunction, d.hash.header(c).number)
  result = a.bnStr
  if a != b:
    result &= ".." & (if b == 0: d.hash.pp else: b.pp)

func pp*(d: PivotArc; c: ForkedChainRef): string =
  "(" & d.pvHeader.pp & "," & d.cursor.pp(c) & ")"

func pp*(q: openArray[CursorDesc]; c: ForkedChainRef): string =
  "{" & q.sorted(c.cmp CursorDesc).mapIt(it.pp(c)).join(",") & "}"

func pp*(c: ForkedChainRef): string =
  "(" & c.baseHeader.pp &
    ",{" & c.baseChainsSorted.mapIt(it.cnStr(c)).join(",") & "}" &
    "," & c.cursorHeader.pp &
    "," & c.cursorHeads.pp(c) &
    "," & (if c.extraValidation: "t" else: "f") &
    "," & $c.baseDistance &
    ")"

# ------------------------------------------------------------------------------
# Public object validators
# ------------------------------------------------------------------------------

func validate*(c: ForkedChainRef): Result[void,string] =
  if c.cursorHeader.number < c.baseHeader.number:
    return err("cursor block number too low")

  # Empty descriptor (mainly used with unit tests)
  if c.cursorHash == c.baseHash and
     c.blocks.len == 0 and
     c.cursorHeads.len == 0:
    return ok()

  # `cursorHeader` must be in the `c.blocks[]` table but `base` must not
  if not c.blocks.hasKey(c.cursorHash):
    return err("cursor must be in blocks[] table: " & c.cursorHeader.pp)
  if c.blocks.hasKey(c.baseHash):
    return err("base must not be in blocks[] table: " & c.baseHeader.pp)

  # Base chains must range inside `(base,cursor]`, rooted on `base`
  var bcHeads: HashSet[Hash32]
  for chain in c.baseChains:
    if chain[0].header(c).parentHash != c.baseHash:
      return err("unbased chain: " & chain.cnStr(c))
    bcHeads.incl chain[^1]

  # Cursor heads must refer to items of `c.blocks[]`
  for ch in c.cursorHeads:
    if not c.blocks.hasKey(ch.hash):
      return err("stray cursor head: " & ch.pp(c))

    if ch.forkJunction <= c.baseHeader.number:
      return err("cursor head junction too small: " & ch.pp(c))

    # Get fork junction header
    var h = ch.hash.header(c)
    while ch.forkJunction < h.number:
      c.blocks.withValue(h.parentHash, val):
        h = val.blk.header
      do:
        return err("inconsistent/broken cursor chain " & ch.pp(c))

    # Now: `cn.forkJunction == h.number`, check parent
    if h.parentHash != c.baseHash and not c.blocks.hasKey(h.parentHash):
      return err("unaligned junction of cursor chain " & ch.pp(c))

    # Check cursor heads against assembled chain heads
    if ch.hash notin bcHeads:
      return err("stale or dup cursor chain " & ch.pp(c))

    bcHeads.excl ch.hash

  # Each chain must have exactly one cursor head
  if bcHeads.len != 0:
    return err("missing cursor chain for head " & bcHeads.toSeq[0].pp(c))

  ok()

proc validate*(c: ForkedChainRef; info: static[string]): bool {.discardable.} =
  let rc = c.validate()
  if rc.isOk:
    return true
  error info & ": invalid desc", error=rc.error, c=c.pp

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
