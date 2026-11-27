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
  std/[os, sequtils, tempfiles],
  unittest2,
  results,
  eth/common,
  ../execution_chain/db/core_db,
  ../execution_chain/db/core_db/[memory_only, persistent],
  ../execution_chain/db/[legacy_code_migration, opts, storage_types],
  ../execution_chain/evm/code_bytes

func testCode(size: int): seq[byte] =
  toSeq(0 ..< size).mapIt(if it mod 5 == 0: 0x5b'u8 else: byte(it mod 251))

suite "Legacy code migration":
  test "Legacy records are rewritten with their jumpdest bitmap":
    let
      path = createTempDir("nimbus-code-migration-", "")
      db = AristoDbRocks.newCoreDbRef(path, DbOptions.init())
      frame = db.baseTxFrame()
      legacyCodes = [1, 8, 9, 100, 24576, 65536].mapIt(testCode(it))
      bothKeys = testCode(200)
      newOnly = testCode(300)
      below = slotHashToSlotKey(keccak256(testCode(1)))
      above = [byte 7, 1, 2]
    defer:
      db.close()
      removeDir(path)

    for code in legacyCodes & bothKeys:
      check frame.put(legacyContractHashKey(keccak256(code)).toOpenArray, code).isOk
    for code in [bothKeys, newOnly]:
      check frame.persistCodeByHash(keccak256(code), code, jumpdestBitmap(code)).isOk
    check:
      frame.put(below.toOpenArray, [byte 1]).isOk
      frame.put(above, [byte 2]).isOk

    check db.migrateLegacyCode().expect("migrated") == legacyCodes.len + 1

    for code in legacyCodes & bothKeys & newOnly:
      let codeHash = keccak256(code)
      var jumpdests: seq[byte]
      check:
        not frame.hasKey(legacyContractHashKey(codeHash).toOpenArray)
        frame.get(contractCodeKey(codeHash).toOpenArray).expect("value") ==
          @[1'u8] & code & jumpdestBitmap(code)
        frame.getCodeByHash(codeHash, jumpdests).expect("code") == code
        jumpdests == jumpdestBitmap(code)
        frame.getCodeLenByHash(codeHash).expect("code len") == code.len
    check:
      frame.get(below.toOpenArray).expect("value") == [byte 1]
      frame.get(above).expect("value") == [byte 2]
      db.migrateLegacyCode().expect("migrated") == 0

  test "Nothing is migrated without legacy records":
    let
      path = createTempDir("nimbus-code-migration-", "")
      db = AristoDbRocks.newCoreDbRef(path, DbOptions.init())
      frame = db.baseTxFrame()
      code = testCode(100)
    defer:
      db.close()
      removeDir(path)

    check:
      db.migrateLegacyCode().expect("migrated") == 0
      frame.persistCodeByHash(keccak256(code), code, jumpdestBitmap(code)).isOk
      db.migrateLegacyCode().expect("migrated") == 0
      frame.getCodeByHash(keccak256(code)).expect("code") == code

  test "The memory backend is left alone":
    let
      db = newCoreDbRef(DefaultDbMemory)
      frame = db.baseTxFrame()
      code = testCode(100)
      codeHash = keccak256(code)
    defer:
      db.close()

    check:
      frame.put(legacyContractHashKey(codeHash).toOpenArray, code).isOk
      db.migrateLegacyCode().expect("migrated") == 0
      frame.get(legacyContractHashKey(codeHash).toOpenArray).expect("value") == code
      frame.getCodeByHash(codeHash).expect("code") == code
