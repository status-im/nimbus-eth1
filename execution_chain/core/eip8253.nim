# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  eth/common/addresses,
  ../db/ledger,
  ../evm/[state, types],
  ../block_access_list/bal_tracker

const
  ZERO_NONCE_STORAGE_ACCOUNTS = [
    address"0xf468bcbc4a0bfdb06336e773382c5202e674db71",
    address"0xd8253352f6044cfe55bcc0748c3fa37b7df81f98",
    address"0x5983c6ac846dcf85fbbc4303f43eb91c379f79ae",
    address"0xde425ad4b8d2d9e0e12f65cbcd6d55f447b44083",
    address"0x50b1497068bae652df3562eb8ea7677ff84477fa",
    address"0x8398ff6c618e9515468c1c4b198d53666cbe8462",
    address"0x6f156dbf8ed30e53f7c9df73144e69f65cbb7e94",
    address"0x2c081ed1949d7dd9447f9d96e509befe576d4461",
    address"0xdb7c577b93baeb56dab50af4d6f86f99a06b96a2",
    address"0x14725085d004f1b10ee07234a4ab28c5ad2a7b9e",
    address"0xae3703584494ade958ad27ec2d289b7a67c19e90",
    address"0x7d6ae067de8d44ae1a08750e7d626d61a623c44a",
    address"0x4d149eb99bdeefc1f858f8fd22289c6beae99f2c",
    address"0x361d7a60b43587c7f6bba4f9fd9642747f65210a",
    address"0xb619f45637c39ca49a41ac64c11637a0a194455e",
    address"0x5071cb62aa170b7f66b26cae8004d90e6078bb1e",
    address"0xadd92e0650457c5db0c4c08cbf7ca580175d33d2",
    address"0x3311c08066580cb906a7287b6786e504c2ebd09f",
    address"0x02820e4bee488c40f7455fdca53125565148708f",
    address"0xe62dc49c92fa799033644d2a9afd7e3babe5a80a",
    address"0x5cc182fabfb81a056b6080d4200bc5150673d06f",
    address"0xf4a835ec1364809003de3925685f24cd360bdffe",
    address"0xfc4465f84b29a1f8794dc753f41bef1f4b025ed2",
    address"0x40490c9c468622d5c89646d6f3097f8eaf80c411",
    address"0xa21b22389bfc1cd6bc7ba19a4fc96adc3d0fe074",
    address"0x59ec0410867828e3b8c23dd8a29d9796ef523b17",
    address"0x19272418753b90d9a3e3efc8430b1612c55fcb3a",
    address"0xfee7707fa4b8c0a923a0e40399db3e7ce26069c6",
  ]

proc bumpZeroNonceStorageAccounts*(vmState: BaseVMState) =
  let
    ledger = vmState.ledger
  if vmState.balTrackerEnabled:
    let
      balTracker = vmState.balTracker
    doAssert balTracker.currentBlockAccessIndex == 0
    for account in ZERO_NONCE_STORAGE_ACCOUNTS:
      balTracker.trackNonceChange(account, 1)
      ledger.setNonce(account, 1)
  else:
    for account in ZERO_NONCE_STORAGE_ACCOUNTS:
      ledger.setNonce(account, 1)
