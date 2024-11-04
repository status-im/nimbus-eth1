# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[strutils, tables, os, json],
  unittest2,
  stew/byteutils,
  ../nimbus/core/pow/difficulty,
  ../nimbus/constants,
  ../nimbus/common/common,
  ./test_helpers

type
  Tester = object
    parentTimestamp: int64
    parentDifficulty: UInt256
    parentUncles: Hash32
    currentTimestamp: int64
    currentBlockNumber: uint64
    currentDifficulty: UInt256

  Tests = Table[string, Tester]

const
  inputPath = "tests" / "fixtures" / "eth_tests" / "DifficultyTests"

proc hexOrInt64(data: JsonNode, key: string, hex: static[bool]): int64 =
  when hex:
    getHexadecimalInt data[key]
  else:
    int64(parseInt data[key].getStr)

proc hexOrInt256(data: JsonNode, key: string, hex: static[bool]): UInt256 =
  when hex:
    UInt256.fromHex data[key].getStr
  else:
    parse(data[key].getStr, UInt256)

proc parseHash(data: string): Hash32 =
  case data
  of "0x00": result = EMPTY_UNCLE_HASH
  of "0x01": result.data[0] = 1.byte
  else:
    doAssert(false, "invalid uncle hash")

proc parseTests(testData: JsonNode): Tests =
  const hex = true
  result = Table[string, Tester]()
  var t: Tester
  for title, data in testData:
    t.parentTimestamp = hexOrInt64(data, "parentTimestamp", hex)
    t.parentDifficulty = hexOrInt256(data, "parentDifficulty", hex)
    let pu = data.fields.getOrDefault("parentUncles")
    if pu.isNil:
      t.parentUncles = EMPTY_UNCLE_HASH
    else:
      t.parentUncles = parseHash(pu.getStr)
    t.currentTimestamp = hexOrInt64(data, "currentTimestamp", hex)
    t.currentBlockNumber = uint64 hexOrInt64(data, "currentBlockNumber", hex)
    t.currentDifficulty = hexOrInt256(data, "currentDifficulty", hex)
    result[title] = t

proc calculator(revision: string, timestamp: EthTime, header: Header): DifficultyInt =
  case revision
  of "Homestead": result = calcDifficultyHomestead(timestamp, header)
  of "GrayGlacier": result = calcDifficultyGrayGlacier(timestamp, header)
  of "Frontier": result = calcDifficultyFrontier(timestamp, header)
  of "Berlin": result = calcDifficultyMuirGlacier(timestamp, header)
  of "Constantinople": result = calcDifficultyConstantinople(timestamp, header)
  of "Byzantium": result = calcDifficultyByzantium(timestamp, header)
  of "ArrowGlacier": result = calcDifficultyArrowGlacier(timestamp, header)
  else:
    doAssert(false, "unknown revision: " & revision)

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus) =
  var fixture: JsonNode
  for _, child in fixtures:
    fixture = child
    break

  for revision, child in fixture:
    if revision == "_info":
      continue

    let tests = parseTests(child)

    for title, t in tests:
      let p = Header(
        difficulty : t.parentDifficulty,
        timestamp  : EthTime(t.parentTimestamp),
        number     : t.currentBlockNumber - 1,
        ommersHash : t.parentUncles
      )

      let timestamp = EthTime(t.currentTimestamp)

      let diff = calculator(revision, timestamp, p)
      check diff == t.currentDifficulty

template runTest() =
  var filenames: seq[string] = @[]
  for filename in walkDirRec(inputPath):
    if not filename.endsWith(".json"):
      continue
    filenames.add filename

  doAssert(filenames.len > 0)

  for fname in filenames:
    let filename = fname
    test fname.substr(inputPath.len + 1):
      let fixtures = parseJson(readFile(filename))
      testFixture(fixtures, testStatusIMPL)

proc difficultyMain*() =
  suite "DifficultyTest":
    runTest()

when isMainModule:
  difficultyMain()
