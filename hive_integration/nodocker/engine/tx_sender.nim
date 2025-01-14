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
  std/[tables],
  eth/common/[keys, transaction_utils],
  stew/endians2,
  nimcrypto/sha2,
  chronicles,
  ./engine_client,
  ./cancun/blobs,
  ../../../nimbus/transaction,
  ../../../nimbus/common,
  ../../../nimbus/utils/utils

from std/sequtils import mapIt

type
  BaseTx* = object of RootObj
    recipient* : Opt[Address]
    gasLimit*  : GasInt
    amount*    : UInt256
    payload*   : seq[byte]
    txType*    : Opt[TxType]
    gasTip*    : GasInt
    gasFee*    : GasInt
    blobGasFee*: UInt256
    blobCount* : int
    blobID*    : BlobID
    authorizationList*: seq[Authorization]

  BigInitcodeTx* = object of BaseTx
    initcodeLength*: int
    padByte*       : uint8
    initcode*      : seq[byte]

  # Blob transaction creator
  BlobTx* = object of BaseTx

  TestAccount* = object
    key*    : PrivateKey
    address*: Address
    index*  : int

  TxSender* = ref object
    accounts: seq[TestAccount]
    nonceMap: Table[Address, uint64]
    txSent  : int
    chainId : ChainId

  MakeTxParams* = object
    chainId*: ChainId
    key*    : PrivateKey
    nonce*  : AccountNonce

  CustSig* = object
    V*: uint64
    R*: UInt256
    S*: UInt256

  CustomTransactionData* = object
    nonce*              : Opt[uint64]
    gasPriceOrGasFeeCap*: Opt[GasInt]
    gasTipCap*          : Opt[GasInt]
    gas*                : Opt[GasInt]
    blobGas*            : Opt[UInt256]
    to*                 : Opt[common.Address]
    value*              : Opt[UInt256]
    data*               : Opt[seq[byte]]
    chainId*            : Opt[ChainId]
    signature*          : Opt[CustSig]
    auth*               : Opt[Authorization]

const
  TestAccountCount = 1000
  gasPrice* = 30.gwei
  gasTipPrice* = 1.gwei
  blobGasPrice* = 1.gwei

func toAddress(key: PrivateKey): Address =
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

proc createAccounts(sender: TxSender, numAccounts: int) =
  for i in 0..<numAccounts:
    sender.accounts.add createAccount(i.int)

proc getNextAccount*(sender: TxSender): TestAccount =
  sender.accounts[sender.txSent mod sender.accounts.len]

