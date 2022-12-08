import
  eth/common

from stew/objects
  import checkedEnumAssign

# these procs are duplicates of nim-eth/eth_types_rlp.nim
# both `readTxLegacy` and `readTxTyped` are exported here

template read[T](rlp: var Rlp, val: var T)=
  val = rlp.read(type val)

proc read[T](rlp: var Rlp, val: var Option[T])=
  if rlp.blobLen != 0:
    val = some(rlp.read(T))
  else:
    rlp.skipElem

proc readTxLegacy*(rlp: var Rlp, tx: var Transaction)=
  tx.txType = TxLegacy
  rlp.tryEnterList()
  rlp.read(tx.nonce)
  rlp.read(tx.gasPrice)
  rlp.read(tx.gasLimit)
  rlp.read(tx.to)
  rlp.read(tx.value)
  rlp.read(tx.payload)
  rlp.read(tx.V)
  rlp.read(tx.R)
  rlp.read(tx.S)

proc readTxEip2930(rlp: var Rlp, tx: var Transaction)=
  tx.txType = TxEip2930
  rlp.tryEnterList()
  tx.chainId = rlp.read(uint64).ChainId
  rlp.read(tx.nonce)
  rlp.read(tx.gasPrice)
  rlp.read(tx.gasLimit)
  rlp.read(tx.to)
  rlp.read(tx.value)
  rlp.read(tx.payload)
  rlp.read(tx.accessList)
  rlp.read(tx.V)
  rlp.read(tx.R)
  rlp.read(tx.S)

proc readTxEip1559(rlp: var Rlp, tx: var Transaction)=
  tx.txType = TxEip1559
  rlp.tryEnterList()
  tx.chainId = rlp.read(uint64).ChainId
  rlp.read(tx.nonce)
  rlp.read(tx.maxPriorityFee)
  rlp.read(tx.maxFee)
  rlp.read(tx.gasLimit)
  rlp.read(tx.to)
  rlp.read(tx.value)
  rlp.read(tx.payload)
  rlp.read(tx.accessList)
  rlp.read(tx.V)
  rlp.read(tx.R)
  rlp.read(tx.S)

proc readTxTyped*(rlp: var Rlp, tx: var Transaction) {.inline.} =
  # EIP-2718: We MUST decode the first byte as a byte, not `rlp.read(int)`.
  # If decoded with `rlp.read(int)`, bad transaction data (from the network)
  # or even just incorrectly framed data for other reasons fails with
  # any of these misleading error messages:
  # - "Message too large to fit in memory"
  # - "Number encoded with a leading zero"
  # - "Read past the end of the RLP stream"
  # - "Small number encoded in a non-canonical way"
  # - "Attempt to read an Int value past the RLP end"
  # - "The RLP contains a larger than expected Int value"
  if not rlp.isSingleByte:
    if not rlp.hasData:
      raise newException(MalformedRlpError,
        "Transaction expected but source RLP is empty")
    raise newException(MalformedRlpError,
      "TypedTransaction type byte is out of range, must be 0x00 to 0x7f")
  let txType = rlp.getByteValue
  rlp.position += 1

  var txVal: TxType
  if checkedEnumAssign(txVal, txType):
    case txVal:
    of TxEip2930:
      rlp.readTxEip2930(tx)
      return
    of TxEip1559:
      rlp.readTxEip1559(tx)
      return
    else:
      discard

  raise newException(UnsupportedRlpError,
    "TypedTransaction type must be 1 or 2 in this version, got " & $txType)
