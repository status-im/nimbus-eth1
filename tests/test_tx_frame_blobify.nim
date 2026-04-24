# nimbus-eth1
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[strutils, tables],
  eth/common/hashes,
  results,
  ../execution_chain/db/aristo/[aristo_desc, aristo_tx_blobify],
  ../execution_chain/db/kvt/[kvt_desc, kvt_tx_blobify],
  ../execution_chain/db/[storage_types, tx_frame_db],
  ../execution_chain/db/core_db/memory_only,
  unittest2

suite "TxFrame blobify round-trip":

  test "storage_types: txFrameKey has correct discriminator":
    let h = Hash32.fromHex("0x" & "ab".repeat(32))
    let k = txFrameKey(h)
    check k.dataEndPos == 32
    check k.data[0] == byte(16)        # DBKeyKind.txFrame = 16
    check k.data[1 .. 32] == h.data

  test "aristo_tx_blobify: empty frame round-trip":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    let blob = blobifyTxFrame(frame.aTx)
    let rc = deblobifyTxFrame(blob)
    check rc.isOk
    let d = rc.value
    check d.vTop == frame.aTx.vTop
    check d.blockNumber == frame.aTx.blockNumber
    check d.sTab.len == 0
    check d.accLeaves.len == 0
    check d.stoLeaves.len == 0
    frame.dispose()

  test "kvt_tx_blobify: empty frame round-trip":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    let blob = blobifyKvtTxFrame(frame.kTx)
    let rc = deblobifyKvtTxFrame(blob)
    check rc.isOk
    check rc.value.len == 0
    frame.dispose()

  test "aristo_tx_blobify: wrong version returns error":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    var blob = blobifyTxFrame(frame.aTx)
    blob[0] = 0xFF'u8
    let rc = deblobifyTxFrame(blob)
    check rc.isErr
    check rc.error == DeblobTxFrameVersion
    frame.dispose()

  test "kvt_tx_blobify: wrong version returns error":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    var blob = blobifyKvtTxFrame(frame.kTx)
    blob[0] = 0xFF'u8
    let rc = deblobifyKvtTxFrame(blob)
    check rc.isErr
    check rc.error == DataInvalid
    frame.dispose()

  test "aristo_tx_blobify: blockNumber round-trip":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    frame.aTx.blockNumber = Opt.some(42'u64)
    let blob = blobifyTxFrame(frame.aTx)
    let rc = deblobifyTxFrame(blob)
    check rc.isOk
    check rc.value.blockNumber == Opt.some(42'u64)
    frame.dispose()

  test "kvt_tx_blobify: single entry round-trip":
    let coreDb = newCoreDbRef(AristoDbMemory)
    let frame = coreDb.txFrameBegin()
    frame.kTx.sTab[@[1'u8, 2, 3]] = @[0xDE'u8, 0xAD, 0xBE, 0xEF]
    let blob = blobifyKvtTxFrame(frame.kTx)
    let rc = deblobifyKvtTxFrame(blob)
    check rc.isOk
    check rc.value.len == 1
    check rc.value[@[1'u8, 2, 3]] == @[0xDE'u8, 0xAD, 0xBE, 0xEF]
    frame.dispose()

when isMainModule:
  discard
