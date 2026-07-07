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
  pkg/[chronicles, chronos, eth/common, results, stew/interval_set],
  ../../../../wire_protocol/snap/snap_types,
  ../../state_db,
  ../mpt_desc,
  ./cache_desc

logScope:
  topics = "snap sync"

when sizeof(Hash) != sizeof(uint):
  {.error: "Hash type must have size of uint".}

# ------------------------------------------------------------------------------
# Public RLP decoders
# ------------------------------------------------------------------------------

proc decodeStateData*(data: seq[byte]): Result[DecodedStateData,string] =
  const info = "decodeStateData"
  var
    rd = data.rlpFromBytes
    res: DecodedStateData
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

func decodeAccount*(data: seq[byte]): Result[DecodedAccount,string] =
  const info = "decodeAccount"
  var
    rd = data.rlpFromBytes
    res: DecodedAccount
  try:
    rd.tryEnterList()
    res.limit = rd.read(UInt256).to(ItemKey)
    res.accounts = rd.read(seq[SnapAccount])
    res.proof = rd.read(seq[ProofNode])
    res.peerID = cast[Hash](rd.read uint)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeStoSlot*(data: seq[byte]): Result[DecodedStoSlot,string] =
  const info = "decodeStoSlot"
  var
    rd = data.rlpFromBytes
    res: DecodedStoSlot
  try:
    rd.tryEnterList()
    res.limit = rd.read(UInt256).to(ItemKey)
    res.slot = rd.read(seq[StorageItem])
    res.proof = rd.read(seq[ProofNode])
    res.peerID = cast[Hash](rd.read uint)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeByteCode*(data: seq[byte]): Result[DecodedByteCode,string] =
  const info = "decodeByteCode"
  var
    rd = data.rlpFromBytes
    res: DecodedByteCode
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

func decodeLeafInv*(data: seq[byte]): Result[DecodedLeafIntv,string] =
  const info = "decodeLeafInv"
  var
    rd = data.rlpFromBytes
    res: DecodedLeafIntv
    first = true
  try:
    res.ranges = ItemKeyRangeSet.init()
    for w in rd.items:
      if first:
        res.root = w.read(Hash32)
        first = false
      else:
        let iv = w.read((UInt256,UInt256))
        discard res.ranges.merge(iv[0].to(ItemKey),iv[1].to(ItemKey))
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeFlatAcc*(data: seq[byte]): Result[Account,string] =
  const info = "decodeFlatAcc"
  var res: Account
  try:
    res = rlp.decode(data, Account)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeFlatSlot*(data: seq[byte]): Result[UInt256,string] =
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

template encodeAccount*(
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

template encodeStoSlot*(
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

template encodeByteCode*(
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

template encodeLeafInv*(
    root: Hash32;
    ranges: ItemKeyRangeSet;
      ): untyped =
  var wrt = initRlpList ranges.chunks+1
  wrt.append root
  for iv in ranges.increasing:
    wrt.append (iv.minPt.to(UInt256),iv.maxPt.to(UInt256))
  wrt.finish()

template encodeFlatAcc*(
    account: Account;
      ): untyped =
  rlp.encode(account)

template encodeFlatSlot*(
    slot: UInt256;
      ): untyped =
  rlp.encode(slot)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
