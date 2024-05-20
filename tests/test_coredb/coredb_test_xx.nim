# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  eth/common,
  ../../nimbus/db/core_db,
  ../../nimbus/common/chain_config

type
  CaptureSpecs* = object
    name*: string            ## Sample name, also used as db directory
    case builtIn*: bool
    of true:
      network*: NetworkId    ## Built-in network ID (unless `config` below)
    else:
      genesis*: string       ## Optional config file (instead of `network`)
    files*: seq[string]      ## Names of capture files
    numBlocks*: int          ## Number of blocks to load
    dbType*: CoreDbType      ## Use `CoreDbType(0)` for default

func cloneWith(
    dsc: CaptureSpecs;
    name = "";
    network = NetworkId(0);
    genesis = "";
    files = seq[string].default;
    numBlocks = 0;
    dbType = CoreDbType(0);
      ): CaptureSpecs =
  result = dsc
  if network != NetworkId(0):
    result.builtIn = true
    result.network = network
  elif 0 < genesis.len:
    result.builtIn = false
    result.genesis = genesis
  if 0 < name.len:
    if name[0] == '-':
      result.name &= name
    elif name[0] == '+' and 1 < name.len:
      result.name &= name[1 .. ^1]
    else:
      result.name = name
  if 0 < files.len:
    result.files = files
  if 0 < numBlocks:
    result.numBlocks = numBlocks
  if dbType != CoreDbType(0):
    result.dbType = dbType


# Must not use `const` here, see `//github.com/nim-lang/Nim/issues/23295`
# Waiting for fix `//github.com/nim-lang/Nim/pull/23297` (or similar) to
# appear on local `Nim` compiler version.
let
  goerliSample =  CaptureSpecs(
    builtIn: true,
    name:    "goerli",
    network: GoerliNet,
    files:   @["goerli68161.txt.gz"])         # on local replay folder

  goerliSampleEx = CaptureSpecs(
    builtIn: true,
    name:    "goerli",
    network: GoerliNet,
    files:   @[
        "goerli482304.txt.gz",                # on nimbus-eth1-blobs/replay
        "goerli482305-504192.txt.gz"])

  mainSample = CaptureSpecs(
    builtIn: true,
    name:    "main",
    network: MainNet,
    files:  @["mainnet-00000-5ec1ffb8.era1"], # on local replay folder
    numBlocks: high(int),
    dbType: AristoDbRocks)

  mainSampleEx = CaptureSpecs(
    builtIn: true,
    name:    "main",
    network: MainNet,
    # will run over all avail files in parent folder
    files:   @["mainnet-era1.txt"])           # on external repo

  # ------------------

  # Supposed to run mostly on defaults
  bulkTest0* = mainSample
    .cloneWith(
      name      = "-more",
      numBlocks = high(int))

  bulkTest1* = mainSample
    .cloneWith(
      name      = "-some",
      numBlocks = 1_000)

  bulkTest2* = mainSampleEx
    .cloneWith(
      name      = "-am",
      numBlocks = 500_000,
      dbType    = AristoDbMemory)

  bulkTest3* = mainSampleEx
    .cloneWith(
      name      = "-ar",
      numBlocks = high(int),
      dbType    = AristoDbRocks)


  bulkTest4* = goerliSample
    .cloneWith(
      name      = "-more",
      numBlocks = high(int))

  bulkTest5* = goerliSample
    .cloneWith(
      name      = "-some",
      numBlocks = 1_000)

  bulkTest6* = goerliSampleEx
    .cloneWith(
      name      = "-am",
      numBlocks = high(int),
      dbType    = AristoDbMemory)

  bulkTest7* = goerliSampleEx
    .cloneWith(
      name      = "-ar",
      numBlocks = high(int),
      dbType    = AristoDbRocks)

  # ------------------

  allSamples* = [
    bulkTest0, bulkTest1, bulkTest2, bulkTest3,
    bulkTest4, bulkTest5, bulkTest6, bulkTest7]

# End
