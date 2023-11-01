# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[tables],
  eth/keys,
  stew/endians2,
  nimcrypto/sha2,
  chronicles,
  ./engine_client,
  ./cancun/blobs,
  ../../../nimbus/transaction,
  ../../../nimbus/common,
  ../../../nimbus/utils/utils

type
  BaseTx* = object of RootObj
    recipient*: Option[EthAddress]
    gasLimit* : GasInt
    amount*   : UInt256
    payload*  : seq[byte]
    txType*   : Option[TxType]

  BigInitcodeTx* = object of BaseTx
    initcodeLength*: int
    padByte*       : uint8
    initcode*      : seq[byte]

  # Blob transaction creator
  BlobTx* = object of BaseTx
    gasFee*    : GasInt
    gasTip*    : GasInt
    blobGasFee*: UInt256
    blobID*    : BlobID
    blobCount* : int

  TestAccount* = object
    key*    : PrivateKey
    address*: EthAddress
    index*  : int

  TxSender* = ref object
    accounts: seq[TestAccount]
    nonceMap: Table[EthAddress, uint64]
    txSent  : int
    chainId : ChainID

  MakeTxParams* = object
    chainId*: ChainID
    key*    : PrivateKey
    nonce*  : AccountNonce

  CustSig* = object
    V*: int64
    R*: UInt256
    S*: UInt256

  CustomTransactionData* = object
    nonce*              : Option[uint64]
    gasPriceOrGasFeeCap*: Option[GasInt]
    gasTipCap*          : Option[GasInt]
    gas*                : Option[GasInt]
    to*                 : Option[common.EthAddress]
    value*              : Option[UInt256]
    data*               : Option[seq[byte]]
    chainId*            : Option[ChainId]
    signature*          : Option[CustSig]

const
  TestAccountCount = 1000
  gasPrice* = 30.gwei
  gasTipPrice* = 1.gwei

func toAddress(key: PrivateKey): EthAddress =
  toKeyPair(key).pubkey.toCanonicalAddress()

proc createAccount(idx: int): TestAccount =
  let
    seed = toBytesBE(idx.uint64)
    seedHash = sha256.digest(seed)

  result.index = idx
  result.key = PrivateKey.fromRaw(seedHash.data).valueOr:
    echo error
    quit(QuitFailure)
  result.address = toAddress(result.key)

proc createAccounts(sender: TxSender) =
  for i in 0..<TestAccountCount:
    sender.accounts.add createAccount(i.int)

proc getNextAccount*(sender: TxSender): TestAccount =
  sender.accounts[sender.txSent mod sender.accounts.len]

