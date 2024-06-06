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
  std/os,
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

const
  snapTest0* = AccountsSample(
    name: "sample0",
    file: "sample0.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapTest1* = AccountsSample(
    name: "test1",
    file: snapTest0.file,
    lastItem: 0) # Only the first `snap/1` reply from the sample

  snapTest2* = AccountsSample(
    name: "sample1",
    file: "sample1.txt.gz",
    lastItem: high(int))

  snapTest3* = AccountsSample(
    name: "test3",
    file: snapTest2.file,
    lastItem: 0) # Only the first `snap/1` reply from the sample

  # Also for storage tests
  snapTest4* = AccountsSample(
    name: "sample2",
    file: "sample2.txt.gz",
    lastItem: high(int))

  # Also for storage tests
  snapTest5* = AccountsSample(
    name: "sample3",
    file: "sample3.txt.gz",
    lastItem: high(int))

  # ----------------------

  snapOther0a* = AccountsSample(
    name: "Other0a",
    file: "account" / "account0_00_06_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapOther0b* = AccountsSample(
    name: "Other0b",
    file: "account" / "account0_07_08_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapOther1a* = AccountsSample(
    name: "Other1a",
    file: "account" / "account1_09_09_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapOther1b* = AccountsSample(
    name: "Other1b",
    file: "account" / "account1_10_17_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapOther2* = AccountsSample(
    name: "Other2",
    file: "account" / "account2_18_25_dump.txt.gz",
    firstItem: 1,
    lastItem: high(int))

  snapOther3* = AccountsSample(
    name: "Other3",
    file: "account" / "account3_26_33_dump.txt.gz",
    firstItem: 2,
    lastItem: high(int))

  snapOther4* = AccountsSample(
    name: "Other4",
    file: "account" / "account4_34_41_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapOther5* = AccountsSample(
    name: "Other5",
    file: "account" / "account5_42_49_dump.txt.gz",
    firstItem: 2,
    lastItem: high(int))

  snapOther6* = AccountsSample(
    name: "Other6",
    file: "account" / "account6_50_54_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapOtherList* = [
    snapOther0a, snapOther0b, snapOther1a, snapOther1b, snapOther2,
    snapOther3,  snapOther4,  snapOther5,  snapOther6]

  #<state-root-id> <sample-id-range> <state-root>
  #                                   <range-base>
  #                                   <last-account>
  #
  # 0b  7..8  346637e390dce1941c8f8c7bf21adb33cefc198c26bc1964ebf8507471e89000
  #           0000000000000000000000000000000000000000000000000000000000000000
  #           09e8d852bc952f53343967d775b55a7a626ce6f02c828f4b0d4509b790aee55b 
  #
  # 1b 10..17 979c81bf60286f195c9b69d0bf3c6e4b3939389702ed767d55230fe5db57b8f7
  #           0000000000000000000000000000000000000000000000000000000000000000
  #           44fc2f4f885e7110bcba5534e9dce2bc59261e1b6ceac2206f5d356575d58d6a
  #
  # 2  18..25 93353de9894e0eac48bfe0b0023488379aff8ffd4b6e96e0c2c51f395363c7fb
  #           024043dc9f47e85f13267584b6098d37e1f8884672423e5f2b86fe4cc606c9d7
  #           473c70d158603819829a2d637edd5fa8e8f05720d9895e5e87450b6b19d81239
  #
  # 4  34..41 d6feef8f3472c5288a5a99409bc0cddbb697637644266a9c8b2e134806ca0fc8
  #           2452fe42091c1f12adfe4ea768e47fe8d7b2494a552122470c89cb4c759fe614
  #           6958f4d824c2b679ad673cc3f373bb6c431e8941d027ed4a1c699925ccc31ea5
  #
  # 3  26..33 14d70751ba7fd40303a054c284bca4ef2f63a8e4e1973da90371dffc666bde32
  #           387bb75a840d46baa37a6d723d3b1de78f6a0a41d6094c47ee1dad16533b829e
  #           7d77e87f695f4244ff8cd4cbfc750003080578f9f51eac3ab3e50df1a7c088c4
  #
  # 6  50..54 11eba9ec2f204c8165a245f9d05bb7ebb5bfdbdbcccc1a849d8ab2b23550cc12
  #           74e30f84b7d6532cf3aeec8931fe6f7ef13d5bad90ebaae451d1f78c4ee41412
  #           9c5f3f14c3b3a6eb4d2201b3bf15cf15554d44ba49d8230a7c8a1709660ca2ef
  #
  # 5  42..49 f75477bd57be4883875042577bf6caab1bd7f8517f0ce3532d813e043ec9f5d0
  #           a04344c35a42386857589e92428b49b96cd0319a315b81bff5c7ae93151b5057
  #           e549721af6484420635f0336d90d2d0226ba9bbd599310ae76916b725980bd85
  #
  # 1a 9      979c81bf60286f195c9b69d0bf3c6e4b3939389702ed767d55230fe5db57b8f7
  #           fa261d159a47f908d499271fcf976b71244b260ca189f709b8b592d18c098b60
  #           fa361ef07b5b6cc719347b8d9db35e08986a575b0eca8701caf778f01a08640a
  #
  # 0a  0..6  346637e390dce1941c8f8c7bf21adb33cefc198c26bc1964ebf8507471e89000
  #           bf75c492276113636daa8cdd8b27ca5283e26965fbdc2568633480b6b104cd77
  #           fa99c0467106abe1ed33bd2b6acc1582b09e43d28308d04663d1ef9532e57c6e
  #
  # ------------------------

  #0  0..6  346637e390dce1941c8f8c7bf21adb33cefc198c26bc1964ebf8507471e89000
  #0  7..8  346637e390dce1941c8f8c7bf21adb33cefc198c26bc1964ebf8507471e89000
  #1  9     979c81bf60286f195c9b69d0bf3c6e4b3939389702ed767d55230fe5db57b8f7
  #1 10..17 979c81bf60286f195c9b69d0bf3c6e4b3939389702ed767d55230fe5db57b8f7
  #2 18..25 93353de9894e0eac48bfe0b0023488379aff8ffd4b6e96e0c2c51f395363c7fb
  #3 26..33 14d70751ba7fd40303a054c284bca4ef2f63a8e4e1973da90371dffc666bde32
  #4 34..41 d6feef8f3472c5288a5a99409bc0cddbb697637644266a9c8b2e134806ca0fc8
  #5 42..49 f75477bd57be4883875042577bf6caab1bd7f8517f0ce3532d813e043ec9f5d0
  #6 50..54 11eba9ec2f204c8165a245f9d05bb7ebb5bfdbdbcccc1a849d8ab2b23550cc12

  # ------------------------

  snapTestList* = [
    snapTest0, snapTest1, snapTest2, snapTest3]

  snapTestStorageList* = [
    snapTest4, snapTest5]

  snapOtherHealingList* = [
    @[snapOther0b, snapOther2, snapOther4],
    @[snapOther0a, snapOther1a, snapOther5]]

# End
