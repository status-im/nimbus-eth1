# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Pretty printing, an alternative to `$` for debugging
## ----------------------------------------------------

import
  std/[sequtils, strformat, strutils, tables, times],
  ../../nimbus/[chain_config, constants],
  eth/[common, trie/trie_defs]

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc reGroup(q: openArray[int]; itemsPerSegment = 16): seq[seq[int]] =
  var top = 0
  while top < q.len:
    let w = top
    top = min(w + itemsPerSegment, q.len)
    result.add q[w ..< top]

# ------------------------------------------------------------------------------
# Public functions, units pretty printer
# ------------------------------------------------------------------------------

proc ppMs*(elapsed: Duration): string =
  result = $elapsed.inMilliSeconds
  let ns = elapsed.inNanoSeconds mod 1_000_000
  if ns != 0:
    # to rounded deca milli seconds
    let dm = (ns + 5_000i64) div 10_000i64
    result &= &".{dm:02}"
  result &= "ms"

proc ppSecs*(elapsed: Duration): string =
  result = $elapsed.inSeconds
  let ns = elapsed.inNanoseconds mod 1_000_000_000
  if ns != 0:
    # to rounded decs seconds
    let ds = (ns + 5_000_000i64) div 10_000_000i64
    result &= &".{ds:02}"
  result &= "s"

proc toKMG*[T](s: T): string =
  proc subst(s: var string; tag, new: string): bool =
    if tag.len < s.len and s[s.len - tag.len ..< s.len] == tag:
      s = s[0 ..< s.len - tag.len] & new
      return true
  result = $s
  for w in [("000", "K"),("000K","M"),("000M","G"),("000G","T"),
            ("000T","P"),("000P","E"),("000E","Z"),("000Z","Y")]:
    if not result.subst(w[0],w[1]):
      return

# ------------------------------------------------------------------------------
# Public functions,  pretty printer
# ------------------------------------------------------------------------------

proc pp*(s: string; hex = false): string =
  if hex:
    let n = (s.len + 1) div 2
    (if s.len < 20: s else: s[0 .. 5] & ".." & s[s.len-8 .. s.len-1]) &
      "[" & (if 0 < n: "#" & $n else: "") & "]"
  elif s.len <= 30:
    s
  else:
    (if (s.len and 1) == 0: s[0 ..< 8] else: "0" & s[0 ..< 7]) &
      "..(" & $s.len & ").." & s[s.len-16 ..< s.len]

proc pp*(q: openArray[int]; itemsPerLine: int; lineSep: string): string =
  doAssert q == q.reGroup(itemsPerLine).concat
  q.reGroup(itemsPerLine)
   .mapIt(it.mapIt(&"0x{it:02x}").join(", "))
   .join("," & lineSep)

proc pp*(b: Blob): string =
  b.mapIt(it.toHex(2)).join.toLowerAscii.pp(hex = true)

proc pp*(a: Hash256; collapse = true): string =
  if not collapse:
    a.data.mapIt(it.toHex(2)).join.toLowerAscii
  elif a == emptyRlpHash:
    "emptyRlpHash"
  elif a == EMPTY_UNCLE_HASH:
    "EMPTY_UNCLE_HASH"
  elif a == EMPTY_SHA3:
    "EMPTY_SHA3"
  else:
    a.data.mapIt(it.toHex(2)).join[56 .. 63].toLowerAscii

proc pp*(a: openArray[Hash256]; collapse = true): string =
  "@[" & a.toSeq.mapIt(it.pp).join(" ") & "]"

proc pp*(a: EthAddress): string =
  a.mapIt(it.toHex(2)).join[32 .. 39].toLowerAscii

proc pp*(a: BlockNonce): string =
  a.mapIt(it.toHex(2)).join.toLowerAscii

proc pp*(h: BlockHeader; sep = " "): string =
  "" &
    &"hash={h.blockHash.pp}{sep}" &
    &"blockNumber={h.blockNumber}{sep}" &
    &"parentHash={h.parentHash.pp}{sep}" &
    &"coinbase={h.coinbase.pp}{sep}" &
    &"gasLimit={h.gasLimit}{sep}" &
    &"gasUsed={h.gasUsed}{sep}" &
    &"timestamp={h.timestamp.toUnix}{sep}" &
    &"extraData={h.extraData.pp}{sep}" &
    &"difficulty={h.difficulty}{sep}" &
    &"mixDigest={h.mixDigest.pp}{sep}" &
    &"nonce={h.nonce.pp}{sep}" &
    &"ommersHash={h.ommersHash.pp}{sep}" &
    &"txRoot={h.txRoot.pp}{sep}" &
    &"receiptRoot={h.receiptRoot.pp}{sep}" &
    &"stateRoot={h.stateRoot.pp}{sep}" &
    &"baseFee={h.baseFee}"

proc pp*(g: Genesis; sep = " "): string =
  "" &
    &"nonce={g.nonce.pp}{sep}" &
    &"timestamp={g.timestamp.toUnix}{sep}" &
    &"extraData={g.extraData.pp}{sep}" &
    &"gasLimit={g.gasLimit}{sep}" &
    &"difficulty={g.difficulty}{sep}" &
    &"mixHash={g.mixHash.pp}{sep}" &
    &"coinbase={g.coinbase.pp}{sep}" &
    &"alloc=<{g.alloc.len} accounts>{sep}" &
    &"number={g.number}{sep}" &
    &"gasUser={g.gasUser}{sep}" &
    &"parentHash={g.parentHash.pp}{sep}" &
    &"baseFeePerGas={g.baseFeePerGas}"




proc pp*(h: BlockHeader; indent: int): string =
  h.pp("\n" & " ".repeat(max(1,indent)))

proc pp*(g: Genesis; indent: int): string =
  g.pp("\n" & " ".repeat(max(1,indent)))

proc pp*(q: openArray[int]; itemsPerLine: int; indent: int): string =
  q.pp(itemsPerLine = itemsPerLine, lineSep = "\n" & " ".repeat(max(1,indent)))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
