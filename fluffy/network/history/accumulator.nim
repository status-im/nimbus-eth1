# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  eth/db/kvstore,
  eth/db/kvstore_sqlite3,
  eth/common/eth_types,
  ssz_serialization, ssz_serialization/[proofs, merkleization],
  ../../common/common_types,
  ../../populate_db,
  ./history_content

export kvstore_sqlite3, merkleization

# Header Accumulator
# Part from specification
# https://github.com/ethereum/portal-network-specs/blob/master/header-gossip-network.md#accumulator-snapshot
# However, applied for the history network instead of the header gossip network
# as per https://github.com/ethereum/portal-network-specs/issues/153

const
  epochSize* = 8192 # blocks
  maxHistoricalEpochs = 131072 # 2^17

type
  HeaderRecord* = object
    blockHash*: BlockHash
    totalDifficulty*: UInt256

  EpochAccumulator* = List[HeaderRecord, epochSize]

  Accumulator* = object
    historicalEpochs*: List[Bytes32, maxHistoricalEpochs]
    currentEpoch*: EpochAccumulator

func updateAccumulator*(a: var Accumulator, header: BlockHeader) =
  let lastTotalDifficulty =
    if a.currentEpoch.len() == 0:
      0.stuint(256)
    else:
      a.currentEpoch[^1].totalDifficulty

  if a.currentEpoch.len() == epochSize:
    let epochHash = hash_tree_root(a.currentEpoch)

    doAssert(a.historicalEpochs.add(epochHash.data))
    a.currentEpoch = EpochAccumulator.init(@[])

  let headerRecord =
    HeaderRecord(
      blockHash: header.blockHash(),
      totalDifficulty: lastTotalDifficulty + header.difficulty)

  let res = a.currentEpoch.add(headerRecord)
  doAssert(res, "Can't fail because of currentEpoch length check")

type
  # Note:
  # This database should eventually just be a part of the ContentDB.
  # The reason it is currently separated is because it is experimental and
  # because accumulator data will in the first tests be used aside to verify
  # headers without actually transferring the data over the network. Hence,
  # all data needs to be available and no pruning should be done on this data.
  AccumulatorDB* = ref object
    kv: KvStoreRef

  # This is a bit of a hacky way to access the latest accumulator right now,
  # hacky in the sense that in theory some contentId could result in this key.
  # Could have a prefix for each key access, but that will not play along nicely
  # with calls that use distance function (pruning, range access)
  # Could drop it in a seperate table/kvstore. And could have a mapping of
  # certain specific requests (e.g. latest) to their hash.
  DbKey = enum
    kLatestAccumulator

func subkey(kind: DbKey): array[1, byte] =
  [byte ord(kind)]

template expectDb(x: auto): untyped =
  # There's no meaningful error handling implemented for a corrupt database or
  # full disk - this requires manual intervention, so we'll panic for now
  x.expect("working database (disk broken/full?)")

proc new*(T: type AccumulatorDB, path: string, inMemory = false): AccumulatorDB =
  let db =
    if inMemory:
      SqStoreRef.init("", "fluffy-acc-db", inMemory = true).expect(
        "working database (out of memory?)")
    else:
      SqStoreRef.init(path, "fluffy-acc-db").expectDb()

  AccumulatorDB(kv: kvStore db.openKvStore().expectDb())

proc get(db: AccumulatorDB, key: openArray[byte]): Option[seq[byte]] =
  var res: Option[seq[byte]]
  proc onData(data: openArray[byte]) = res = some(@data)

  discard db.kv.get(key, onData).expectDb()

  return res

proc put(db: AccumulatorDB, key, value: openArray[byte]) =
  db.kv.put(key, value).expectDb()

proc contains(db: AccumulatorDB, key: openArray[byte]): bool =
  db.kv.contains(key).expectDb()

proc del(db: AccumulatorDB, key: openArray[byte]) =
  db.kv.del(key).expectDb()

proc get*(db: AccumulatorDB, key: ContentId): Option[seq[byte]] =
  db.get(key.toByteArrayBE())

proc put*(db: AccumulatorDB, key: ContentId, value: openArray[byte]) =
  db.put(key.toByteArrayBE(), value)

proc contains*(db: AccumulatorDB, key: ContentId): bool =
  db.contains(key.toByteArrayBE())

proc del*(db: AccumulatorDB, key: ContentId) =
  db.del(key.toByteArrayBE())

proc get(
    db: AccumulatorDB, key: openArray[byte],
    T: type auto): Option[T] =
  let res = db.get(key)
  if res.isSome():
    try:
      some(SSZ.decode(res.get(), T))
    except SszError:
      raiseAssert("Stored data should always be serialized correctly")
  else:
    none(T)

# TODO: Will it be required to store more than just the latest accumulator?
proc getAccumulator*(db: AccumulatorDB, key: ContentId): Option[Accumulator] =
  db.get(key.toByteArrayBE, Accumulator)

proc getAccumulator*(db: AccumulatorDB): Option[Accumulator] =
  db.get(subkey(kLatestAccumulator), Accumulator)

proc getAccumulatorSSZ*(db: AccumulatorDB): Option[seq[byte]] =
  db.get(subkey(kLatestAccumulator))

proc putAccumulator*(db: AccumulatorDB, value: openArray[byte]) =
  db.put(subkey(kLatestAccumulator), value)

proc getEpochAccumulator*(
    db: AccumulatorDB, key: ContentId): Option[EpochAccumulator] =
  db.get(key.toByteArrayBE(), EpochAccumulator)

# Following calls are there for building up the accumulator from a bit set of
# headers, which then can be used to inject into the network and to generate
# header proofs from.
# It will not be used in the more general usage of Fluffy
# Note: One could also make a Portal network and or json-rpc eth1 endpoint
# version of this.

proc buildAccumulator*(db: AccumulatorDB, headers: seq[BlockHeader]) =
  var accumulator: Accumulator
  for header in headers:
    updateAccumulator(accumulator, header)

    if accumulator.currentEpoch.len() == epochSize:
      let rootHash = accumulator.currentEpoch.hash_tree_root()
      let key = ContentKey(
        contentType: epochAccumulator,
        epochAccumulatorKey: EpochAccumulatorKey(
          epochHash: rootHash))

      db.put(key.toContentId(), SSZ.encode(accumulator.currentEpoch))

  db.putAccumulator(SSZ.encode(accumulator))

proc buildAccumulator*(
    db: AccumulatorDB, dataFile: string): Result[void, string] =
  let blockData = ? readBlockDataTable(dataFile)

  var headers: seq[BlockHeader]
  # Len of headers from blockdata + genesis header
  headers.setLen(blockData.len() + 1)

  headers[0] = getGenesisHeader()

  for k, v in blockData.pairs:
    let header = ? v.readBlockHeader()
    headers[header.blockNumber.truncate(int)] = header

  db.buildAccumulator(headers)

  ok()

func buildAccumulator(headers: seq[BlockHeader]): Accumulator =
  var accumulator: Accumulator
  for header in headers:
    updateAccumulator(accumulator, header)

  accumulator

proc buildAccumulator*(dataFile: string): Result[Accumulator, string] =
  let blockData = ? readBlockDataTable(dataFile)

  var headers: seq[BlockHeader]
  # Len of headers from blockdata + genesis header
  headers.setLen(blockData.len() + 1)

  headers[0] = getGenesisHeader()

  for k, v in blockData.pairs:
    let header = ? v.readBlockHeader()
    headers[header.blockNumber.truncate(int)] = header

  ok(buildAccumulator(headers))
