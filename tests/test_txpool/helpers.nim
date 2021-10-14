# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[strformat, sequtils, strutils, times],
  ../../nimbus/utils/keequ,
  ../../nimbus/utils/tx_pool/[tx_desc, tx_item, tx_tabs],
  ../replay/undump,
  eth/[common, keys],
  stint

# Make sure that the runner can stay on public view without the need
# to import `tx_pool/*` sup-modules
export
  keequ,
  tx_desc.dbHead,
  tx_desc.txDB,
  tx_desc.verify,
  tx_tabs.TxTabsRef,
  tx_tabs.`baseFee=`,
  tx_tabs.any,
  tx_tabs.baseFee,
  tx_tabs.decItemList,
  tx_tabs.decNonceList,
  tx_tabs.dispose,
  tx_tabs.eq,
  tx_tabs.first,
  tx_tabs.flushRejects,
  tx_tabs.ge,
  tx_tabs.gt,
  tx_tabs.incItemList,
  tx_tabs.incNonceList,
  tx_tabs.last,
  tx_tabs.le,
  tx_tabs.len,
  tx_tabs.lt,
  tx_tabs.nItems,
  tx_tabs.next,
  tx_tabs.prev,
  tx_tabs.reassign,
  tx_tabs.reject,
  tx_tabs.verify,
  tx_tabs.walkItems,
  tx_tabs.walkNonceList,
  tx_tabs.walkSchedList,
  undumpNextGroup

const
  # pretty printing
  localInfo* = block:
    var rc: array[bool,string]
    rc[true] = "L"
    rc[false] = "R"
    rc

  statusInfo* = block:
    var rc: array[TxItemStatus,string]
    rc[txItemQueued] = "Q"
    rc[txItemPending] = "P"
    rc[txItemStaged] = "S"
    rc

proc toHex*(acc: EthAddress): string =
  acc.toSeq.mapIt(&"{it:02x}").join

proc pp*(txs: openArray[Transaction]; pfx = ""): string =
  let txt = block:
    var rc = ""
    if 0 < txs.len:
      rc = "[" & txs[0].pp
      for n in 1 ..< txs.len:
        rc &= ";" & txs[n].pp
      rc &= "]"
    rc
  txt.multiReplace([
    (",", &",\n   {pfx}"),
    (";", &",\n  {pfx}")])

proc pp*(txs: openArray[Transaction]; pfxLen: int): string =
  txs.pp(" ".repeat(pfxLen))

proc pp*(it: TxItemRef): string =
  result = it.info.split[0]
  if it.local:
    result &= "L"
  else:
    result &= "R"

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

template showElapsed*(noisy: bool; info: string; code: untyped) =
  let start = getTime()
  code
  if noisy:
    let elpd {.inject.} = getTime() - start
    if 0 < elpd.inSeconds:
      echo "*** ", info, &": {elpd.ppSecs:>4}"
    else:
      echo "*** ", info, &": {elpd.ppMs:>4}"

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

# End
