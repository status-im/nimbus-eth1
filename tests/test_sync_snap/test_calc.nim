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

## Snap sync components tester and TDD environment

import
  std/sequtils,
  eth/common,
  unittest2,
  ../../nimbus/sync/handlers/snap,
  ../../nimbus/sync/snap/[range_desc, worker/db/hexary_desc],
  ./test_helpers

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_calcAccountsListSizes*() =
  ## RLP does not allow static check ..

  let sample = Account(
    storageRoot: Hash256(data: high(UInt256).toBytesBE),
    codeHash:    Hash256(data: high(UInt256).toBytesBE),
    nonce:       high(uint64),
    balance:     high(UInt256))

  let tryLst = [0, 1, 2, 3, 594, 595, 596]

  for n in tryLst:
    #echo ">>> ", n, " ", sample.repeat(n).encode.len
    check n.accountRangeSize == sample.repeat(n).encode.len
  block:
    let n = tryLst[^1]
    check 4 + n * sample.encode.len == sample.repeat(n).encode.len


proc  test_calcProofsListSizes*() =
  ## RLP does not allow static check ..

  let sample = block:
    var xNode = XNodeObj(kind: Branch)
    for n in 0 .. 15:
      xNode.bLink[n] = high(NodeTag).to(Blob)
    xNode

  let tryLst = [0, 1, 2, 126, 127]

  for n in tryLst:
    #echo ">>> ", n, " ", sample.repeat(n).encode.len
    check n.proofNodesSize == sample.repeat(n).encode.len
  block:
    let n = tryLst[^1]
    check 4 + n * sample.encode.len == sample.repeat(n).encode.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
