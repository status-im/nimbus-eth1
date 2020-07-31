import
  os, tables, json, ./config, stew/[results, byteutils],
  eth/trie/db, eth/[trie, rlp, common, keyfile], nimcrypto

export nimcrypto.`$`

proc calcRootHash[T](items: openArray[T]): Hash256 =
  var tr = initHexaryTrie(newMemoryDB())
  for i, t in items:
    tr.put(rlp.encode(i), rlp.encode(t))
  return tr.rootHash

template calcTxRoot*(transactions: openArray[Transaction]): Hash256 =
  calcRootHash(transactions)

template calcReceiptRoot*(receipts: openArray[Receipt]): Hash256 =
  calcRootHash(receipts)

func keccakHash*(value: openarray[byte]): Hash256 {.inline.} =
  keccak256.digest value

func generateAddress*(address: EthAddress, nonce: AccountNonce): EthAddress =
  result[0..19] = keccakHash(rlp.encodeList(address, nonce)).data.toOpenArray(12, 31)

func generateSafeAddress*(address: EthAddress, salt: Uint256, data: openArray[byte]): EthAddress =
  const prefix = [0xff.byte]
  let dataHash = keccakHash(data)
  var hashResult: Hash256

  var ctx: keccak256
  ctx.init()
  ctx.update(prefix)
  ctx.update(address)
  ctx.update(salt.toByteArrayBE())
  ctx.update(dataHash.data)
  ctx.finish hashResult.data
  ctx.clear()

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

proc loadKeystoreFiles*(conf: NimbusConfiguration): Result[void, string] =
  try:
    createDir(conf.keyStore)
  except OSError, IOError:
    return err("keystore: cannot create directory")

  for filename in walkDirRec(conf.keyStore):
    try:
      var data = json.parseFile(filename)
      let address: EthAddress = hexToByteArray[20](data["address"].getStr())
      conf.accounts[address] = NimbusAccount(keystore: data, unlocked: false)
    except JsonParsingError:
      return err("keystore: json parsing error " & filename)
    except ValueError:
      return err("keystore: data parsing error")
    except Exception: # json raises Exception
      return err("keystore: " & getCurrentExceptionMsg())

  result = ok()

proc getAccount*(conf: NimbusConfiguration, address: EthAddress): Result[NimbusAccount, string] =
  conf.accounts.withValue(address, val) do:
    result = ok(val[])
  do:
    result = err("getAccount: not available " & address.toHex)

proc unlockAccount*(conf: NimbusConfiguration, address: EthAddress, password: string): Result[void, string] =
  var acc = conf.getAccount(address).tryGet()
  let res = decodeKeyFileJson(acc.keystore, password)
  if res.isOk:
    acc.privateKey = res.get()
    acc.unlocked = true
    conf.accounts[address] = acc
    result = ok()
  else:
    result = err($res.error)
