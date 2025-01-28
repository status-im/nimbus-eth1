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

func baseChains(c: ForkedChainRef): seq[seq[Hash32]] =
  for brc in c.branches:
    var hs: seq[Hash32]
    var branch = brc
    while not branch.isNil:
      var hss: seq[Hash32]
      for blk in branch.blocks:
        hss.add blk.hash
      hs = hss.concat(hs)
      branch = branch.parent
    result.add move(hs)

# ----------------

func cnStr(q: openArray[Hash32]; c: ForkedChainRef): string =
  let (a,b) = (q[0].header(c).number, q[^1].header(c).number)
  result = a.bnStr
  if a != b:
    result &= "<<" & b.bnStr

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
func pp*(rc: Result[Header,string]): string =
  if rc.isOk: rc.value.pp else: "err(" &  rc.error & ")"

# ------------------------------------------------------------------------------
# Public object validators
# ------------------------------------------------------------------------------
func headNumber(c: ForkedChainRef): BlockNumber =
  c.activeBranch.headNumber

func headHash(c: ForkedChainRef): Hash32 =
  c.activeBranch.headHash

func baseNumber(c: ForkedChainRef): BlockNumber =
  c.baseBranch.tailNumber

func baseHash(c: ForkedChainRef): Hash32 =
  c.baseBranch.tailHash

func validate*(c: ForkedChainRef): Result[void,string] =
  if c.headNumber < c.baseNumber:
    return err("head block number too low")

  # Empty descriptor (mainly used with unit tests)
  if c.headHash == c.baseHash and
     c.branches.len == 1 and
     c.hashToBlock.len == 0:
    return ok()

  # `head` and `base` must be in the `c.hashToBlock[]`
  if not c.hashToBlock.hasKey(c.headHash):
    return err("head must be in hashToBlock[] table: " & $c.headNumber)
  if not c.hashToBlock.hasKey(c.baseHash):
    return err("base must be in hashToBlock[] table: " & $c.baseNumber)

  # Base chains must range inside `(base,head]`, rooted on `base`
  for chain in c.baseChains:
    if chain[0] != c.baseHash:
      return err("unbased chain: " & chain.cnStr(c))

  # Cursor heads must refer to items of `c.blocks[]`
  for brc in c.branches:
    for bd in brc.blocks:
      if not c.hashToBlock.hasKey(bd.hash):
        return err("stray block: " & pp(bd))

    if brc.tailNumber < c.baseNumber:
      return err("branch junction too small: " & $brc.tailNumber)

    let parent = brc.parent
    if not parent.isNil:
      if brc.tailNumber < parent.tailNumber:
        return err("branch junction too small: " & $brc.tailNumber)

  ok()

proc validate*(c: ForkedChainRef; info: static[string]): bool {.discardable.} =
  let rc = c.validate()
  if rc.isOk:
    return true
  error info & ": invalid desc", error=rc.error

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
