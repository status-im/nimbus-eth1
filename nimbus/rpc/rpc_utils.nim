# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import hexstrings, eth/[common, rlp], stew/byteutils,
  ../db/[db_chain], strutils, algorithm,
  ../constants, stint

func toAddress*(value: EthAddressStr): EthAddress = hexToPaddedByteArray[20](value.string)

func toHash*(value: array[32, byte]): Hash256 {.inline.} =
  result.data = value

func toHash*(value: EthHashStr): Hash256 {.inline.} =
  result = hexToPaddedByteArray[32](value.string).toHash

proc headerFromTag*(chain: BaseChainDB, blockTag: string): BlockHeader =
  let tag = blockTag.toLowerAscii
  case tag
  of "latest": result = chain.getCanonicalHead()
  of "earliest": result = chain.getBlockHeader(GENESIS_BLOCK_NUMBER)
  of "pending":
    #TODO: Implement get pending block
    raise newException(ValueError, "Pending tag not yet implemented")
  else:
    # Raises are trapped and wrapped in JSON when returned to the user.
    tag.validateHexQuantity
    let blockNum = stint.fromHex(UInt256, tag)
    result = chain.getBlockHeader(blockNum.toBlockNumber)

proc calculateMedianGasPrice*(chain: BaseChainDB): GasInt =
  var prices  = newSeqOfCap[GasInt](64)
  let header = chain.getCanonicalHead()
  for encodedTx in chain.getBlockTransactionData(header.txRoot):
    let tx = rlp.decode(encodedTx, Transaction)
    prices.add(tx.gasPrice)

  if prices.len > 0:
    sort(prices)
    let middle = prices.len div 2
    if prices.len mod 2 == 0:
      # prevent overflow
      let price = prices[middle].uint64 + prices[middle - 1].uint64
      result = (price div 2).GasInt
    else:
      result = prices[middle]
