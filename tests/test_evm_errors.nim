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

    let revertReason = unpackRevertReason(data.hexToSeqByte()).expect("something")
    check revertReason == "UniswapV2Router: EXPIRED"

  test "unpack revert reason data missing bytes":
    let data = "0x08c379a0000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000018556e69737761705632526f757465723a20455850495245440000000000000000"

    let revertReason = unpackRevertReason(data.hexToSeqByte())
    check revertReason == Opt.none(string)
    
  test "unpack panic reason data":
    let data = "0x4e487b710000000000000000000000000000000000000000000000000000000000000032"

    var revertReason = unpackRevertReason(data.hexToSeqByte()).expect("something")
    check revertReason == "out-of-bounds access of an array or bytesN"

  test "unpack panic reason data missing byte":
    let data = "0x4e487b7100000000000000000000000000000000000000000000000000000000000032"

    var revertReason = unpackRevertReason(data.hexToSeqByte())
    check revertReason == Opt.none(string)
