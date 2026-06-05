# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[os, parseutils, strutils, tables],
  stew/io2,
  results,
  beacon_chain/spec/presets,
  ssz_serialization,
  eth/common/[blocks, receipts],
  ../e2store_formats/ere

export ere

type EreDB* = ref object
  ## The ere database manages a collection of ere files that together make up
  ## a linear history of execution chain data, covering pre-merge through
  ## post-merge eras.
  path: string
  network: string
  mergeBlockNumber: uint64
  files: seq[EreFile]
  filenames: Table[uint64, string]

proc getEreFile(db: EreDB, era: Era): Result[EreFile, string] =
  for f in db.files:
    if f.blockIdx.startNumber.era == era:
      return ok(f)

  let
    name =
      try:
        db.filenames[uint64 era]
      except KeyError:
        return err("Era not covered by existing ere files: " & $era.uint64)
    path = db.path / name

  if not isFile(path):
    return err("Ere file no longer available: " & path)

  let (_, noProofs, noReceipts) = ?parseEreFileName(path)
  let f = ?EreFile.open(path, db.mergeBlockNumber, noProofs, noReceipts)

  if db.files.len > 16: # TODO LRU
    close(db.files[0])
    db.files.delete(0)

  db.files.add(f)
  ok(f)

proc init*(
    T: type EreDB, path: string, network: string, mergeBlockNumber: uint64
): Result[EreDB, string] =
  var filenames: Table[uint64, string]
  try:
    for w in path.walkDir(relative = true):
      if w.kind in {pcFile, pcLinkToFile}:
        let (_, name, ext) = w.path.splitFile()
        if name.startsWith(network & "-") and ext == ".ere":
          var era: uint64
          discard parseBiggestUInt(name, era, start = network.len + 1)
          filenames[era] = w.path
  except CatchableError as exc:
    return err("Cannot open ere database: " & exc.msg)
  if filenames.len == 0:
    return err("No ere files found in " & path)

  ok EreDB(
    path: path,
    network: network,
    mergeBlockNumber: mergeBlockNumber,
    filenames: filenames,
  )

proc dispose*(db: EreDB) =
  for f in db.files:
    if f != nil:
      f.close()
  db.files.reset()

proc verifyEra*(
    db: EreDB, era: Era, v: HeaderVerifier, cfg: RuntimeConfig
): Result[Opt[Digest], string] =
  ## Verify all blocks in an era, including header/body/receipts consistency and
  ## proof verification against the given HeaderVerifier.
  ## Returns the accumulator root for pre-merge eras, none for post-merge.
  let f = ?db.getEreFile(era)
  f.verify(v, cfg)

proc getBlockHeader*(
    db: EreDB, blockNumber: uint64, res: var Header
): Result[void, string] =
  let f = ?db.getEreFile(blockNumber.era)
  res = ?f.getBlockHeader(blockNumber)
  ok()

proc getBlockBody*(
    db: EreDB, blockNumber: uint64, res: var BlockBody
): Result[void, string] =
  let f = ?db.getEreFile(blockNumber.era)
  res = ?f.getBlockBody(blockNumber)
  ok()

proc getReceipts*(
    db: EreDB, blockNumber: uint64, res: var seq[StoredReceipt]
): Result[void, string] =
  let f = ?db.getEreFile(blockNumber.era)
  res = ?f.getReceipts(blockNumber)
  ok()

proc getProof*(db: EreDB, blockNumber: uint64, res: var Proof): Result[void, string] =
  let f = ?db.getEreFile(blockNumber.era)
  res = ?f.getProof(blockNumber)
  ok()

proc getTotalDifficulty*(db: EreDB, blockNumber: uint64): Result[UInt256, string] =
  ## Only available for pre-merge blocks.
  let f = ?db.getEreFile(blockNumber.era)
  f.getTotalDifficulty(blockNumber)

proc getEthBlock*(
    db: EreDB, blockNumber: uint64, res: var Block
): Result[void, string] =
  let f = ?db.getEreFile(blockNumber.era)
  res = ?f.getEthBlock(blockNumber)
  ok()
