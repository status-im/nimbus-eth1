import unittest2, strutils, tables, os, json,
  ../nimbus/utils/difficulty, stint, times,
  eth/common, test_helpers, stew/byteutils

type
  Tester = object
    parentTimestamp: int64
    parentDifficulty: Uint256
    parentUncles: Hash256
    currentTimestamp: int64
    currentBlockNumber: Uint256
    currentDifficulty: Uint256

  Tests = Table[string, Tester]

proc hexOrInt64(data: JsonNode, key: string, hex: static[bool]): int64 =
  when hex:
    getHexadecimalInt data[key]
  else:
    int64(parseInt data[key].getStr)

proc hexOrInt256(data: JsonNode, key: string, hex: static[bool]): Uint256 =
  when hex:
    UInt256.fromHex data[key].getStr
  else:
    parse(data[key].getStr, Uint256)

proc parseTests(name: string, hex: static[bool]): Tests =
  let fileName = "tests" / "fixtures" / "DifficultyTests" / "difficulty" & name & ".json"
  let fixtures = parseJSON(readFile(fileName))

  result = initTable[string, Tester]()
  var t: Tester
  for title, data in fixtures:
    t.parentTimestamp = hexOrInt64(data, "parentTimestamp", hex)
    t.parentDifficulty = hexOrInt256(data, "parentDifficulty", hex)
    hexToByteArray(data["parentUncles"].getStr, t.parentUncles.data)
    t.currentTimestamp = hexOrInt64(data, "currentTimestamp", hex)
    t.currentBlockNumber = hexOrInt256(data, "currentBlockNumber", hex)
    t.currentDifficulty = hexOrInt256(data, "currentDifficulty", hex)
    result[title] = t

template runTests(name: string, hex: bool, calculator: typed) =
  test name:
    let data = parseTests(name, hex)
    for title, t in data:
      var p = BlockHeader(
        difficulty: t.parentDifficulty,
        timestamp: times.fromUnix(t.parentTimestamp),
        blockNumber: t.currentBlockNumber - 1,
        ommersHash: t.parentUncles)

      let diff = calculator(times.fromUnix(t.currentTimeStamp), p)
      check diff == t.currentDifficulty

proc difficultyMain*() =
  suite "DifficultyTest":
    runTests("Byzantium", true, calcDifficultyByzantium)
    runTests("Constantinople", true, calcDifficultyConstantinople)
    runTests("Homestead", true, calcDifficultyHomestead)
    runTests("Frontier", true, calcDifficultyFrontier)
    runTests("", false, calcDifficulty)

when isMainModule:
  difficultyMain()
