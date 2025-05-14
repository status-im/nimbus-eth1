# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  unittest2,
  eth/common/[addresses_rlp, base_rlp, hashes_rlp, receipts],
  ../../execution_chain/sync/wire_protocol/receipt69

suite "test receipt69 encoding":
  const
    addr1 = address"0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02"
    hash1 = hash32"c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    top1  = bytes32"56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"

  test "roundtrip test with hash":
    let log = Log(
      address: addr1,
      topics : @[top1],
      data   : @(top1.data)
    )

    let rec = Receipt69(
      recType: Eip1559Receipt,
      isHash : true,
      hash   : hash1,
      cumulativeGas: 100.GasInt,
      logs   : @[log],
    )

    let
      bytes1 = rlp.encode(rec)
      rc = rlp.decode(bytes1, Receipt69)

    check:
      rc.recType == rec.recType
      rc.isHash == rec.isHash
      rc.status == rec.status
      rc.hash == rec.hash
      rc.cumulativeGas == rec.cumulativeGas
      rc.logs == rec.logs

    let bytes2 = rlp.encode(rc)
    check bytes2 == bytes1

  test "roundtrip test with status":
    let log = Log(
      address: addr1,
      topics : @[top1],
      data   : @(top1.data)
    )

    let rec = Receipt69(
      recType: Eip4844Receipt,
      isHash : false,
      status : true,
      cumulativeGas: 100.GasInt,
      logs   : @[log],
    )

    let
      bytes1 = rlp.encode(rec)
      rc = rlp.decode(bytes1, Receipt69)

    check:
      rc.recType == rec.recType
      rc.isHash == rec.isHash
      rc.status == rec.status
      rc.hash == rec.hash
      rc.cumulativeGas == rec.cumulativeGas
      rc.logs == rec.logs

    let bytes2 = rlp.encode(rc)
    check bytes2 == bytes1

  test "roundtrip test with seq":
    let log = Log(
      address: addr1,
      topics : @[top1],
      data   : @(top1.data)
    )

    let rec = Receipt69(
      recType: Eip4844Receipt,
      isHash : false,
      status : true,
      cumulativeGas: 100.GasInt,
      logs   : @[log],
    )
  
    let
      list = @[rec, rec]
      bytes1 = rlp.encode(list)
      rc = rlp.decode(bytes1, seq[Receipt69])
      bytes2 = rlp.encode(rc)
      
    check bytes2 == bytes1
    
