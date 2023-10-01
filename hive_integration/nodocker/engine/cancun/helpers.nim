import
  std/[tables, strutils, typetraits],
  stint,
  eth/[common, rlp],
  eth/common/eth_types_rlp,
  chronicles,
  stew/[results, byteutils],
  kzg4844/kzg_ex as kzg,
  ../types,
  ../engine_client,
  ../../../../nimbus/constants,
  ../../../../nimbus/core/eip4844,
  ../../../../nimbus/rpc/rpc_types,
  ../../../../nimbus/beacon/execution_types,
  ../../../../nimbus/beacon/web3_eth_conv,
  ./blobs

type
  TestBlobTxPool* = ref object
    currentBlobID* : BlobID
    currentTxIndex*: int
    transactions*  : Table[common.Hash256, Transaction]
    hashesByIndex* : Table[int, common.Hash256]

const
  HISTORY_BUFFER_LENGTH* = 8191

  # Test constants
  DATAHASH_START_ADDRESS* = toAddress(0x20000.u256)
  DATAHASH_ADDRESS_COUNT* = 1000

func getMinExcessBlobGasForBlobGasPrice(data_gas_price: uint64): uint64 =
  var
    current_excess_data_gas = 0'u64
    current_data_gas_price  = 1'u64

  while current_data_gas_price < data_gas_price:
    current_excess_data_gas += GAS_PER_BLOB.uint64
    current_data_gas_price = getBlobGasPrice(current_excess_data_gas).truncate(uint64)

  return current_excess_data_gas

func getMinExcessBlobsForBlobGasPrice*(data_gas_price: uint64): uint64 =
  return getMinExcessBlobGasForBlobGasPrice(data_gas_price) div GAS_PER_BLOB.uint64

proc addBlobTransaction*(pool: TestBlobTxPool, tx: Transaction) =
  let txHash = rlpHash(tx)
  pool.transactions[txHash] = tx

proc `==`(a: openArray[rpc_types.AccessTuple], b: openArray[AccessPair]): bool =
  if a.len != b.len:
    return false

  for i in 0..<a.len:
    if a[i].address != b[i].address:
      return false
    if a[i].storageKeys.len != b[i].storageKeys.len:
      return false
    for j in 0..<a[i].storageKeys.len:
      if a[i].storageKeys[j].data != b[i].storageKeys[j]:
        return false

  return true

# Test two different transactions with the same blob, and check the blob bundle.
proc verifyTransactionFromNode*(client: RpcClient, tx: Transaction): Result[void, string] =
  let txHash = tx.rlpHash
  let res = client.txByHash(txHash)
  if res.isErr:
    return err(res.error)
  let returnedTx = res.get()

  # Verify that the tx fields are all the same
  if returnedTx.nonce != tx.nonce:
    return err("nonce mismatch: $1 != $2" % [$returnedTx.nonce, $tx.nonce])

  if returnedTx.gasLimit != tx.gasLimit:
    return err("gas mismatch: $1 != $2" % [$returnedTx.gasLimit, $tx.gasLimit])

  if returnedTx.gasPrice != tx.gasPrice:
    return err("gas price mismatch: $1 != $2" % [$returnedTx.gasPrice, $tx.gasPrice])

  if returnedTx.value != tx.value:
    return err("value mismatch: $1 != $2" % [$returnedTx.value, $tx.value])

  if returnedTx.to != tx.to:
    return err("to mismatch: $1 != $2" % [$returnedTx.to, $tx.to])

  if returnedTx.payload != tx.payload:
    return err("data mismatch: $1 != $2" % [returnedTx.payload.toHex, tx.payload.toHex])

  if returnedTx.accessList.isNone:
    return err("expect accessList is some")

  let ac = returnedTx.accessList.get
  if ac != tx.accessList:
    return err("access list mismatch")

  if returnedTx.chainId.isNone:
    return err("chain id is none, expect is some")

  if returnedTx.chainId.get.uint64 != tx.chainId.uint64:
    return err("chain id mismatch: $1 != $2" % [$returnedTx.chainId.get.uint64, $tx.chainId.uint64])

  if returnedTx.maxFeePerGas != tx.maxFee:
    return err("max fee per gas mismatch: $1 != $2" % [$returnedTx.maxFeePerGas, $tx.maxFee])

  if returnedTx.maxPriorityFeePerGas != tx.maxPriorityFee:
    return err("max priority fee per gas mismatch: $1 != $2" % [$returnedTx.maxPriorityFeePerGas, $tx.maxPriorityFee])

  if returnedTx.maxFeePerBlobGas.isNone:
    return err("expect maxFeePerBlobGas is some")

  if returnedTx.maxFeePerBlobGas.get != tx.maxFeePerBlobGas:
    return err("max fee per data gas mismatch: $1 != $2" % [$returnedTx.maxFeePerBlobGas.get, $tx.maxFeePerBlobGas])

  if returnedTx.versionedHashes.isNone:
    return err("expect versioned hashes is some")

  let vs = returnedTx.versionedHashes.get
  if vs != tx.versionedHashes:
    return err("blob versioned hashes mismatch")

  if returnedTx.txType != tx.txType:
    return err("type mismatch: $1 != $2" % [$returnedTx.txType, $tx.txType])

  ok()

