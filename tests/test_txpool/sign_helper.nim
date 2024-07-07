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
  ../../nimbus/constants,
  ../../nimbus/utils/ec_recover,
  ../../nimbus/core/tx_pool/tx_item,
  eth/[common, common/transaction, keys],
  results,
  stint

const
  # example from clique, signer: 658bdf435d810c91414ec09147daa6db62406379
  prvKey = "9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"

proc signature(tx: Transaction; key: PrivateKey): (uint64,UInt256,UInt256) =
  let
    hashData = tx.txHashNoSignature.data
    signature = key.sign(SkMessage(hashData)).toRaw
    v = signature[64].uint64

  result[1] = UInt256.fromBytesBE(signature[0..31])
  result[2] = UInt256.fromBytesBE(signature[32..63])

  if tx.txType == TxLegacy:
    if tx.V >= EIP155_CHAIN_ID_OFFSET:
      # just a guess which does not always work .. see `txModPair()`
      # see https://eips.ethereum.org/EIPS/eip-155
      result[0] = (tx.V and not 1'u64) or (not v and 1'u64)
    else:
      result[0] = 27 + v
  else:
    # currently unsupported, will skip this one .. see `txModPair()`
    result[0] = 0'u64


proc sign(tx: Transaction; key: PrivateKey): Transaction =
  let (V,R,S) = tx.signature(key)
  result = tx
  result.V = V
  result.R = R
  result.S = S


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
    tx0Signed = tx0.sign(prvTestKey)
    tx1Signed = tx1.sign(prvTestKey)
  block:
    let rc = tx0Signed.ecRecover
    if rc.isErr or rc.value != testAddress:
      return
  block:
    let rc = tx1Signed.ecRecover
    if rc.isErr or rc.value != testAddress:
      return
  (item,tx0Signed,tx1Signed)

proc testKeySign*(header: BlockHeader): BlockHeader =
  ## Sign the header and embed the signature in extra data
  header.sign(prvTestKey)

proc signerFunc*(signer: EthAddress, msg: openArray[byte]):
                Result[array[RawSignatureSize, byte], cstring] {.gcsafe.} =
  doAssert(signer == testAddress)
  let
    data = keccakHash(msg)
    rawSign  = sign(prvTestKey, SkMessage(data.data)).toRaw

  ok(rawSign)

# End
