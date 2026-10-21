# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
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

  test "unpack revert reason with oversized string length":
    let data = "0x08c379a0" &
      "0000000000000000000000000000000000000000000000000000000000000020" &
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
      "0000000000000000000000000000000000000000000000000000000000000000"

    check unpackRevertReason(data.hexToSeqByte()) == Opt.none(string)

  test "unpack revert reason with oversized string offset":
    let data = "0x08c379a0" &
      "0000000000000000000000000000000000000000000000010000000000000020" &
      "0000000000000000000000000000000000000000000000000000000000000004" &
      "6f6f707300000000000000000000000000000000000000000000000000000000"

    check unpackRevertReason(data.hexToSeqByte()) == Opt.none(string)

  test "unpack revert reason data with a 32 byte string":
    let data = "0x08c379a0" &
      "0000000000000000000000000000000000000000000000000000000000000020" &
      "0000000000000000000000000000000000000000000000000000000000000020" &
      "3031323334353637383961626364656630313233343536373839616263646566"

    let revertReason = unpackRevertReason(data.hexToSeqByte()).expect("something")
    check revertReason == "0123456789abcdef0123456789abcdef"
