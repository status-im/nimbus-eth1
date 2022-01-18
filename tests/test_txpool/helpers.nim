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
  ../../nimbus/utils/tx_pool/[tx_chain, tx_desc, tx_gauge, tx_item, tx_tabs],
  ../../nimbus/utils/tx_pool/tx_tasks/[tx_packer, tx_recover],
  ../replay/undump,
  eth/[common, keys],
  stew/[keyed_queue, sorted_set],
  stint

# Make sure that the runner can stay on public view without the need
# to import `tx_pool/*` sup-modules
export
  tx_chain.TxChainGasLimits,
  tx_chain.`maxMode=`,
  tx_chain.clearAccounts,
  tx_chain.db,
  tx_chain.limits,
  tx_chain.nextFork,
  tx_chain.profit,
  tx_chain.receipts,
  tx_chain.reward,
  tx_chain.vmState,
  tx_desc.chain,
  tx_desc.txDB,
  tx_desc.verify,
  tx_gauge,
  tx_packer.packerVmExec,
  tx_recover.recoverItem,
  tx_tabs.TxTabsRef,
  tx_tabs.any,
  tx_tabs.decAccount,
  tx_tabs.dispose,
  tx_tabs.eq,
  tx_tabs.flushRejects,
  tx_tabs.gasLimits,
  tx_tabs.ge,
  tx_tabs.gt,
  tx_tabs.incAccount,
  tx_tabs.incNonce,
  tx_tabs.le,
  tx_tabs.len,
  tx_tabs.lt,
  tx_tabs.nItems,
  tx_tabs.reassign,
  tx_tabs.reject,
  tx_tabs.verify,
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
    rc[txItemPending] = "*"
    rc[txItemStaged] = "S"
    rc[txItemPacked] = "P"
    rc

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc joinXX(s: string): string =
  if s.len <= 30:
    return s
  if (s.len and 1) == 0:
    result = s[0 ..< 8]
  else:
    result = "0" & s[0 ..< 7]
  result &= "..(" & $((s.len + 1) div 2) & ").." & s[s.len-16 ..< s.len]

proc joinXX(q: seq[string]): string =
  q.join("").joinXX

proc toXX[T](s: T): string =
  s.toHex.strip(leading=true,chars={'0'}).toLowerAscii

proc toXX(q: Blob): string =
  q.mapIt(it.toHex(2)).join(":")

proc toXX(a: EthAddress): string =
  a.mapIt(it.toHex(2)).joinXX

proc toXX(h: Hash256): string =
  h.data.mapIt(it.toHex(2)).joinXX

proc toXX(v: int64; r,s: UInt256): string =
  v.toXX & ":" & ($r).joinXX & ":" & ($s).joinXX

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

proc pp*(a: BlockNonce): string =
  a.mapIt(it.toHex(2)).join.toLowerAscii

proc pp*(a: EthAddress): string =
  a.mapIt(it.toHex(2)).join[32 .. 39].toLowerAscii

proc pp*(a: Hash256): string =
  a.data.mapIt(it.toHex(2)).join[56 .. 63].toLowerAscii

proc pp*(q: seq[(EthAddress,int)]): string =
  "[" & q.mapIt(&"{it[0].pp}:{it[1]:03d}").join(",") & "]"

proc pp*(w: TxItemStatus): string =
  ($w).replace("txItem")

proc pp*(tx: Transaction): string =
  ## Pretty print transaction (use for debugging)
  result = "(txType=" & $tx.txType

  if tx.chainId.uint64 != 0:
    result &= ",chainId=" & $tx.chainId.uint64

  result &= ",nonce=" & tx.nonce.toXX
  if tx.gasPrice != 0:
    result &= ",gasPrice=" & tx.gasPrice.toKMG
  if tx.maxPriorityFee != 0:
    result &= ",maxPrioFee=" & tx.maxPriorityFee.toKMG
  if tx.maxFee != 0:
    result &= ",maxFee=" & tx.maxFee.toKMG
  if tx.gasLimit != 0:
    result &= ",gasLimit=" & tx.gasLimit.toKMG
  if tx.to.isSome:
    result &= ",to=" & tx.to.get.toXX
  if tx.value != 0:
    result &= ",value=" & tx.value.toKMG
  if 0 < tx.payload.len:
    result &= ",payload=" & tx.payload.toXX
  if 0 < tx.accessList.len:
    result &= ",accessList=" & $tx.accessList

  result &= ",VRS=" & tx.V.toXX(tx.R,tx.S)
  result &= ")"

proc pp*(w: TxItemRef): string =
  ## Pretty print item (use for debugging)
  let s = w.tx.pp
  result = "(timeStamp=" & ($w.timeStamp).replace(' ','_') &
    ",hash=" & w.itemID.toXX &
    ",status=" & w.status.pp &
    "," & s[1 ..< s.len]

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

proc pp*(w: TxTabsItemsCount): string =
  &"{w.pending}/{w.staged}/{w.packed}:{w.total}/{w.disposed}"

proc pp*(w: TxTabsGasTotals): string =
  &"{w.pending}/{w.staged}/{w.packed}"

proc pp*(w: TxChainGasLimits): string =
  &"min={w.minLimit}" &
    &" trg={w.lwmLimit}:{w.trgLimit}" &
    &" max={w.hwmLimit}:{w.maxLimit}"

# ------------------------------------------------------------------------------
# Public functions, other
# ------------------------------------------------------------------------------

proc isOK*(rc: ValidationResult): bool =
  rc == ValidationResult.OK

proc toHex*(acc: EthAddress): string =
  acc.toSeq.mapIt(it.toHex(2)).join

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
