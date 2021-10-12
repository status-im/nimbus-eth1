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
   std/[sequtils, strformat, strutils],
  ../../nimbus/utils/ec_recover,
  ../../nimbus/utils/tx_pool/tx_item,
   eth/[common, common/transaction, keys],
  stew/results,
  stint

const
  # example from clique, signer: 658bdf435d810c91414ec09147daa6db62406379
  pubKey = "658bdf435d810c91414ec09147daa6db62406379"
  prvKey = "9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"

proc toHex(sender: EthAddress): string =
  sender.toSeq.mapIt(&"{it:02x}").join

proc toPrvKey(pkhex: string): PrivateKey =
  let rc = PrivateKey.fromHex(pkhex)
  doAssert rc.isOK
  rc.value

proc signature(tx: Transaction; key: PrivateKey): (int64,UInt256,UInt256) =
  let
    hashData = tx.txHashNoSignature.data
    signature = key.sign(SkMessage(hashData)).toRaw
    v = signature[64].int64

  result[1] = UInt256.fromBytesBE(signature[0..31])
  result[2] = UInt256.fromBytesBE(signature[32..63])

  if tx.txType == TxLegacy:
    if tx.V >= EIP155_CHAIN_ID_OFFSET:
      # just a guess which does not always work .. see `txModPair()`
      # see https://eips.ethereum.org/EIPS/eip-155
      result[0] = (tx.V and not 1'i64) or (not v and 1)
    else:
      result[0] = 27 + v
  else:
    # currently unsupported, will skip this one .. see `txModPair()`
    result[0] = -1


proc sign*(tx: Transaction; key: PrivateKey): Transaction =
  let (V,R,S) = tx.signature(key)
  result = tx
  result.V = V
  result.R = R
  result.S = S

# ------------

proc txModPair*(item: TxItemRef; priceBump: int):
              (TxItemRef,Transaction,Transaction) =
  ## Produce pair of modified txs, might fail => so try another one
  var
    tx0 = item.tx
    tx1 = item.tx
  tx1.gasPrice = (tx0.gasPrice * (100 + priceBump) + 99) div 100
  let
    tx0Signed = tx0.sign(prvKey.toPrvKey)
    tx1Signed = tx1.sign(prvKey.toPrvKey)
  block:
    let rc = tx0Signed.ecRecover
    if rc.isErr or rc.value.toHex != pubKey:
      return
  block:
    let rc = tx1Signed.ecRecover
    if rc.isErr or rc.value.toHex != pubKey:
      return
  (item,tx0Signed,tx1Signed)

# End
