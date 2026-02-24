# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
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
  std/[tables, sets],
  pkg/chronicles,
  pkg/stew/interval_set,
  ../../execution_chain/common,
  ../../execution_chain/sync/beacon/worker/helpers,
  ../../execution_chain/core/chain/forked_chain/chain_desc,
  ../../execution_chain/core/chain/forked_chain/chain_branch

logScope: topics = "forked-chain"

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

func header(h: Hash32; c: ForkedChainRef): Header =
  c.hashToBlock.withValue(h, loc):
    return loc[].header

func baseChains(c: ForkedChainRef): seq[seq[Hash32]] =
  for head in c.heads:
    var hs: seq[Hash32]
    for it in ancestors(head):
      hs.add it.hash
    result.add move(hs)

# ----------------

func cnStr(q: openArray[Hash32]; c: ForkedChainRef): string =
  let (a,b) = (q[0].header(c).number, q[^1].header(c).number)
  result = $a
  if a != b:
    result &= "<<" & $b

# ------------------------------------------------------------------------------
# Public pretty printers
# ------------------------------------------------------------------------------

# Pretty printers
func pp*(n: BlockNumber): string = $n
func pp*(h: Header): string = $h.number
func pp*(b: Block): string = $b.header.number
func pp*(h: Hash32): string = h.short
func pp*(d: BlockRef): string = d.header.pp
func pp*(d: ptr BlockRef): string = d[].pp
func pp*(rc: Result[Header,string]): string =
  if rc.isOk: rc.value.pp else: "err(" &  rc.error & ")"

# ------------------------------------------------------------------------------
# Public object validators
# ------------------------------------------------------------------------------
func headNumber(c: ForkedChainRef): BlockNumber =
  c.latest.number

func headHash(c: ForkedChainRef): Hash32 =
  c.latest.hash

func baseNumber(c: ForkedChainRef): BlockNumber =
  c.base.number

func baseHash(c: ForkedChainRef): Hash32 =
  c.base.hash

func validate*(c: ForkedChainRef): Result[void,string] =
  if c.headNumber < c.baseNumber:
    return err("head block number too low")

  # Empty descriptor (mainly used with unit tests)
  if c.headHash == c.baseHash and
     c.heads.len == 1 and
     c.hashToBlock.len == 1:
    return ok()

  # `head` and `base` must be in the `c.hashToBlock[]`
  if not c.hashToBlock.hasKey(c.headHash):
    return err("head must be in hashToBlock[] table: " & $c.headNumber)
  if not c.hashToBlock.hasKey(c.baseHash):
    return err("base must be in hashToBlock[] table: " & $c.baseNumber)

  if c.base.notFinalized:
    return err("base must have finalized marker")

  # Base chains must range inside `(base,head]`, rooted on `base`
  for chain in c.baseChains:
    if chain[^1] != c.baseHash:
      return err("unbased chain: " & chain.cnStr(c))

  var blocks = initHashSet[Hash32]()
  # Cursor heads must refer to items of `c.blocks[]`
  for head in c.heads:
    for it in ancestors(head):
      if not c.hashToBlock.hasKey(it.hash):
        return err("stray block: " & pp(it))

      if it.number < c.baseNumber:
        return err("branch junction too small: " & $it.number)

      blocks.incl it.hash

  if blocks.len != c.hashToBlock.len:
    return err("inconsistent number of blocks in branches: " & $blocks.len &
      " vs number of block hashes " & $c.hashToBlock.len)

  ok()

proc validate*(c: ForkedChainRef; info: static[string]): bool {.discardable.} =
  let rc = c.validate()
  if rc.isOk:
    return true
  error info & ": invalid desc", error=rc.error

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
