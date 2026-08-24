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

func decodeHeader*(data: openArray[byte]): Result[Header,string] =
  const info = "decodeHeader"
  var
    res: Header
  try:
    res = rlp.decode(data, Header)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeBal*(data: openArray[byte]): Result[BlockAccessListRef,string] =
  const info = "decodeBal"
  var res = new BlockAccessList
  try:
    res[] = rlp.decode(data, BlockAccessList)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeAccMissingIntvData*(
    data: openArray[byte];
      ): Result[CacheAccMissingIntvData,string] =
  const info = "decodeAccMissingIntvData"
  var
    rd = data.rlpFromBytes
    res: CacheAccMissingIntvData
  try:
    rd.tryEnterList()
    res.number = rd.read(BlockNumber)
    res.ranges = ItemKeyRangeSet.fromRlp rd.rawData()
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(res)

func decodeStoMissingIntvData*(
    data: openArray[byte];
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

func decodeFlatAccData*(
    data: openArray[byte];
     ): Result[CacheFlatAccData,string] =
  const info = "decodeFlatAccData"
  var res: CacheFlatAccData
  try:
    res = rlp.decode(data, CacheFlatAccData)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeAccPayloadData*(
    data: openArray[byte];
     ): Result[Account,string] =
  const info = "decodeAccPayloadData"
  var res: Account
  try:
    res = rlp.decode(data, Account)
  except RlpError as e:
    return err(info & ": " & $e.name & "(" & e.msg & ")")
  ok(move res)

func decodeFlatSlotData*(data: openArray[byte]): Result[UInt256,string] =
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

template encodeHeader*(
    header: Header;
      ): untyped =
  rlp.encode header

template encodeBal*(
    bal: BlockAccessListRef;
      ): untyped =
  rlp.encode bal[]

template encodeAccMissingIntvData*(
    number: BlockNumber;
    rng: ItemKeyRangeSet;
      ): untyped =
  var wrt = initRlpList 2
  wrt.append number
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
    data: CacheFlatAccData;
      ): untyped =
  rlp.encode(data)

template encodeFlatSlotData*(
    slot: UInt256;
      ): untyped =
  rlp.encode(slot)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
