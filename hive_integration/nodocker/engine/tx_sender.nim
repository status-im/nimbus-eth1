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
  eth/[common/transaction, keys],
  stew/endians2,
  stint,
  nimcrypto/sha2,
  chronicles,
  ./engine_client,
  ./cancun/blobs,
  ../../../nimbus/transaction,
  ../../../nimbus/common,
  ../../../nimbus/utils/utils

type
  BaseTx* = object of RootObj
    recipient* : Option[EthAddress]
    gasLimit*  : GasInt
    amount*    : UInt256
    payload*   : seq[byte]
    txType*    : Option[TxType]
    gasTip*    : GasInt
    gasFee*    : GasInt
    blobGasFee*: UInt256
    blobCount* : int
    blobID*    : BlobID

  BigInitcodeTx* = object of BaseTx
    initcodeLength*: int
    padByte*       : uint8
    initcode*      : seq[byte]

  # Blob transaction creator
  BlobTx* = object of BaseTx

  TestAccount* = object
    key*    : PrivateKey
    address*: EthAddress
    index*  : int

  TxSender* = ref object
    accounts: seq[TestAccount]
    nonceMap: Table[EthAddress, uint64]
    txSent  : int
    chainId*: ChainID

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
  blobGasPrice* = 1.gwei

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
  if sender.nonceMap.hasKey(address):
    return 0
  sender.nonceMap[address] - 1

proc fillBalance(sender: TxSender, params: NetworkParams) =
  for x in sender.accounts:
    params.genesis.alloc[x.address] = GenesisAccount(
      balance: UInt256.fromHex("0x123450000000000000000"),
    )

proc new*(_: type TxSender, params: NetworkParams): TxSender =
  result = TxSender(chainId: params.config.chainId)
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
        payload: TransactionPayload(
          nonce: params.nonce,
          to:
            if tc.recipient.isSome:
              Opt.some(tc.recipient.get)
            else:
              Opt.none(EthAddress),
          value: tc.amount,
          gas: tc.gasLimit.uint64,
          max_fee_per_gas: gasPrice.uint64.u256,
          input: List[byte, Limit MAX_CALLDATA_SIZE].init tc.payload)))

  of TxEip1559:
    PooledTransaction(
      tx: Transaction(
        payload: TransactionPayload(
          tx_type: Opt.some TxEip1559,
          nonce: params.nonce,
          gas: tc.gasLimit.uint64,
          max_fee_per_gas: gasPrice.uint64.u256,
          max_priority_fee_per_gas: Opt.some(gasTipCap.uint64.u256),
          to:
            if tc.recipient.isSome:
              Opt.some(tc.recipient.get)
            else:
              Opt.none(EthAddress),
          value: tc.amount,
          input: List[byte, Limit MAX_CALLDATA_SIZE].init tc.payload)))
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
        payload: TransactionPayload(
          tx_type: Opt.some TxEip4844,
          nonce: params.nonce,
          max_fee_per_gas: gasPrice.uint64.u256,
          max_priority_fee_per_gas: Opt.some(gasTipCap.uint64.u256),
          gas: tc.gasLimit.uint64,
          to:
            if tc.recipient.isSome:
              Opt.some(tc.recipient.get)
            else:
              Opt.none(EthAddress),
          value: tc.amount,
          input: List[byte, Limit MAX_CALLDATA_SIZE].init tc.payload,
          max_fee_per_blob_gas: Opt.some(blobFeeCap),
          blob_versioned_hashes: Opt.some(
            List[eth_types.VersionedHash, Limit MAX_BLOB_COMMITMENTS_PER_BLOCK]
              .init(system.move(blobData.hashes))))),
      blob_data: Opt.some NetworkPayload(
        blobs:
          List[NetworkBlob, MAX_BLOB_COMMITMENTS_PER_BLOCK]
            .init(system.move(blobData.blobs)),
        commitments:
          List[eth_types.KzgCommitment, MAX_BLOB_COMMITMENTS_PER_BLOCK]
            .init(system.move(blobData.commitments)),
        proofs:
          List[eth_types.KzgProof, MAX_BLOB_COMMITMENTS_PER_BLOCK]
            .init(system.move(blobData.proofs)),
      )
    )
  else:
    raiseAssert "unsupported tx type"

proc makeTx(params: MakeTxParams, tc: BaseTx): PooledTransaction =
  # Build the transaction depending on the specified type
  let tx = makeTxOfType(params, tc)
  PooledTransaction(
    tx: signTransaction(tx.tx.payload, params.key, params.chainId),
    blob_data: tx.blob_data)

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
  let rr = client.sendTransaction(tx, sender.chainId)
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

  let rr = client.sendTransaction(tx, sender.chainId)
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

  let rr = client.sendTransaction(tx, sender.chainId)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false

  inc sender.txSent
  return true

