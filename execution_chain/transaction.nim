# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./[constants],
  ./core/pooled_txs_rlp,
  eth/common/[addresses, keys, transactions, transactions_rlp, transaction_utils]

export addresses, keys, transactions

proc signTransaction*(tx: Transaction, privateKey: PrivateKey, eip155 = true): Transaction =
  result = tx
  result.signature = result.sign(privateKey, eip155)

# deriveChainId derives the chain id from the given v parameter
func deriveChainId*(v: uint64, chainId: ChainId): ChainId =
  if v == 27 or v == 28:
    chainId
  else:
    ((v - 35) div 2).u256

func validateChainId*(tx: Transaction, chainId: ChainId): bool =
  if tx.txType == TxLegacy:
    chainId == deriveChainId(tx.V, chainId)
  else:
    chainId == tx.chainId

func maxPriorityFeePerGasNorm*(tx: Transaction): GasInt =
  if tx.txType < TxEip1559:
    tx.gasPrice
  else:
    tx.maxPriorityFeePerGas

func maxFeePerGasNorm*(tx: Transaction): GasInt =
  if tx.txType < TxEip1559:
    tx.gasPrice
  else:
    tx.maxFeePerGas

func effectiveGasPrice*(tx: Transaction, baseFeePerGas: GasInt): GasInt =
  if tx.txType < TxEip1559:
    tx.gasPrice
  else:
    baseFeePerGas +
      min(tx.maxPriorityFeePerGas, tx.maxFeePerGas - baseFeePerGas)

func effectiveGasTip*(tx: Transaction; baseFeePerGas: Opt[UInt256]): GasInt =
  let
    baseFeePerGas = baseFeePerGas.get(0.u256).truncate(GasInt)

  min(tx.maxPriorityFeePerGasNorm(), tx.maxFeePerGasNorm() - baseFeePerGas)

proc decodeTx*(bytes: openArray[byte]): Transaction =
  var rlp = rlpFromBytes(bytes)
  result = rlp.read(Transaction)
  if rlp.hasData:
    raise newException(RlpError, "rlp: input contains more than one value")

proc decodePooledTx*(bytes: openArray[byte]): PooledTransaction =
  var rlp = rlpFromBytes(bytes)
  result = rlp.read(PooledTransaction)
  if rlp.hasData:
    raise newException(RlpError, "rlp: input contains more than one value")
