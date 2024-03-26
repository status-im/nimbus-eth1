# fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/os, stew/io2, results, ../network/history/accumulator, ../eth_data/era1

type Era1DB* = ref object
  ## The Era1 database manages a collection of era files that together make up
  ## a linear history of pre-merge execution chain data.
  path: string
  network: string
  accumulator: FinishedAccumulator
  files: seq[Era1File]

proc getEra1File(db: Era1DB, era: Era1): Result[Era1File, string] =
  for f in db.files:
    if f.blockIdx.startNumber.era == era:
      return ok(f)

  if era > mergeBlockNumber.era():
    return err("Selected era1 past pre-merge data")

  let
    root = db.accumulator.historicalEpochs[era.int]
    name = era1FileName(db.network, era, Digest(data: root))
    path = db.path / name

  if not isFile(path):
    return err("No such era file")

  # TODO: The open call does not do full verification. It is assumed here that
  # trusted files are used. We might want to add a full validation option.
  let f = Era1File.open(path).valueOr:
    return err(error)

  if db.files.len > 16: # TODO LRU
    close(db.files[0])
    db.files.delete(0)

  db.files.add(f)
  ok(f)

proc new*(
    T: type Era1DB, path: string, network: string, accumulator: FinishedAccumulator
): Era1DB =
  Era1DB(path: path, network: network, accumulator: accumulator)

proc getBlockTuple*(db: Era1DB, blockNumber: uint64): Result[BlockTuple, string] =
  let f = ?db.getEra1File(blockNumber.era)

  f.getBlockTuple(blockNumber)

proc getAccumulator*(
    db: Era1DB, blockNumber: uint64
): Result[EpochAccumulatorCached, string] =
  ## Get the Epoch Accumulator that the block with `blockNumber` is part of.
  # TODO: Probably want this `EpochAccumulatorCached` also actually cached in
  # the Era1File or EraDB object.
  let f = ?db.getEra1File(blockNumber.era)

  f.buildAccumulator()
