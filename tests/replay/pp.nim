# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
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
  std/[tables, typetraits],
  eth/common,
  stew/byteutils,
  ../../nimbus/common/chain_config,
  ./pp_light

export
  pp_light

# ------------------------------------------------------------------------------
# Public functions,  pretty printer
# ------------------------------------------------------------------------------

func pp*(b: seq[byte]): string =
  b.toHex.pp(hex = true)

func pp*(a: Address): string =
  a.toHex[32 .. 39]

func pp*(a: Opt[Address]): string =
  if a.isSome: a.unsafeGet.pp else: "n/a"

func pp*(a: openArray[Address]): string =
  "[" & a.mapIt(it.pp).join(" ") & "]"

func pp*(a: Bytes8|Bytes32): string =
  a.toHex

func pp*(a: NetworkPayload): string =
  if a.isNil:
    "n/a"
  else:
    "([#" & $a.blobs.len & "],[#" &
      $a.commitments.len & "],[#" &
      $a.proofs.len & "])"

func pp*(h: Header; sep = " "): string =
  "" &
    &"hash={h.blockHash.pp}{sep}" &
    &"blockNumber={h.number}{sep}" &
    &"parentHash={h.parentHash.pp}{sep}" &
    &"coinbase={h.coinbase.pp}{sep}" &
    &"gasLimit={h.gasLimit}{sep}" &
    &"gasUsed={h.gasUsed}{sep}" &
    &"timestamp={h.timestamp}{sep}" &
    &"extraData={h.extraData.pp}{sep}" &
    &"difficulty={h.difficulty}{sep}" &
    &"mixHash={h.mixHash.pp}{sep}" &
    &"nonce={h.nonce.pp}{sep}" &
    &"ommersHash={h.ommersHash.pp}{sep}" &
    &"txRoot={h.txRoot.pp}{sep}" &
    &"receiptsRoot={h.receiptsRoot.pp}{sep}" &
    &"stateRoot={h.stateRoot.pp}{sep}" &
    &"baseFee={h.baseFeePerGas}{sep}" &
    &"withdrawalsRoot={h.withdrawalsRoot.get(EMPTY_ROOT_HASH).pp}{sep}" &
    &"blobGasUsed={h.blobGasUsed.get(0'u64)}{sep}" &
    &"excessBlobGas={h.excessBlobGas.get(0'u64)}"

func pp*(g: Genesis; sep = " "): string =
  "" &
    &"nonce={g.nonce.pp}{sep}" &
    &"timestamp={g.timestamp}{sep}" &
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

func pp*(t: Transaction; sep = " "): string =
  "" &
    &"txType={t.txType}{sep}" &
    &"chainId={t.chainId.distinctBase}{sep}" &
    &"nonce={t.nonce}{sep}" &
    &"gasPrice={t.gasPrice}{sep}" &
    &"maxPriorityFee={t.maxPriorityFeePerGas}{sep}" &
    &"maxFee={t.maxFeePerGas}{sep}" &
    &"gasLimit={t.gasLimit}{sep}" &
    &"to={t.to.pp}{sep}" &
    &"value={t.value}{sep}" &
    &"payload={t.payload.pp}{sep}" &
    &"accessList=[#{t.accessList.len}]{sep}" &
    &"maxFeePerBlobGas={t.maxFeePerBlobGas}{sep}" &
    &"versionedHashes=[#{t.versionedHashes.len}]{sep}" &
    &"V={t.V}{sep}" &
    &"R={t.R}{sep}" &
    &"S={t.S}{sep}"

proc pp*(h: Header; indent: int): string =
  h.pp("\n" & " ".repeat(max(1,indent)))

proc pp*(g: Genesis; indent: int): string =
  g.pp("\n" & " ".repeat(max(1,indent)))

proc pp*(a: Account): string =
  &"({a.nonce},{a.balance},{a.storageRoot.pp},{a.codeHash.pp})"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
