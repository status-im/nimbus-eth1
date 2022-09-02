# Nimbus - Types, data structures and shared utilities used in network sync
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
  std/os,
  ./test_types

const
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

# End
