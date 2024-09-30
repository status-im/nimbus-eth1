# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  stew/byteutils,
  unittest2,
  eth/[common, keys],
  ../nimbus/transaction

const
  recipient = address"095e7baea6a6c7c4c2dfeb977efac326af552d87"
  source    = address"0x0000000000000000000000000000000000000001"
  storageKey= default(StorageKey)
  accesses  = @[AccessPair(address: source, storageKeys: @[storageKey])]
  abcdef    = hexToSeqByte("abcdef")
  hexKey    = "af1a9be9f1a54421cac82943820a0fe0f601bb5f4f6d0bccc81c613f0ce6ae22"
  senderTop = address"73cf19657412508833f618a15e8251306b3e6ee5"

proc tx0(i: int): Transaction =
  Transaction(
    txType:   TxLegacy,
    nonce:    i.AccountNonce,
    to:       Opt.some recipient,
    gasLimit: 1.GasInt,
    gasPrice: 2.GasInt,
    payload:  abcdef)

proc tx1(i: int): Transaction =
  Transaction(
    # Legacy tx contract creation.
    txType:   TxLegacy,
    nonce:    i.AccountNonce,
    gasLimit: 1.GasInt,
    gasPrice: 2.GasInt,
    payload:  abcdef)

proc tx2(i: int): Transaction =
  Transaction(
    # Tx with non-zero access list.
    txType:     TxEip2930,
    chainId:    1.ChainId,
    nonce:      i.AccountNonce,
    to:         Opt.some recipient,
    gasLimit:   123457.GasInt,
    gasPrice:   10.GasInt,
    accessList: accesses,
    payload:    abcdef)

proc tx3(i: int): Transaction =
  Transaction(
    # Tx with empty access list.
    txType:   TxEip2930,
    chainId:  1.ChainId,
    nonce:    i.AccountNonce,
    to:       Opt.some recipient,
    gasLimit: 123457.GasInt,
    gasPrice: 10.GasInt,
    payload:  abcdef)

proc tx4(i: int): Transaction =
  Transaction(
    # Contract creation with access list.
    txType:     TxEip2930,
    chainId:    1.ChainId,
    nonce:      i.AccountNonce,
    gasLimit:   123457.GasInt,
    gasPrice:   10.GasInt,
    accessList: accesses)

proc tx5(i: int): Transaction =
  Transaction(
    txType:     TxEip1559,
    chainId:    1.ChainId,
    nonce:      i.AccountNonce,
    gasLimit:   123457.GasInt,
    maxPriorityFeePerGas: 42.GasInt,
    maxFeePerGas: 10.GasInt,
    accessList: accesses)

proc tx6(i: int): Transaction =
  const
    digest = bytes32"010657f37554c781402a22917dee2f75def7ab966d7b770905398eba3c444014"

  Transaction(
    txType:              TxEip4844,
    chainId:             1.ChainId,
    nonce:               i.AccountNonce,
    gasLimit:            123457.GasInt,
    maxPriorityFeePerGas:42.GasInt,
    maxFeePerGas:        10.GasInt,
    accessList:          accesses,
    versionedHashes:     @[digest]
  )

proc tx7(i: int): Transaction =
  const
    digest = bytes32"01624652859a6e98ffc1608e2af0147ca4e86e1ce27672d8d3f3c9d4ffd6ef7e"

  Transaction(
    txType:              TxEip4844,
    chainID:             1.ChainId,
    nonce:               i.AccountNonce,
    gasLimit:            123457.GasInt,
    maxPriorityFeePerGas:42.GasInt,
    maxFeePerGas:        10.GasInt,
    accessList:          accesses,
    versionedHashes:     @[digest],
    maxFeePerBlobGas:    10000000.u256,
  )

proc tx8(i: int): Transaction =
  const
    digest = bytes32"01624652859a6e98ffc1608e2af0147ca4e86e1ce27672d8d3f3c9d4ffd6ef7e"

  Transaction(
    txType:              TxEip4844,
    chainID:             1.ChainId,
    nonce:               i.AccountNonce,
    to:                  Opt.some recipient,
    gasLimit:            123457.GasInt,
    maxPriorityFeePerGas:42.GasInt,
    maxFeePerGas:        10.GasInt,
    accessList:          accesses,
    versionedHashes:     @[digest],
    maxFeePerBlobGas:    10000000.u256,
  )

proc privKey(keyHex: string): PrivateKey =
  let kRes = PrivateKey.fromHex(keyHex)
  if kRes.isErr:
    echo kRes.error
    quit(QuitFailure)

  kRes.get()

proc eip4844Main*() =
  var signerKey = privKey(hexKey)

  suite "EIP4844 sign transaction":
    let txs = @[tx0(3), tx1(3), tx2(3), tx3(3), tx4(3),
                tx5(3), tx6(3), tx7(3), tx8(3)]

    test "sign transaction":
      for tx in txs:
        let signedTx = signTransaction(tx, signerKey, 1.ChainId, true)
        let sender = signedTx.getSender()
        check sender == senderTop

when isMainModule:
  eip4844Main()