proc getNextNonce(sender: TxSender, address: Address): uint64 =
  let nonce = sender.nonceMap.getOrDefault(address, 0'u64)
  sender.nonceMap[address] = nonce + 1
  nonce

proc getLastNonce(sender: TxSender, address: Address): uint64 =
  if sender.nonceMap.hasKey(address):
    return 0
  sender.nonceMap[address] - 1

proc fillBalance(sender: TxSender, params: NetworkParams) =
  const balance = UInt256.fromHex("0x123450000000000000000")
  for x in sender.accounts:
    params.genesis.alloc[x.address] = GenesisAccount(
      balance: balance,
    )

proc new*(_: type TxSender, params: NetworkParams, numAccounts = TestAccountCount): TxSender =
  result = TxSender(chainId: params.config.chainId)
  result.createAccounts(numAccounts)
  result.fillBalance(params)

proc getTxType(tc: BaseTx, nonce: uint64): TxType =
  if tc.txType.isNone:
    if nonce mod 2 == 0:
      TxLegacy
    else:
      TxEip1559
  else:
    tc.txType.get

proc makeTxOfType(params: MakeTxParams, tc: BaseTx): PooledTransaction =
  let
    gasFeeCap = if tc.gasFee != 0.GasInt: tc.gasFee
                else: gasPrice
    gasTipCap = if tc.gasTip != 0.GasInt: tc.gasTip
                else: gasTipPrice

  let txType = tc.getTxType(params.nonce)
  case txType
  of TxLegacy:
    PooledTransaction(
      tx: Transaction(
        txType  : TxLegacy,
        nonce   : params.nonce,
        to      : tc.recipient,
        value   : tc.amount,
        gasLimit: tc.gasLimit,
        gasPrice: gasPrice,
        payload : tc.payload,
        chainId : params.chainId,
      )
    )
  of TxEip1559:
    PooledTransaction(
      tx: Transaction(
        txType  : TxEip1559,
        nonce   : params.nonce,
        gasLimit: tc.gasLimit,
        maxFeePerGas: gasFeeCap,
        maxPriorityFeePerGas: gasTipCap,
        to      : tc.recipient,
        value   : tc.amount,
        payload : tc.payload,
        chainId : params.chainId
      )
    )
  of TxEip4844:
    doAssert(tc.recipient.isSome, "recipient must be some")
    let
      blobCount  = if tc.blobCount != 0: tc.blobCount
                   else: MAX_BLOBS_PER_BLOCK
      blobFeeCap = if tc.blobGasFee != 0.u256: tc.blobGasFee
                   else: blobGasPrice.u256

    # Need tx wrap data that will pass blob verification
    var blobData = blobDataGenerator(tc.blobID, blobCount)
    #tc.blobID += BlobID(blobCount)

    PooledTransaction(
      tx: Transaction(
        txType  : TxEip4844,
        nonce   : params.nonce,
        chainId : params.chainId,
        maxFeePerGas: gasFeeCap,
        maxPriorityFeePerGas: gasTipCap,
        gasLimit: tc.gasLimit,
        to      : tc.recipient,
        value   : tc.amount,
        payload : tc.payload,
        #AccessList: tc.AccessList,
        maxFeePerBlobGas: blobFeeCap,
        versionedHashes: system.move(blobData.hashes),
      ),
      networkPayload: NetworkPayload(
        blobs: blobData.blobs.mapIt(it.bytes),
        commitments: blobData.commitments.mapIt(KzgCommitment it.bytes),
        proofs: blobData.proofs.mapIt(KzgProof it.bytes),
      )
    )
  of TxEip7702:
    PooledTransaction(
      tx: Transaction(
        txType  : TxEip7702,
        nonce   : params.nonce,
        gasLimit: tc.gasLimit,
        maxFeePerGas: gasFeeCap,
        maxPriorityFeePerGas: gasTipCap,
        to      : tc.recipient,
        value   : tc.amount,
        payload : tc.payload,
        chainId : params.chainId,
        authorizationList: tc.authorizationList,
      )
    )
  else:
    raiseAssert "unsupported tx type"

proc makeTx(params: MakeTxParams, tc: BaseTx): PooledTransaction =
  # Build the transaction depending on the specified type
  let tx = makeTxOfType(params, tc)
  PooledTransaction(
    tx: signTransaction(tx.tx, params.key),
    networkPayload: tx.networkPayload)

proc makeTx(params: MakeTxParams, tc: BigInitcodeTx): PooledTransaction =
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

proc makeTx*(
    sender: TxSender, tc: BaseTx, nonce: AccountNonce): PooledTransaction =
  let acc = sender.getNextAccount()
  let params = MakeTxParams(
    chainId: sender.chainId,
    key: acc.key,
    nonce: nonce
  )
  params.makeTx(tc)

proc makeTx*(
    sender: TxSender,
    tc: BigInitcodeTx,
    nonce: AccountNonce): PooledTransaction =
  let acc = sender.getNextAccount()
  let params = MakeTxParams(
    chainId: sender.chainId,
    key: acc.key,
    nonce: nonce
  )
  params.makeTx(tc)

proc makeNextTx*(sender: TxSender, tc: BaseTx): PooledTransaction =
  let
    acc = sender.getNextAccount()
    nonce = sender.getNextNonce(acc.address)
    params = MakeTxParams(
      chainId: sender.chainId,
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
      chainId: sender.chainId,
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
      chainId: sender.chainId,
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

proc sendTx*(client: RpcClient, tx: PooledTransaction): bool =
  let rr = client.sendTransaction(tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false
  return true

proc makeTx*(params: MakeTxParams, tc: BlobTx): PooledTransaction =
  # Need tx wrap data that will pass blob verification
  let data = blobDataGenerator(tc.blobID, tc.blobCount)
  doAssert(tc.recipient.isSome, "nil recipient address")

  let
    gasFeeCap = if tc.gasFee != 0.GasInt: tc.gasFee
                else: gasPrice
    gasTipCap = if tc.gasTip != 0.GasInt: tc.gasTip
                else: gasTipPrice

  # Collect fields for transaction
  let unsignedTx = Transaction(
    txType    : TxEip4844,
    chainId   : params.chainId,
    nonce     : params.nonce,
    maxPriorityFeePerGas: gasTipCap,
    maxFeePerGas: gasFeeCap,
    gasLimit  : tc.gasLimit,
    to        : tc.recipient,
    value     : tc.amount,
    payload   : tc.payload,
    maxFeePerBlobGas: tc.blobGasFee,
    versionedHashes: data.hashes,
  )

  PooledTransaction(
    tx: signTransaction(unsignedTx, params.key),
    networkPayload: NetworkPayload(
      blobs      : data.blobs.mapIt(it.bytes),
      commitments: data.commitments.mapIt(KzgCommitment it.bytes),
      proofs     : data.proofs.mapIt(KzgProof it.bytes),
    ),
  )

proc getAccount*(sender: TxSender, idx: int): TestAccount =
  sender.accounts[idx]

proc sendTx*(
    sender: TxSender,
    acc: TestAccount,
    client: RpcClient,
    tc: BlobTx): Result[PooledTransaction, void] =
  let
    params = MakeTxParams(
      chainId: sender.chainId,
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

proc replaceTx*(
    sender: TxSender,
    acc: TestAccount,
    client: RpcClient,
    tc: BlobTx): Result[PooledTransaction, void] =
  let
    params = MakeTxParams(
      chainId: sender.chainId,
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

proc makeTx*(
    sender: TxSender,
    tc: BaseTx,
    acc: TestAccount,
    nonce: AccountNonce): PooledTransaction =
  let
    params = MakeTxParams(
      chainId: sender.chainId,
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

  if custTx.chainId.isSome:
    modTx.chainId = custTx.chainId.get

  if baseTx.txType in {TxEip1559, TxEip4844, TxEip7702}:
    if custTx.gasPriceOrGasFeeCap.isSome:
      modTx.maxFeePerGas = custTx.gasPriceOrGasFeeCap.get.GasInt

    if custTx.gasTipCap.isSome:
      modTx.maxPriorityFeePerGas = custTx.gasTipCap.get.GasInt

  if baseTx.txType == TxEip4844:
    if modTx.to.isNone:
      var address: Address
      modTx.to = Opt.some(address)

  if custTx.blobGas.isSome:
    doAssert(baseTx.txType == TxEip4844)
    modTx.maxFeePerBlobGas = custTx.blobGas.get

  if custTx.auth.isSome:
    doAssert(baseTx.txType == TxEip7702)
    doAssert(baseTx.authorizationList.len > 0)
    modTx.authorizationList[0] = custTx.auth.get

  if custTx.signature.isSome:
    let signature = custTx.signature.get
    modTx.V = signature.V
    modTx.R = signature.R
    modTx.S = signature.S
  else:
    modTx.signature = modTx.sign(acc.key, eip155 = true)

  modTx

proc makeAuth*(sender: TxSender, acc: TestAccount, nonce: AccountNonce): Authorization =
  var auth = Authorization(
    chainId: sender.chainId,
    address: acc.address,
    nonce: nonce,
  )
  let hash = auth.rlpHashForSigning()
  let sig  = sign(acc.key, SkMessage(hash.data))
  let raw  = sig.toRaw()

  auth.r = UInt256.fromBytesBE(raw.toOpenArray(0, 31))
  auth.s = UInt256.fromBytesBE(raw.toOpenArray(32, 63))
  auth.v = raw[64].uint64