proc sendTx*(client: RpcClient, tx: PooledTransaction, chainId: ChainId): bool =
  let rr = client.sendTransaction(tx, chainId)
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
  let unsignedTx = TransactionPayload(
    tx_type: Opt.some TxEip4844,
    nonce: params.nonce,
    max_priority_fee_per_gas: Opt.some(gasTipCap.uint64.u256),
    max_fee_per_gas: gasFeeCap.uint64.u256,
    gas: tc.gasLimit.uint64,
    to:
      if tc.recipient.isSome:
        Opt.some(tc.recipient.get)
      else:
        Opt.none(EthAddress),
    value: tc.amount,
    input: List[byte, Limit MAX_CALLDATA_SIZE].init tc.payload,
    max_fee_per_blob_gas: Opt.some(tc.blobGasFee),
    blob_versioned_hashes: Opt.some(
      List[eth_types.VersionedHash, Limit MAX_BLOB_COMMITMENTS_PER_BLOCK]
        .init(data.hashes)))
  PooledTransaction(
    tx: signTransaction(unsignedTx, params.key, params.chainId),
    blob_data: Opt.some NetworkPayload(
      blobs:
        List[NetworkBlob, MAX_BLOB_COMMITMENTS_PER_BLOCK]
          .init(data.blobs),
      commitments:
        List[eth_types.KzgCommitment, MAX_BLOB_COMMITMENTS_PER_BLOCK]
          .init(data.commitments),
      proofs:
        List[eth_types.KzgProof, MAX_BLOB_COMMITMENTS_PER_BLOCK]
          .init(data.proofs),
    )
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

  let rr = client.sendTransaction(tx, params.chainId)
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

  let rr = client.sendTransaction(tx, params.chainId)
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
                           custTx: CustomTransactionData,
                           chainId: ChainId): Transaction =
  # Create a modified transaction base, from the base transaction and custTx mix
  var modTx = baseTx
  if custTx.nonce.isSome:
    modTx.payload.nonce = custTx.nonce.get.AccountNonce

  if custTx.gasPriceOrGasFeeCap.isSome:
    modTx.payload.max_fee_per_gas = custTx.gasPriceOrGasFeeCap.get.u256

  if custTx.gas.isSome:
    modTx.payload.gas = custTx.gas.get.uint64

  if custTx.to.isSome:
    modTx.payload.to.ok custTx.to.get

  if custTx.value.isSome:
    modTx.payload.value = custTx.value.get

  if custTx.data.isSome:
    modTx.payload.input =
      List[byte, Limit MAX_CALLDATA_SIZE].init(custTx.data.get)

  let custChainId =
    if custTx.chainId.isSome:
      custTx.chainId.get
    else:
      chainId

  if baseTx.payload.tx_type.get(TxLegacy) in {TxEip1559, TxEip4844}:
    if custTx.gasPriceOrGasFeeCap.isSome:
      modTx.payload.max_fee_per_gas = custTx.gasPriceOrGasFeeCap.get.u256

    if custTx.gasTipCap.isSome:
      modTx.payload.max_priority_fee_per_gas.ok custTx.gasTipCap.get.u256

  if baseTx.payload.tx_type.get(TxLegacy) == TxEip4844:
    if modTx.payload.to.isNone:
      var address: EthAddress
      modTx.payload.to.ok(address)

  if custTx.signature.isSome:
    let
      signature = custTx.signature.get
      v = signature.V.u256
      r = signature.R
      s = signature.S
      anyTx = AnyTransactionPayload.fromOneOfBase(modTx.payload).valueOr:
        raise (ref ValueError)(msg: "Invalid combination of fields")
    return withTxPayloadVariant(anyTx):
      let y_parity =
        when txKind == TransactionKind.Replayable:
          if v == 27.u256:
            false
          elif v == 28.u256:
            true
          else:
            raise (ref ValueError)(msg: "Invalid `v`")
        elif txKind == TransactionKind.Legacy:
          let
            res = v.isEven
            expected_v =
              distinctBase(custChainId).u256 * 2 +
              (if res: 36.u256 else: 35.u256)
          if v != expected_v:
            raise (ref ValueError)(msg: "Invalid `v`")
          res
        else:
          if v > UInt256.one:
            raise (ref ValueError)(msg: "Invalid `v`")
          v.isOdd
      var signature: TransactionSignature
      signature.ecdsa_signature = ecdsa_pack_signature(y_parity, r, s)
      signature.from_address = ecdsa_recover_from_address(
          signature.ecdsa_signature,
          txPayloadVariant.compute_sig_hash(custChainId)).valueOr:
        raise (ref ValueError)(msg: "Cannot compute `from` address")
      Transaction(payload: modTx.payload, signature: signature)

  if custTx.signature.isNone:
    return signTransaction(modTx.payload, acc.key, custChainId)

  return modTx
