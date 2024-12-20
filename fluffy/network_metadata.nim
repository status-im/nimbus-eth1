# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, strutils, os, macros],
  results,
  stew/io2,
  chronos/timer,
  beacon_chain/spec/forks,
  ./network/history/validation/historical_hashes_accumulator

proc loadBootstrapNodes(path: string): seq[string] {.raises: [IOError].} =
  # Read a list of ENR URIs from a file containing a flat list of entries.
  # If the file can't be read, this will raise. This is intentionally.
  splitLines(readFile(path)).filterIt(it.startsWith("enr:")).mapIt(it.strip())

proc loadCompileTimeBootstrapNodes(path: string): seq[string] =
  try:
    return loadBootstrapNodes(path)
  # TODO: This error doesn't seem to get printed. It instead dies with an
  # unhandled exception (IOError)
  except IOError as err:
    macros.error "Failed to load bootstrap nodes metadata at '" & path & "': " & err.msg

const
  portalConfigDir =
    currentSourcePath.parentDir.parentDir.replace('\\', '/') / "vendor" /
    "portal-mainnet" / "config"
  # Note:
  # These are the bootstrap nodes for the Portal mainnet.
  # TODO: For the Portal testnet, additional bootstrap nodes need to be read
  # still and Protocol Ids need to be adjusted.
  #
  # When more config data is required per Portal network, a metadata object can
  # be created, but right now only bootstrap nodes can be different.
  # TODO: It would be nice to be able to use `loadBootstrapFile` here, but that
  # doesn't work at compile time. The main issue seems to be the usage of
  # rlp.rawData() in the enr code.
  mainnetBootstrapNodes* =
    loadCompileTimeBootstrapNodes(portalConfigDir / "bootstrap_nodes.txt")
  angelfoodBootstrapNodes* =
    loadCompileTimeBootstrapNodes(portalConfigDir / "bootstrap_nodes_angelfood.txt")

  historicalHashesAccumulatorSSZ* =
    slurp(portalConfigDir / "historical_hashes_accumulator.ssz")

  historicalRootsSSZ* = slurp(portalConfigDir / "historical_roots.ssz")

func loadAccumulator*(): FinishedHistoricalHashesAccumulator =
  try:
    SSZ.decode(historicalHashesAccumulatorSSZ, FinishedHistoricalHashesAccumulator)
  except SerializationError as err:
    raiseAssert "Invalid baked-in accumulator: " & err.msg

func loadHistoricalRoots*(): HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT] =
  try:
    SSZ.decode(historicalRootsSSZ, HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT])
  except SerializationError as err:
    raiseAssert "Invalid baked-in historical_roots: " & err.msg

type
  # TODO: I guess we could use the nimbus ChainConfig but:
  # - Only need some of the values right now
  # - `EthTime` uses std/times while chronos Moment is sufficient and more
  # sensible
  ChainConfig* = object
    mergeNetsplitBlock*: uint64
    shanghaiTime*: Opt[Moment]
    cancunTime*: Opt[Moment]

const
  # Allow this to be adjusted at compile time for testing. If more constants
  # need to be adjusted we can add some more ChainConfig presets either at
  # compile or runtime.
  mergeBlockNumber* {.intdefine.}: uint64 = 15537394

  chainConfig* = ChainConfig(
    mergeNetsplitBlock: mergeBlockNumber,
    shanghaiTime: Opt.some(Moment.init(1681338455'i64, Second)),
    cancunTime: Opt.none(Moment),
  )

func isTimestampForked(forkTime: Opt[Moment], timestamp: Moment): bool =
  if forkTime.isNone():
    false
  else:
    forkTime.get() <= timestamp

func isPoSBlock*(c: ChainConfig, blockNumber: uint64): bool =
  c.mergeNetsplitBlock <= blockNumber

func isShanghai*(c: ChainConfig, timestamp: Moment): bool =
  isTimestampForked(c.shanghaiTime, timestamp)

func isCancun*(c: ChainConfig, timestamp: Moment): bool =
  isTimestampForked(c.cancunTime, timestamp)
