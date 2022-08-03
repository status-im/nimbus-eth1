
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
  std/[tables, times],
  ./pp_light,
  ../../nimbus/chain_config,
  eth/common

export
  pp_light

# ------------------------------------------------------------------------------
# Public functions,  pretty printer
# ------------------------------------------------------------------------------

proc pp*(b: Blob): string =
  b.mapIt(it.toHex(2)).join.toLowerAscii.pp(hex = true)

proc pp*(a: EthAddress): string =
  a.mapIt(it.toHex(2)).join[32 .. 39].toLowerAscii

proc pp*(a: openArray[EthAddress]): string =
  "[" & a.mapIt(it.pp).join(" ") & "]"

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

proc pp*(a: Account): string =
  &"({a.nonce},{a.balance},{a.storageRoot.pp},{a.codeHash.pp})"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
