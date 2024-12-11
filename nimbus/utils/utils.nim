# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[math, times, strutils],
  eth/[common/eth_types_rlp, trie/ordered_trie],
  stew/byteutils,
  nimcrypto/sha2,
  ../constants

export eth_types_rlp

template calcTxRoot*(transactions: openArray[Transaction]): Root =
  orderedTrieRoot(transactions)

template calcWithdrawalsRoot*(withdrawals: openArray[Withdrawal]): Root =
  orderedTrieRoot(withdrawals)

template calcReceiptsRoot*(receipts: openArray[Receipt]): Root =
  orderedTrieRoot(receipts)

func calcRequestsHash*(requests: varargs[seq[byte]]): Hash32 =
  func calcHash(reqType: byte, data: openArray[byte]): Hash32 =
    var ctx: sha256
    ctx.init()
    ctx.update([reqType]) # request type
    ctx.update data
    ctx.finish(result.data)
    ctx.clear()

  var ctx: sha256
  ctx.init()
  for i, data in requests:
    ctx.update(calcHash(i.byte, data).data)
  ctx.finish(result.data)
  ctx.clear()

func calcRequestsHash*(reqs: Opt[array[3, seq[byte]]]): Opt[Hash32] =
  if reqs.isNone:
    Opt.none(Hash32)
  else:
    Opt.some(calcRequestsHash(reqs.get()[0], reqs.get()[1], reqs.get()[2]))

func sumHash*(hashes: varargs[Hash32]): Hash32 =
  var ctx: sha256
  ctx.init()
  for hash in hashes:
    ctx.update hash.data
  ctx.finish result.data
  ctx.clear()

proc sumHash*(body: BlockBody): Hash32 {.gcsafe, raises: []} =
  let txRoot = calcTxRoot(body.transactions)
  let ommersHash = keccak256(rlp.encode(body.uncles))
  let wdRoot = if body.withdrawals.isSome:
                 calcWithdrawalsRoot(body.withdrawals.get)
               else: EMPTY_ROOT_HASH
  sumHash(txRoot, ommersHash, wdRoot)

proc sumHash*(header: Header): Hash32 =
  let wdRoot = if header.withdrawalsRoot.isSome:
                 header.withdrawalsRoot.get
               else: EMPTY_ROOT_HASH
  sumHash(header.txRoot, header.ommersHash, wdRoot)

func hasBody*(h: Header): bool =
  h.txRoot != EMPTY_ROOT_HASH or
    h.ommersHash != EMPTY_UNCLE_HASH or
    h.withdrawalsRoot.get(EMPTY_ROOT_HASH) != EMPTY_ROOT_HASH

func generateAddress*(address: Address, nonce: AccountNonce): Address =
  result.data[0..19] = keccak256(rlp.encodeList(address, nonce)).data.toOpenArray(12, 31)

const ZERO_CONTRACTSALT* = default(Bytes32)

func generateSafeAddress*(address: Address, salt: Bytes32,
                          data: openArray[byte]): Address =
  const prefix = [0xff.byte]
  let
    dataHash = keccak256(data)
    hashResult = withKeccak256:
      h.update(prefix)
      h.update(address.data)
      h.update(salt.data)
      h.update(dataHash.data)

  hashResult.to(Address)

proc crc32*(crc: uint32, buf: openArray[byte]): uint32 =
  const kcrc32 = [ 0'u32, 0x1db71064, 0x3b6e20c8, 0x26d930ac, 0x76dc4190,
    0x6b6b51f4, 0x4db26158, 0x5005713c, 0xedb88320'u32, 0xf00f9344'u32, 0xd6d6a3e8'u32,
    0xcb61b38c'u32, 0x9b64c2b0'u32, 0x86d3d2d4'u32, 0xa00ae278'u32, 0xbdbdf21c'u32]

  var crcu32 = not crc
  for b in buf:
    crcu32 = (crcu32 shr 4) xor kcrc32[int((crcu32 and 0xF) xor (uint32(b) and 0xF'u32))]
    crcu32 = (crcu32 shr 4) xor kcrc32[int((crcu32 and 0xF) xor (uint32(b) shr 4'u32))]

  result = not crcu32

proc short*(h: Hash32): string =
  var bytes: array[6, byte]
  bytes[0..2] = h.data[0..2]
  bytes[^3..^1] = h.data[^3..^1]
  bytes.toHex

proc short*(h: Bytes32): string =
  var bytes: array[6, byte]
  bytes[0..2] = h.data[0..2]
  bytes[^3..^1] = h.data[^3..^1]
  bytes.toHex

func short*(x: Duration): string =
  let parts = x.toParts
  if parts[Hours] > 0:
    result.add $parts[Hours]
    result.add ':'

  result.add intToStr(parts[Minutes].int, 2)
  result.add ':'
  result.add intToStr(parts[Seconds].int, 2)

proc decompose*(rlp: var Rlp,
                header: var Header,
                body: var BlockBody) {.gcsafe, raises: [RlpError].} =
  var blk = rlp.read(Block)
  header = system.move(blk.header)
  body.transactions = system.move(blk.txs)
  body.uncles = system.move(blk.uncles)
  body.withdrawals = system.move(blk.withdrawals)

proc decompose*(rlpBytes: openArray[byte],
                header: var Header,
                body: var BlockBody) {.gcsafe, raises: [RlpError].} =
  var rlp = rlpFromBytes(rlpBytes)
  rlp.decompose(header, body)

func gwei*(n: uint64): GasInt =
  GasInt(n * (10'u64 ^ 9'u64))

# Helper types to convert gwei into wei more easily
func weiAmount*(w: Withdrawal): UInt256 =
  w.amount.u256 * (10'u64 ^ 9'u64).u256

func isGenesis*(header: Header): bool =
  header.number == 0'u64 and
    header.parentHash == GENESIS_PARENT_HASH
