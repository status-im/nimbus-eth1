# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  eth/common

type
  AccountsSample* = object
    name*: string   ## sample name, also used as sub-directory for db separation
    file*: string
    firstItem*: int
    lastItem*: int

  CaptureSpecs* = object
    name*: string   ## sample name, also used as sub-directory for db separation
    network*: NetworkId
    file*: string   ## name of capture file
    numBlocks*: int ## Number of blocks to load

  SnapSyncSpecs* = object
    name*: string
    network*: NetworkId
    snapDump*: string
    tailBlocks*: string
    pivotBlock*: uint64
    nItems*: int

# End
