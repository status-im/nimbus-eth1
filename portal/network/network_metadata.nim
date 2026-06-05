# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
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
  eth/common/headers,
  beacon_chain/spec/forks,
  ../../execution_chain/history/block_proofs/historical_hashes_accumulator

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
  portalVendorDir =
    currentSourcePath.parentDir.parentDir.parentDir.replace('\\', '/') / "vendor"

  mainnetPortalConfigDir = portalVendorDir / "portal-mainnet" / "config"
  sepoliaPortalConfigDir = portalVendorDir / "portal-sepolia" / "config"

  # Note:
  # These are the bootstrap nodes for the Portal mainnet.
  # TODO: For the Portal testnet, additional bootstrap nodes need to be read
  # still and Protocol Ids need to be adjusted.
  mainnetBootstrapNodes* =
    loadCompileTimeBootstrapNodes(mainnetPortalConfigDir / "bootstrap_nodes.txt")

  mainnetHistoricalHashesAccumulatorSSZ* =
    slurp(mainnetPortalConfigDir / "historical_hashes_accumulator.ssz")
  sepoliaHistoricalHashesAccumulatorSSZ* =
    slurp(sepoliaPortalConfigDir / "historical_hashes_accumulator.ssz")

  mainnetHistoricalRootsSSZ* = slurp(mainnetPortalConfigDir / "historical_roots.ssz")

func loadAccumulator*(
    network: string = "mainnet"
): FinishedHistoricalHashesAccumulator =
  let ssz =
    case network
    of "mainnet":
      mainnetHistoricalHashesAccumulatorSSZ
    of "sepolia":
      sepoliaHistoricalHashesAccumulatorSSZ
    else:
      raiseAssert "No baked-in accumulator for network: " & network
  try:
    SSZ.decode(ssz, FinishedHistoricalHashesAccumulator)
  except SerializationError as err:
    raiseAssert "Invalid baked-in accumulator: " & err.msg

func loadHistoricalRoots*(): HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT] =
  try:
    SSZ.decode(
      mainnetHistoricalRootsSSZ, HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT]
    )
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
    pragueTime*: Opt[Moment]

const
  # Allow this to be adjusted at compile time for testing. If more constants
  # need to be adjusted we can add some more ChainConfig presets either at
  # compile or runtime.
  mergeBlockNumber* {.intdefine.}: uint64 = 15537394

  chainConfig* = ChainConfig(
    mergeNetsplitBlock: mergeBlockNumber,
    shanghaiTime: Opt.some(Moment.init(1_681_338_455'i64, Second)),
    cancunTime: Opt.some(Moment.init(1_710_338_135'i64, Second)),
    pragueTime: Opt.some(Moment.init(1_740_434_112'i64, Second)),
  )

func isTimestampForked(forkTime: Opt[Moment], timestamp: Moment): bool =
  if forkTime.isNone():
    false
  else:
    forkTime.get() <= timestamp

func isPoSBlock*(c: ChainConfig, blockNumber: uint64): bool =
  c.mergeNetsplitBlock <= blockNumber

func isPoSBlock*(c: ChainConfig, header: Header): bool =
  c.mergeNetsplitBlock <= header.number

func isShanghai*(c: ChainConfig, timestamp: Moment): bool =
  isTimestampForked(c.shanghaiTime, timestamp)

func isCancun*(c: ChainConfig, timestamp: Moment): bool =
  isTimestampForked(c.cancunTime, timestamp)

func isPrague*(c: ChainConfig, timestamp: Moment): bool =
  isTimestampForked(c.pragueTime, timestamp)
