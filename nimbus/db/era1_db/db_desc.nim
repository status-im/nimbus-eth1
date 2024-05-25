# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  stew/io2,
  std/[os, parseutils, strutils, tables],
  results,
  eth/common/eth_types,
  ../../fluffy/eth_data/era1

export results, eth_types

# TODO this is a "rough copy" of the fluffy DB, minus the accumulator (it goes
#      by era number alone instead of rooted name) - eventually the two should
#      be merged, when eth1 gains accumulators in its metadata

type Era1DbRef* = ref object
  ## The Era1 database manages a collection of era files that together make up
  ## a linear history of pre-merge execution chain data.
  path: string
  network: string
  files: seq[Era1File]
  filenames: Table[uint64, string]

proc getEra1File*(db: Era1DbRef, era: Era1): Result[Era1File, string] =
  for f in db.files:
    if f.blockIdx.startNumber.era == era:
      return ok(f)

  let
    name =
      try:
        db.filenames[uint64 era]
      except KeyError:
        return err("Era not covered by existing files: " & $era)
    path = db.path / name

  if not isFile(path):
    return err("Era file no longer available: " & path)

  # TODO: The open call does not do full verification. It is assumed here that
  # trusted files are used. We might want to add a full validation option.
  let f = Era1File.open(path).valueOr:
    return err(error)

  if db.files.len > 16: # TODO LRU
    close(db.files[0])
    db.files.delete(0)

  db.files.add(f)
  ok(f)

proc init*(
    T: type Era1DbRef, path: string, network: string
): Result[Era1DbRef, string] =
  var filenames: Table[uint64, string]
  try:
    for w in path.walkDir(relative = true):
      if w.kind in {pcFile, pcLinkToFile}:
        let (_, name, ext) = w.path.splitFile()
        # era files are named network-00era-root.era1 - we don't have the root
        # so do prefix matching instead
        if name.startsWith(network & "-") and ext == ".era1":
          var era1: uint64
          discard parseBiggestUInt(name, era1, start = network.len + 1)
          filenames[era1] = w.path
  except CatchableError as exc:
    return err "Cannot open era database: " & exc.msg
  if filenames.len == 0:
    return err "No era files found in " & path

  ok Era1DbRef(path: path, network: network, filenames: filenames)

proc getBlockTuple*(db: Era1DbRef, blockNumber: uint64): Result[BlockTuple, string] =
  let f = ?db.getEra1File(blockNumber.era)

  f.getBlockTuple(blockNumber)

proc dispose*(db: Era1DbRef) =
  for w in db.files:
    if w != nil:
      w.close()
  db.files.reset()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
