import
  eth/[trie, rlp, common/eth_types_rlp, trie/db],
  stew/byteutils

export eth_types_rlp

{.push raises: [].}

proc calcRootHash[T](items: openArray[T]): Hash256
    {.gcsafe, raises: [RlpError]} =
  var tr = initHexaryTrie(newMemoryDB())
  for i, t in items:
    tr.put(rlp.encode(i), rlp.encode(t))
  return tr.rootHash

template calcTxRoot*(transactions: openArray[Transaction]): Hash256 =
  calcRootHash(transactions)

template calcReceiptRoot*(receipts: openArray[Receipt]): Hash256 =
  calcRootHash(receipts)

func generateAddress*(address: EthAddress, nonce: AccountNonce): EthAddress =
  result[0..19] = keccakHash(rlp.encodeList(address, nonce)).data.toOpenArray(12, 31)

type ContractSalt* = object
  bytes*: array[32, byte]

const ZERO_CONTRACTSALT* = default(ContractSalt)

func generateSafeAddress*(address: EthAddress, salt: ContractSalt,
                          data: openArray[byte]): EthAddress =
  const prefix = [0xff.byte]
  let
    dataHash = keccakHash(data)
    hashResult = withKeccakHash:
      h.update(prefix)
      h.update(address)
      h.update(salt.bytes)
      h.update(dataHash.data)

  result[0..19] = hashResult.data.toOpenArray(12, 31)

func hash*(b: BlockHeader): Hash256 {.inline.} =
  rlpHash(b)

proc crc32*(crc: uint32, buf: openArray[byte]): uint32 =
  const kcrc32 = [ 0'u32, 0x1db71064, 0x3b6e20c8, 0x26d930ac, 0x76dc4190,
    0x6b6b51f4, 0x4db26158, 0x5005713c, 0xedb88320'u32, 0xf00f9344'u32, 0xd6d6a3e8'u32,
    0xcb61b38c'u32, 0x9b64c2b0'u32, 0x86d3d2d4'u32, 0xa00ae278'u32, 0xbdbdf21c'u32]

  var crcu32 = not crc
  for b in buf:
    crcu32 = (crcu32 shr 4) xor kcrc32[int((crcu32 and 0xF) xor (uint32(b) and 0xF'u32))]
    crcu32 = (crcu32 shr 4) xor kcrc32[int((crcu32 and 0xF) xor (uint32(b) shr 4'u32))]

  result = not crcu32

proc short*(h: Hash256): string =
  var bytes: array[6, byte]
  bytes[0..2] = h.data[0..2]
  bytes[^3..^1] = h.data[^3..^1]
  bytes.toHex
