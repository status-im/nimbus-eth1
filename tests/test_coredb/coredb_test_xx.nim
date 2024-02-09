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

# Must not use `const` here, see `//github.com/nim-lang/Nim/issues/23295`
# Waiting for fix `//github.com/nim-lang/Nim/pull/23297` (or similar) to
# appear on local `Nim` compiler version.
let
  bulkTest0* = CaptureSpecs(
    name:      "some-goerli",
    builtIn:   true,
    network:   GoerliNet,
    files:     @["goerli68161.txt.gz"],
    numBlocks: 1_000)

  bulkTest1* = CaptureSpecs(
    name:      "more-goerli",
    builtIn:   true,
    network:   GoerliNet,
    files:     @["goerli68161.txt.gz"],
    numBlocks: high(int))

  bulkTest2* = CaptureSpecs(
    name:      "much-goerli",
    builtIn:   true,
    network:   GoerliNet,
    files:     @[
      "goerli482304.txt.gz",              # on nimbus-eth1-blobs/replay
      "goerli482305-504192.txt.gz"],
    numBlocks: high(int))

  bulkTest3* = CaptureSpecs(
    name:      "mainnet",
    builtIn:   true,
    network:   MainNet,
    files:     @[
      "mainnet332160.txt.gz",             # on nimbus-eth1-blobs/replay
      "mainnet332161-550848.txt.gz",
      "mainnet550849-719232.txt.gz",
      "mainnet719233-843841.txt.gz"],
    numBlocks: high(int))


  failSample0* = CaptureSpecs(
    name:      "fail-goerli",
    builtIn:   true,
    network:   GoerliNet,
    files:     bulkTest2.files,
    numBlocks: 301_375 + 1)               # +1 => crash on Aristo only

  failSample1* = CaptureSpecs(
    name:      "fail-main",
    builtIn:   true,
    network:   MainNet,
    files:     bulkTest3.files,
    numBlocks: 257_280 + 512)

# End
