# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../../nimbus/[constants, transaction],
  ../../nimbus/utils/ec_recover,
  ../../nimbus/core/tx_pool/tx_item,
  eth/[common, common/transaction, keys],
  results,
  stint

const
  # example from clique, signer: 658bdf435d810c91414ec09147daa6db62406379
  prvKey = "9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"

proc sign(header: BlockHeader; key: PrivateKey): BlockHeader =
  let
    hashData = header.blockHash.data
    signature = key.sign(SkMessage(hashData)).toRaw
  result = header
  result.extraData.add signature

# ------------

let
  prvTestKey* = PrivateKey.fromHex(prvKey).value
  pubTestKey* = prvTestKey.toPublicKey
  testAddress* = pubTestKey.toCanonicalAddress

proc txModPair*(item: TxItemRef; nonce: int; priceBump: int):
              (TxItemRef,Transaction,Transaction) =
  ## Produce pair of modified txs, might fail => so try another one
  var tx0 = item.tx
  tx0.nonce = nonce.AccountNonce

  var tx1 = tx0
  tx1.gasPrice = (tx0.gasPrice * (100 + priceBump).GasInt + 99.GasInt) div 100

  let
    tx0Signed = tx0.signTransaction(prvTestKey)
    tx1Signed = tx0.signTransaction(prvTestKey)
  block:
    let rc = tx0Signed.recoverSender()
    if rc.isErr or rc.value != testAddress:
      return
  block:
    let rc = tx1Signed.recoverSender()
    if rc.isErr or rc.value != testAddress:
      return
  (item,tx0Signed,tx1Signed)

proc testKeySign*(header: BlockHeader): BlockHeader =
  ## Sign the header and embed the signature in extra data
  header.sign(prvTestKey)

proc signerFunc*(signer: Address, msg: openArray[byte]):
                Result[array[RawSignatureSize, byte], cstring] {.gcsafe.} =
  doAssert(signer == testAddress)
  let
    data = keccakHash(msg)
    rawSign  = sign(prvTestKey, SkMessage(data.data)).toRaw

  ok(rawSign)

# End