proc getNextNonce(sender: TxSender, address: EthAddress): uint64 =
  let nonce = sender.nonceMap.getOrDefault(address, 0'u64)
  sender.nonceMap[address] = nonce + 1
  nonce

proc getLastNonce(sender: TxSender, address: EthAddress): uint64 =
  sender.nonceMap.getOrDefault(address, 0'u64)

proc fillBalance(sender: TxSender, params: NetworkParams) =
  for x in sender.accounts:
    params.genesis.alloc[x.address] = GenesisAccount(
      balance: UInt256.fromHex("0x123450000000000000000"),
    )

proc new*(_: type TxSender, params: NetworkParams): TxSender =
  result = TxSender(chainId: params.config.chainID)
  result.createAccounts()
  result.fillBalance(params)

proc getTxType(tc: BaseTx, nonce: uint64): TxType =
  if tc.txType.isNone:
    if nonce mod 2 == 0:
      TxLegacy
    else:
      TxEIP1559
  else:
    tc.txType.get

proc makeTx(params: MakeTxParams, tc: BaseTx): Transaction =
  const
    gasFeeCap = gasPrice
    gasTipCap = gasTipPrice

  let txType = tc.getTxType(params.nonce)

  # Build the transaction depending on the specified type
  let tx = if txType == TxLegacy:
             Transaction(
               txType  : TxLegacy,
               nonce   : params.nonce,
               to      : tc.recipient,
               value   : tc.amount,
               gasLimit: tc.gasLimit,
               gasPrice: gasPrice,
               payload : tc.payload
             )
           else:
             Transaction(
               txType  : TxEIP1559,
               nonce   : params.nonce,
               gasLimit: tc.gasLimit,
               maxFee  : gasFeeCap,
               maxPriorityFee: gasTipCap,
               to      : tc.recipient,
               value   : tc.amount,
               payload : tc.payload,
               chainId : params.chainID
             )

  signTransaction(tx, params.key, params.chainID, eip155 = true)

proc makeTx(params: MakeTxParams, tc: BigInitcodeTx): Transaction =
  var tx = tc
  if tx.payload.len == 0:
    # Prepare initcode payload
    if tx.initcode.len != 0:
      doAssert(tx.initcode.len <= tx.initcodeLength, "invalid initcode (too big)")
      tx.payload = tx.initcode

    while tx.payload.len < tx.initcodeLength:
      tx.payload.add tx.padByte

  doAssert(tx.recipient.isNone, "invalid configuration for big contract tx creator")
  params.makeTx(tx.BaseTx)

proc makeTx*(sender: TxSender, tc: BaseTx, nonce: AccountNonce): Transaction =
  let acc = sender.getNextAccount()
  let params = MakeTxParams(
    chainId: sender.chainID,
    key: acc.key,
    nonce: nonce
  )
  params.makeTx(tc)

proc makeTx*(sender: TxSender, tc: BigInitcodeTx, nonce: AccountNonce): Transaction =
  let acc = sender.getNextAccount()
  let params = MakeTxParams(
    chainId: sender.chainID,
    key: acc.key,
    nonce: nonce
  )
  params.makeTx(tc)

proc makeNextTx*(sender: TxSender, tc: BaseTx): Transaction =
  let
    acc = sender.getNextAccount()
    nonce = sender.getNextNonce(acc.address)
    params = MakeTxParams(
      chainId: sender.chainID,
      key: acc.key,
      nonce: nonce
    )
  params.makeTx(tc)

proc sendNextTx*(sender: TxSender, client: RpcClient, tc: BaseTx): bool =
  let tx = sender.makeNextTx(tc)
  let rr = client.sendTransaction(tx)
  if rr.isErr:
    error "sendNextTx: Unable to send transaction", msg=rr.error
    return false

  inc sender.txSent
  return true

proc sendTx*(sender: TxSender, client: RpcClient, tc: BaseTx, nonce: AccountNonce): bool =
  let
    acc = sender.getNextAccount()
    params = MakeTxParams(
      chainId: sender.chainID,
      key: acc.key,
      nonce: nonce
    )
    tx = params.makeTx(tc)

  let rr = client.sendTransaction(tx)
  if rr.isErr:
    error "sendTx: Unable to send transaction", msg=rr.error
    return false

  inc sender.txSent
  return true

proc sendTx*(sender: TxSender, client: RpcClient, tc: BigInitcodeTx, nonce: AccountNonce): bool =
  let
    acc = sender.getNextAccount()
    params = MakeTxParams(
      chainId: sender.chainID,
      key: acc.key,
      nonce: nonce
    )
    tx = params.makeTx(tc)

  let rr = client.sendTransaction(tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false

  inc sender.txSent
  return true

proc sendTx*(client: RpcClient, tx: Transaction): bool =
  let rr = client.sendTransaction(tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false
  return true

proc makeTx*(params: MakeTxParams, tc: BlobTx): Transaction =
  # Need tx wrap data that will pass blob verification
  let data = blobDataGenerator(tc.blobID, tc.blobCount)
  doAssert(tc.recipient.isSome, "nil recipient address")

  # Collect fields for transaction
  let
    gasFeeCap = if tc.gasFee != 0.GasInt: tc.gasFee
                else: gasPrice
    gasTipCap = if tc.gasTip != 0.GasInt: tc.gasTip
                else: gasTipPrice

  let unsignedTx = Transaction(
    txType    : TxEip4844,
    chainId   : params.chainID,
    nonce     : params.nonce,
    maxPriorityFee: gasTipCap,
    maxFee    : gasFeeCap,
    gasLimit  : tc.gasLimit,
    to        : tc.recipient,
    value     : tc.amount,
    payload   : tc.payload,
    maxFeePerBlobGas: tc.blobGasFee,
    versionedHashes: data.hashes,
  )

  var tx = signTransaction(unsignedTx, params.key, params.chainID, eip155 = true)
  tx.networkPayload = NetworkPayload(
    blobs      : data.blobs,
    commitments: data.commitments,
    proofs     : data.proofs,
  )

  tx

proc getAccount*(sender: TxSender, idx: int): TestAccount =
  sender.accounts[idx]

proc sendTx*(sender: TxSender, acc: TestAccount, client: RpcClient, tc: BlobTx): Result[Transaction, void] =
  let
    params = MakeTxParams(
      chainId: sender.chainID,
      key: acc.key,
      nonce: sender.getNextNonce(acc.address),
    )
    tx = params.makeTx(tc)

  let rr = client.sendTransaction(tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return err()

  inc sender.txSent
  return ok(tx)

proc replaceTx*(sender: TxSender, acc: TestAccount, client: RpcClient, tc: BlobTx): Result[Transaction, void] =
  let
    params = MakeTxParams(
      chainId: sender.chainID,
      key: acc.key,
      nonce: sender.getLastNonce(acc.address),
    )
    tx = params.makeTx(tc)

  let rr = client.sendTransaction(tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return err()

  inc sender.txSent
  return ok(tx)

proc makeTx*(sender: TxSender, tc: BaseTx, acc: TestAccount, nonce: AccountNonce): Transaction =
  let
    params = MakeTxParams(
      chainId: sender.chainID,
      key: acc.key,
      nonce: nonce,
    )
  params.makeTx(tc)

proc customizeTransaction*(sender: TxSender,
                           acc: TestAccount,
                           baseTx: Transaction,
                           custTx: CustomTransactionData): Transaction =
  # Create a modified transaction base, from the base transaction and custTx mix
  var modTx = baseTx
  if custTx.nonce.isSome:
    modTx.nonce = custTx.nonce.get.AccountNonce

  if custTx.gasPriceOrGasFeeCap.isSome:
    modTx.gasPrice = custTx.gasPriceOrGasFeeCap.get.GasInt

  if custTx.gas.isSome:
    modTx.gasLimit = custTx.gas.get.GasInt

  if custTx.to.isSome:
    modTx.to = custTx.to

  if custTx.value.isSome:
    modTx.value = custTx.value.get

  if custTx.data.isSome:
    modTx.payload = custTx.data.get

  if custTx.signature.isSome:
    let signature = custTx.signature.get
    modTx.V = signature.V
    modTx.R = signature.R
    modTx.S = signature.S

  if baseTx.txType in {TxEip1559, TxEip4844}:
    if custTx.chainID.isSome:
      modTx.chainID = custTx.chainID.get

    if custTx.gasPriceOrGasFeeCap.isSome:
      modTx.maxFee = custTx.gasPriceOrGasFeeCap.get.GasInt

    if custTx.gasTipCap.isSome:
      modTx.maxPriorityFee = custTx.gasTipCap.get.GasInt

  if baseTx.txType == TxEip4844:
    if modTx.to.isNone:
      var address: EthAddress
      modTx.to = some(address)

  if custTx.signature.isNone:
    return signTransaction(modTx, acc.key, modTx.chainID, eip155 = true)

  return modTx
