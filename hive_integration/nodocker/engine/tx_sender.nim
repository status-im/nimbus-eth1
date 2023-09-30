import
  std/[tables, math],
  eth/keys,
  stew/endians2,
  nimcrypto/sha2,
  chronicles,
  ./engine_client,
  ../../../nimbus/transaction,
  ../../../nimbus/common

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

  TestAccount = object
    key    : PrivateKey
    address: EthAddress
    index  : int

  TxSender* = ref object
    accounts: seq[TestAccount]
    nonceMap: Table[EthAddress, uint64]
    txSent  : int
    chainId : ChainID

  MakeTxParams* = object
    chainId*: ChainID
    key*    : PrivateKey
    nonce*  : AccountNonce

const
  TestAccountCount = 1000

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

proc getNextAccount(sender: TxSender): TestAccount =
  sender.accounts[sender.txSent mod sender.accounts.len]

proc getNextNonce(sender: TxSender, address: EthAddress): uint64 =
  let nonce = sender.nonceMap.getOrDefault(address, 0'u64)
  sender.nonceMap[address] = nonce + 1
  nonce

proc fillBalance(sender: TxSender, params: NetworkParams) =
  for x in sender.accounts:
    params.genesis.alloc[x.address] = GenesisAccount(
      balance: UInt256.fromHex("0x123450000000000000000"),
    )

proc new*(_: type TxSender, params: NetworkParams): TxSender =
  result = TxSender(chainId: params.config.chainId)
  result.createAccounts()
  result.fillBalance(params)

func gwei(n: int64): GasInt {.compileTime.} =
  GasInt(n * (10 ^ 9))

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
    gasPrice = 30.gwei
    gasTipPrice = 1.gwei

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
               chainId : params.chainId
             )

  signTransaction(tx, params.key, params.chainId, eip155 = true)

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
    chainId: sender.chainId,
    key: acc.key,
    nonce: nonce
  )
  params.makeTx(tc)

proc makeTx*(sender: TxSender, tc: BigInitcodeTx, nonce: AccountNonce): Transaction =
  let acc = sender.getNextAccount()
  let params = MakeTxParams(
    chainId: sender.chainId,
    key: acc.key,
    nonce: nonce
  )
  params.makeTx(tc)

proc makeNextTx*(sender: TxSender, tc: BaseTx): Transaction =
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
    error "Unable to send transaction", msg=rr.error
    return false
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
    error "Unable to send transaction", msg=rr.error
    return false
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
  return true

proc sendTx*(client: RpcClient, tx: Transaction): bool =
  let rr = client.sendTransaction(tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false
  return true
