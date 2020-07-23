# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import hexstrings, eth/[common, rlp, keys], stew/byteutils, nimcrypto,
  ../db/[db_chain], strutils, algorithm, options,
  ../constants, stint, hexstrings, rpc_types

type
  UnsignedTx* = object
    nonce   : AccountNonce
    gasPrice: GasInt
    gasLimit: GasInt
    to {.rlpCustomSerialization.}: EthAddress
    value   : UInt256
    payload : Blob
    contractCreation {.rlpIgnore.}: bool

proc read(rlp: var Rlp, t: var UnsignedTx, _: type EthAddress): EthAddress {.inline.} =
  if rlp.blobLen != 0:
    result = rlp.read(EthAddress)
  else:
    t.contractCreation = true

proc append(rlpWriter: var RlpWriter, t: UnsignedTx, a: EthAddress) {.inline.} =
  if t.contractCreation:
    rlpWriter.append("")
  else:
    rlpWriter.append(a)

func toAddress*(value: EthAddressStr): EthAddress = hexToPaddedByteArray[20](value.string)

func toHash*(value: array[32, byte]): Hash256 {.inline.} =
  result.data = value

func toHash*(value: EthHashStr): Hash256 {.inline.} =
  result = hexToPaddedByteArray[32](value.string).toHash

func hexToInt*(s: string, T: typedesc[SomeInteger]): T =
  var i = 0
  if s[i] == '0' and (s[i+1] in {'x', 'X'}): inc(i, 2)
  if s.len - i > sizeof(T) * 2:
    raise newException(ValueError, "input hex too big for destination int")
  while i < s.len:
    result = result shl 4 or readHexChar(s[i]).T
    inc(i)

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

proc unsignedTx*(tx: TxSend, chain: BaseChainDB, defaultNonce: AccountNonce): UnsignedTx =
  if tx.to.isSome:
    result.to = toAddress(tx.to.get())
    result.contractCreation = false
  else:
    result.contractCreation = true

  if tx.gas.isSome:
    result.gasLimit = hexToInt(tx.gas.get().string, GasInt)
  else:
    result.gasLimit = 90000.GasInt

  if tx.gasPrice.isSome:
    result.gasPrice = hexToInt(tx.gasPrice.get().string, GasInt)
  else:
    result.gasPrice = calculateMedianGasPrice(chain)

  if tx.value.isSome:
    result.value = UInt256.fromHex(tx.value.get().string)
  else:
    result.value = 0.u256

  if tx.nonce.isSome:
    result.nonce = hexToInt(tx.nonce.get().string, AccountNonce)
  else:
    result.nonce = defaultNonce

  result.payload = hexToSeqByte(tx.data.string)

func rlpEncode(tx: UnsignedTx, chainId: uint): auto =
  rlp.encode(Transaction(
    accountNonce: tx.nonce,
    gasPrice: tx.gasPrice,
    gasLimit: tx.gasLimit,
    to: tx.to,
    value: tx.value,
    payload: tx.payload,
    isContractCreation: tx.contractCreation,
    V: chainId.byte,
    R: 0.u256,
    S: 0.u256
    ))

proc signTransaction*(tx: UnsignedTx, chain: BaseChainDB, privateKey: PrivateKey): Transaction =
  let eip155 = chain.currentBlock >= chain.config.eip155Block
  let rlpTx = if eip155:
                rlpEncode(tx, chain.config.chainId)
              else:
                rlp.encode(tx)

  let sig = sign(privateKey, rlpTx).toRaw
  let v = if eip155:
            byte(sig[64].uint + chain.config.chainId * 2'u + 35'u)
          else:
            sig[64] + 27.byte

  result = Transaction(
    accountNonce: tx.nonce,
    gasPrice: tx.gasPrice,
    gasLimit: tx.gasLimit,
    to: tx.to,
    value: tx.value,
    payload: tx.payload,
    isContractCreation: tx.contractCreation,
    V: v,
    R: Uint256.fromBytesBE(sig[0..31]),
    S: Uint256.fromBytesBE(sig[32..63])
    )
