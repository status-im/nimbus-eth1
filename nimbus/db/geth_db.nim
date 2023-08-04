import eth/[rlp, common], core_db

const
  headerPrefix     = 'h'.byte # headerPrefix + num (uint64 big endian) + hash -> header
  headerHashSuffix = 'n'.byte # headerPrefix + num (uint64 big endian) + headerHashSuffix -> hash
  blockBodyPrefix  = 'b'.byte # blockBodyPrefix + num (uint64 big endian) + hash -> block body

proc headerHash*(db: CoreDbRef, number: uint64): Hash256 =
  var key: array[10, byte]
  key[0] = headerPrefix
  key[1..8] = toBytesBE(number)[0..^1]
  key[^1] = headerHashSuffix
  let res = db.kvt.get(key)
  doAssert(res.len == 32)
  result.data[0..31] = res[0..31]

proc blockHeader*(db: CoreDbRef, hash: Hash256, number: uint64): BlockHeader =
  var key: array[41, byte]
  key[0] = headerPrefix
  key[1..8] = toBytesBE(number)[0..^1]
  key[9..40] = hash.data[0..^1]
  let res = db.kvt.get(key)
  result = rlp.decode(res, BlockHeader)

proc blockHeader*(db: CoreDbRef, number: uint64): BlockHeader =
  let hash = db.headerHash(number)
  db.blockHeader(hash, number)

proc blockBody*(db: CoreDbRef, hash: Hash256, number: uint64): BlockBody =
  var key: array[41, byte]
  key[0] = blockBodyPrefix
  key[1..8] = toBytesBE(number)[0..^1]
  key[9..40] = hash.data[0..^1]
  let res = db.kvt.get(key)
  result = rlp.decode(res, BlockBody)
