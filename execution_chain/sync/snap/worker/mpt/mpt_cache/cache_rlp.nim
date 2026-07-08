# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/[chronos, eth/common, results, stew/interval_set],
  ../../../../wire_protocol/snap/snap_types,
  ../../state_db,
  ../mpt_desc,
  ./cache_desc

when sizeof(Hash) != sizeof(uint):
  {.error: "Hash type must have size of uint".}

# ------------------------------------------------------------------------------
# Private RLP helpers
# ------------------------------------------------------------------------------

func fromRlp(
    _: type ItemKeyRangeSet;
    data: openArray[byte];
      ): ItemKeyRangeSet
      {.raises: [RlpError].} =
  var
    rd = data.rlpFromBytes
    rng = ItemKeyRangeSet.init()
  for w in rd.items():
    w.tryEnterList()
    let
      a = w.read UInt256
      b = w.read UInt256
    discard rng.merge(a.to(ItemKey),b.to(ItemKey))
  rng

func toRlp(rng: ItemKeyRangeSet): seq[byte] =
  var wrt = initRlpList rng.chunks()
  for iv in rng.increasing():
    var w = initRlpList 2
    w.append iv.minPt.to(UInt256)
    w.append iv.maxPt.to(UInt256)
    wrt.appendRawBytes w.finish()
  wrt.finish()

# ------------------------------------------------------------------------------
# Public RLP decoders
# ------------------------------------------------------------------------------

proc decodeStateData*(data: seq[byte]): Result[CacheStateData,string] =
  const info = "decodeStateData"
  var
    rd = data.rlpFromBytes
    res: CacheStateData
  try:
    rd.tryEnterList()
    res.hash = rd.read(Hash32).to(BlockHash)
    res.number = rd.read(BlockNumber)
    res.touch = Moment.fromNow(rd.read(uint64).int64.nanoseconds)
    res.tag = StateDataTag(rd.read uint8)
    res.coverage = rd.read(UInt256)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeAccountData*(data: seq[byte]): Result[CacheAccountData,string] =
  const info = "decodeAccount"
  var
    rd = data.rlpFromBytes
    res: CacheAccountData
  try:
    rd.tryEnterList()
    res.limit = rd.read(UInt256).to(ItemKey)
    res.accounts = rd.read(seq[SnapAccount])
    res.proof = rd.read(seq[ProofNode])
    res.peerID = cast[Hash](rd.read uint)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeStoSlotData*(data: seq[byte]): Result[CacheStoSlotData,string] =
  const info = "decodeStoSlot"
  var
    rd = data.rlpFromBytes
    res: CacheStoSlotData
  try:
    rd.tryEnterList()
    res.limit = rd.read(UInt256).to(ItemKey)
    res.slot = rd.read(seq[StorageItem])
    res.proof = rd.read(seq[ProofNode])
    res.peerID = cast[Hash](rd.read uint)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeByteCodeData*(data: seq[byte]): Result[CacheByteCodeData,string] =
  const info = "decodeByteCode"
  var
    rd = data.rlpFromBytes
    res: CacheByteCodeData
  try:
    rd.tryEnterList()
    res.limit = rd.read(UInt256).to(ItemKey)
    res.codes = rd.read(seq[(CodeHash,CodeItem)])
    res.peerID = cast[Hash](rd.read uint)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeHeader*(data: seq[byte]): Result[Header,string] =
  const info = "decodeHeader"
  var
    res: Header
  try:
    res = rlp.decode(data, Header)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeBal*(data: seq[byte]): Result[BlockAccessListRef,string] =
  const info = "decodeBal"
  var res = new BlockAccessList
  try:
    res[] = rlp.decode(data, BlockAccessList)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeAccMissingIntvData*(
    data: seq[byte];
      ): Result[CacheAccMissingIntvData,string] =
  const info = "decodeAccMissingIntvData"
  var
    rd = data.rlpFromBytes
    res: CacheAccMissingIntvData
  try:
    rd.tryEnterList()
    res.root = StateRoot rd.read(Hash32)
    res.ranges = ItemKeyRangeSet.fromRlp rd.rawData()
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(res)

func decodeStoMissingIntvData*(
    data: seq[byte];
      ): Result[CacheStoMissingIntvData,string] =
  const info = "decodeStoMissingIntvData"
  var
    rd = data.rlpFromBytes
    res: CacheStoMissingIntvData
  try:
    rd.tryEnterList()
    res.ranges = ItemKeyRangeSet.fromRlp rd.rawData()
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(res)

func decodeFlatAccData*(data: seq[byte]): Result[Account,string] =
  const info = "decodeFlatAcc"
  var res: Account
  try:
    res = rlp.decode(data, Account)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeFlatSlotData*(data: seq[byte]): Result[UInt256,string] =
  const info = "decodeFlatSlot"
  var res: UInt256
  try:
    res = rlp.decode(data, UInt256)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

# ------------------------------------------------------------------------------
# Public RLP encoders
# ------------------------------------------------------------------------------

template encodeStateData*(
    hash: BlockHash;
    number: BlockNumber;
    touch: Moment;
    tag: StateDataTag;
    coverage: UInt256;
      ): untyped =
  var wrt = initRlpList 4
  wrt.append hash.to(Hash32)
  wrt.append number
  wrt.append max(touch.epochNanoSeconds(),0).uint64
  wrt.append tag.uint8
  wrt.append coverage
  wrt.finish()

template encodeAccountData*(
    limit: ItemKey;
    accounts: seq[SnapAccount];
    proof: seq[ProofNode];
    peerID: Hash;
      ): untyped =
  var wrt = initRlpList 4
  wrt.append limit.to(UInt256)
  wrt.append accounts
  wrt.append proof
  wrt.append cast[uint](peerID)
  wrt.finish()

template encodeStoSlotData*(
    limit: ItemKey;
    slot: seq[StorageItem];
    proof: seq[ProofNode];
    peerID: Hash;
      ): untyped =
  var wrt = initRlpList 4
  wrt.append limit.to(UInt256)
  wrt.append slot
  wrt.append proof
  wrt.append cast[uint](peerID)
  wrt.finish()

template encodeByteCodeData*(
    limit: ItemKey;
    codes: seq[(CodeHash,CodeItem)];
    peerID: Hash;
      ): untyped =
  var wrt = initRlpList 3
  wrt.append limit.to(UInt256)
  wrt.append codes
  wrt.append cast[uint](peerID)
  wrt.finish()

template encodeHeader*(
    header: Header;
      ): untyped =
  rlp.encode header

template encodeBal*(
    bal: BlockAccessListRef;
      ): untyped =
  rlp.encode bal[]

template encodeAccMissingIntvData*(
    root: StateRoot;
    rng: ItemKeyRangeSet;
      ): untyped =
  var wrt = initRlpList 2
  wrt.append Hash32(root)
  wrt.appendRawBytes rng.toRlp()
  var res = wrt.finish()
  res

template encodeStoMissingIntvData*(
    rng: ItemKeyRangeSet;
      ): untyped =
  var wrt = initRlpList 1
  wrt.appendRawBytes rng.toRlp()
  wrt.finish()

template encodeFlatAccData*(
    account: Account;
      ): untyped =
  rlp.encode(account)

template encodeFlatSlotData*(
    slot: UInt256;
      ): untyped =
  rlp.encode(slot)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
