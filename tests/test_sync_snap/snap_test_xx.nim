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
  ./test_types

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
    name: "test2",
    file: "sample1.txt.gz",
    lastItem: high(int))

  snapTest3* = AccountsSample(
    name: "test3",
    file: snapTest2.file,
    lastItem: 0) # Only the first `snap/1` reply from the sample

# End
