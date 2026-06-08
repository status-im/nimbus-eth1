# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[os, parseutils, strutils, tables],
  stew/io2,
  results,
  eth/common/[blocks, receipts],
  ../block_proofs/historical_hashes_accumulator,
  ../e2store_formats/era1

export era1

type Era1DB* = ref object
  ## The Era1 database manages a collection of era files that together make up
  ## a linear history of pre-merge execution chain data.
  path: string
  network: string
  accumulator: Opt[FinishedHistoricalHashesAccumulator]
  files: seq[Era1File]
  filenames: Table[uint64, string]
  mergeBlockNumber: uint64

proc getEra1File(db: Era1DB, era: Era1): Result[Era1File, string] =
  for f in db.files:
    if f.blockIdx.startNumber.era == era:
      return ok(f)

  if era > db.mergeBlockNumber.era():
    return err("Selected era1 past pre-merge data")

  let name =
    if db.accumulator.isSome:
      let root = db.accumulator.value().historicalEpochs[era.int]
      era1FileName(db.network, era, Digest(data: root))
    else:
      try:
        db.filenames[uint64 era]
      except KeyError:
        return err("Era not covered by existing files: " & $era)

  let path = db.path / name

  if not isFile(path):
    return err("No such era file")

  # TODO: The open call does not do full verification. It is assumed here that
  # trusted files are used. We might want to add a full validation option.
  let f = Era1File.open(path, db.mergeBlockNumber).valueOr:
    return err(error)

  if db.files.len > 16: # TODO LRU
    close(db.files[0])
    db.files.delete(0)

  db.files.add(f)
  ok(f)

proc new*(
    T: type Era1DB,
    path: string,
    network: string,
    accumulator: FinishedHistoricalHashesAccumulator,
    mergeBlockNumber: uint64,
): Era1DB =
  Era1DB(
    path: path,
    network: network,
    accumulator: Opt.some(accumulator),
    mergeBlockNumber: mergeBlockNumber,
  )

proc new*(
    T: type Era1DB, path: string, network: string, mergeBlockNumber: uint64
): Result[Era1DB, string] =
  ## Initialize Era1DB by scanning `path` for era1 files. Unlike the accumulator
  ## overload, this discovers files by directory scan matched by network prefix
  ## and era number.
  var filenames: Table[uint64, string]
  try:
    for w in path.walkDir(relative = true):
      if w.kind in {pcFile, pcLinkToFile}:
        let (_, name, ext) = w.path.splitFile()
        if name.startsWith(network & "-") and ext == ".era1":
          var era: uint64
          discard parseBiggestUInt(name, era, start = network.len + 1)
          filenames[era] = w.path
  except CatchableError as exc:
    return err("Cannot open era database: " & exc.msg)

  if filenames.len == 0:
    return err("No era files found in " & path)

  ok Era1DB(
    path: path,
    network: network,
    accumulator: Opt.none(FinishedHistoricalHashesAccumulator),
    filenames: filenames,
    mergeBlockNumber: mergeBlockNumber,
  )

proc dispose*(db: Era1DB) =
  for f in db.files:
    if f != nil:
      f.close()
  db.files.reset()

proc verifyEra*(db: Era1DB, era: Era1): Result[Digest, string] =
  ## Verify all blocks in an era, including header/body/receipts consistency and
  ## calculates the accumulator root and compares it with the root stored in the
  ## era file. Returns the accumulator root.
  let f = ?db.getEra1File(era)
  f.verify()

proc getBlockHeader*(
    db: Era1DB, blockNumber: uint64, res: var Header
): Result[void, string] =
  let f = ?db.getEra1File(blockNumber.era)

  f.getBlockHeader(blockNumber, res)

proc getBlockBody*(
    db: Era1DB, blockNumber: uint64, res: var BlockBody
): Result[void, string] =
  let f = ?db.getEra1File(blockNumber.era)

  f.getBlockBody(blockNumber, res)

proc getReceipts*(
    db: Era1DB, blockNumber: uint64, res: var seq[Receipt]
): Result[void, string] =
  let f = ?db.getEra1File(blockNumber.era)

  f.getReceipts(blockNumber, res)

proc getTotalDifficulty*(db: Era1DB, blockNumber: uint64): Result[UInt256, string] =
  let f = ?db.getEra1File(blockNumber.era)

  f.getTotalDifficulty(blockNumber)

proc getEthBlock*(
    db: Era1DB, blockNumber: uint64, res: var Block
): Result[void, string] =
  let f = ?db.getEra1File(blockNumber.era)

  f.getEthBlock(blockNumber, res)

proc getBlockTuple*(
    db: Era1DB, blockNumber: uint64, res: var BlockTuple
): Result[void, string] =
  let f = ?db.getEra1File(blockNumber.era)

  f.getBlockTuple(blockNumber, res)
