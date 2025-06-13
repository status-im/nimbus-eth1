# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stew/byteutils,
  unittest2,
  ../execution_chain/evm/evm_errors

suite "EVM errors tests":
  test "unpack revert reason data":
    let data = "0x08c379a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000018556e69737761705632526f757465723a20455850495245440000000000000000"

    var revertReason: string
    unpackRevertReason(data.hexToSeqByte(), revertReason)
    check revertReason == "UniswapV2Router: EXPIRED"

  test "unpack panic reason data":
    let data = "0x4e487b710000000000000000000000000000000000000000000000000000000000000032"

    var revertReason: string
    unpackRevertReason(data.hexToSeqByte(), revertReason)
    check revertReason == "out-of-bounds access of an array or bytesN"