proc beaconRootStorageIndexes*(timestamp: uint64): (UInt256, UInt256) =
  # Calculate keys
  let
    timestampReduced = timestamp mod HISTORY_BUFFER_LENGTH
    timestampExtended = timestampReduced + HISTORY_BUFFER_LENGTH

  (timestampReduced.u256, timestampExtended.u256)


type
  BlobWrapData* = object
    versionedHash*: common.Hash256
    blob*         : kzg.KzgBlob
    commitment*   : kzg.KZGCommitment
    proof*        : kzg.KzgProof

  BlobData* = ref object
    txs*  : seq[Transaction]
    data*: seq[BlobWrapData]

proc getBlobDataInPayload*(pool: TestBlobTxPool, payload: ExecutionPayload): Result[BlobData, string] =
  var blobData = BlobData()

  # Find all blob transactions included in the payload
  for binaryTx in payload.transactions:
    # Unmarshal the tx from the payload, which should be the minimal version
    # of the blob transaction
    let txData = rlp.decode(distinctBase binaryTx, Transaction)
    if txData.txType != TxEIP4844:
      continue

    let txHash = rlpHash(txData)

    # Find the transaction in the current pool of known transactions
    if not pool.transactions.hasKey(txHash):
      return err("could not find transaction in the pool")

    let blobTx = pool.transactions[txHash]
    if blobTx.networkPayload.isNil:
      return err("blob data is nil")

    let np = blobTx.networkPayload
    if blobTx.versionedHashes.len != np.commitments.len or
       np.commitments.len != np.blobs.len or
       np.blobs.len != np.proofs.len:
      return err("invalid blob wrap data")

    for i in 0..<blobTx.versionedHashes.len:
      blobData.data.add BlobWrapData(
        versionedHash: blobTx.versionedHashes[i],
        commitment   : np.commitments[i],
        blob         : np.blobs[i],
        proof        : np.proofs[i],
      )
    blobData.txs.add blobTx

  return ok(blobData)

proc verifyBeaconRootStorage*(client: RpcClient, payload: ExecutionPayload): bool =
  # Read the storage keys from the stateful precompile that stores the beacon roots and verify
  # that the beacon root is the same as the one in the payload
  let
    blockNumber = u256 payload.blockNumber
    precompileAddress = BEACON_ROOTS_ADDRESS
    (timestampKey, beaconRootKey) = beaconRootStorageIndexes(payload.timestamp.uint64)

  # Verify the timestamp key
  var r = client.storageAt(precompileAddress, timestampKey, blockNumber)
  if r.isErr:
    error "verifyBeaconRootStorage", msg=r.error
    return false

  if r.get != payload.timestamp.uint64.u256:
    error "verifyBeaconRootStorage storage 1",
      expect=payload.timestamp.uint64.u256,
      get=r.get
    return false

  # Verify the beacon root key
  r = client.storageAt(precompileAddress, beaconRootKey, blockNumber)
  let parentBeaconBlockRoot = timestampToBeaconRoot(payload.timestamp)
  if parentBeaconBlockRoot != beaconRoot(r.get):
    error "verifyBeaconRootStorage storage 2",
      expect=parentBeaconBlockRoot.toHex,
      get=beaconRoot(r.get).toHex
    return false

  return true