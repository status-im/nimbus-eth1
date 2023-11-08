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
  ../../nimbus/core/chain,
  ./test_types

const
  snapSyncdb0* = SnapSyncSpecs(
    name:       "main-snap",
    network:    MainNet,
    snapDump:   "mainnet=64.txt.gz",
    tailBlocks: "mainnet332160.txt.gz",
    pivotBlock: 64u64,
    nItems:     100)

  snapSyncdb1* = SnapSyncSpecs(
    name:       "main-snap",
    network:    MainNet,
    snapDump:   "mainnet=128.txt.gz",
    tailBlocks: "mainnet332160.txt.gz",
    pivotBlock: 128u64,
    nItems:     500)

  snapSyncdb2* = SnapSyncSpecs(
    name:       "main-snap",
    network:    MainNet,
    snapDump:   "mainnet=500.txt.gz",
    tailBlocks: "mainnet332160.txt.gz",
    pivotBlock: 500u64,
    nItems:     500)

  snapSyncdb3* = SnapSyncSpecs(
    name:       "main-snap",
    network:    MainNet,
    snapDump:   "mainnet=1000.txt.gz",
    tailBlocks: "mainnet332160.txt.gz",
    pivotBlock: 1000u64,
    nItems:     500)

  snapSyncdb4* = SnapSyncSpecs(
    name:       "main-snap",
    network:    MainNet,
    snapDump:   "mainnet=300000.txt.gz",
    tailBlocks: "mainnet299905-332160.txt.gz",
    pivotBlock: 300000u64,
    nItems:     500)

  snapSyncdbList* = [
    snapSyncdb0, snapSyncdb1, snapSyncdb2, snapSyncdb3, snapSyncdb4]

# End
