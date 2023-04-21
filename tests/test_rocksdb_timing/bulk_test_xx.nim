#
# Copyright (c) 2018-2021 Status Research & Development GmbH
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
    name*: string   ## sample name, also used as sub-directory for db separation
    network*: NetworkId
    file*: string   ## name of capture file
    numBlocks*: int ## Number of blocks to load

const
  bulkTest0* = CaptureSpecs(
    name: "some-goerli",
    network: GoerliNet,
    file: "goerli68161.txt.gz",
    numBlocks: 1_000)

  bulkTest1* = CaptureSpecs(
    name:      "full-goerli",
    network:   bulkTest0.network,
    file:      bulkTest0.file,
    numBlocks: high(int))

  bulkTest2* = CaptureSpecs(
    name:      "more-goerli",
    network:   GoerliNet,
    file:      "goerli482304.txt.gz",
    numBlocks: high(int))

  bulkTest3* = CaptureSpecs(
    name:      "mainnet",
    network:   MainNet,
    file:      "mainnet332160.txt.gz",
    numBlocks: high(int))

# End
