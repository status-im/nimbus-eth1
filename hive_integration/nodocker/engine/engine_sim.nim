import
  std/times,
  ./types,
  ../sim_utils

import
  ./engine_tests,
  ./auths_tests,
  ./exchange_cap_tests,
  ./withdrawal_tests

proc combineTests(): seq[TestDesc] =
  result.add wdTestList
  result.add ecTestList
  result.add authTestList
  result.add engineTestList

let
  testList = combineTests()

proc main() =
  var stat: SimStat
  let start = getTime()

  for x in testList:
    let status = if x.run(x.spec):
                   TestStatus.OK
                 else:
                   TestStatus.Failed
    stat.inc(x.name, status)

  let elpd = getTime() - start
  print(stat, elpd, "engine")
  echo stat

main()
