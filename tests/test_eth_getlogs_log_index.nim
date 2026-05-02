# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  unittest2,
  eth/common/eth_types_rlp,
  eth/common/eth_types,
  ../execution_chain/rpc/filters,
  ../execution_chain/beacon/web3_eth_conv

suite "eth_getLogs logIndex regression":
  test "filtered logs keep their original block-wide index":
    let
      matchingAddress = address"0x7dcd17433742f4c0ca53122ab541d0ba67fc27df"
      otherAddress = address"0x882e7e5d12617c267a72948e716f231fa79e6d51"
      filterOptions = FilterOptions(
        address: AddressOrList(kind: slkSingle, single: matchingAddress),
        topics: @[]
      )

    var nonMatchingLogs: seq[Log]
    for i in 0'u8 ..< 10'u8:
      nonMatchingLogs.add Log(
        address: otherAddress,
        topics: @[default(Bytes32)],
        data: @[i]
      )

    let
      transactions = newSeq[Transaction](3)
      receipts = @[
        StoredReceipt(logs: nonMatchingLogs),
        StoredReceipt(logs: @[
          Log(address: matchingAddress, topics: @[default(Bytes32)], data: @[10'u8])
        ]),
        StoredReceipt(logs: @[
          Log(address: matchingAddress, topics: @[default(Bytes32)], data: @[11'u8])
        ]),
      ]
      logs = deriveLogs(Header(), transactions, receipts, filterOptions)

    check:
      logs.len == 2
      logs[0].logIndex.get() == w3Qty(10'u64)
      logs[1].logIndex.get() == w3Qty(11'u64)
