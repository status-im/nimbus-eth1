# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[options, times],
  eth/common,
  stew/byteutils

proc `$`(hash: Hash256): string =
  hash.data.toHex

proc `$`(address: openArray[byte]): string =
  address.toHex

proc `$`(bloom: BloomFilter): string =
  bloom.toHex

proc `$`(nonce: BlockNonce): string =
  nonce.toHex

proc `$`(data: Blob): string =
  data.toHex

proc debug*(h: BlockHeader): string =
  result.add "parentHash     : " & $h.parentHash  & "\n"
  result.add "ommersHash     : " & $h.ommersHash  & "\n"
  result.add "coinbase       : " & $h.coinbase    & "\n"
  result.add "stateRoot      : " & $h.stateRoot   & "\n"
  result.add "txRoot         : " & $h.txRoot      & "\n"
  result.add "receiptRoot    : " & $h.receiptRoot & "\n"
  result.add "bloom          : " & $h.bloom       & "\n"
  result.add "difficulty     : " & $h.difficulty  & "\n"
  result.add "blockNumber    : " & $h.blockNumber & "\n"
  result.add "gasLimit       : " & $h.gasLimit    & "\n"
  result.add "gasUsed        : " & $h.gasUsed     & "\n"
  result.add "timestamp      : " & $h.timestamp.toUnix   & "\n"
  result.add "extraData      : " & $h.extraData   & "\n"
  result.add "mixDigest      : " & $h.mixDigest   & "\n"
  result.add "nonce          : " & $h.nonce       & "\n"
  result.add "fee.isSome     : " & $h.fee.isSome  & "\n"
  if h.fee.isSome:
    result.add "fee            : " & $h.fee.get()   & "\n"
  if h.withdrawalsRoot.isSome:
    result.add "withdrawalsRoot: " & $h.withdrawalsRoot.get() & "\n"
  result.add "blockHash      : " & $blockHash(h) & "\n"
