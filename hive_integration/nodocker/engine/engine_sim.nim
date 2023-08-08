import
  "."/[types, test_env],
  ../sim_utils

import
  ./engine_tests,
  ./auths_tests,
  ./exchange_cap_tests

proc combineTests(): seq[TestSpec] =
  result = @engineTestList
  result.add @authTestList

const testList = combineTests()

proc main() =
  var stat: SimStat
  let start = getTime()

  for x in testList:
    var t = setupELClient(x.chainFile, x.enableAuth)
    t.setRealTTD(x.ttd)
    if x.slotsToFinalized != 0:
      t.slotsToFinalized(x.slotsToFinalized)
    if x.slotsToSafe != 0:
      t.slotsToSafe(x.slotsToSafe)
    let status = x.run(t)
    t.stopELClient()
    stat.inc(x.name, status)

  for x in exchangeCapTestList:
    let env = setupELClient(x.conf)
    let status = x.run(env)
    env.stopELClient()
    stat.inc(x.name, status)

  let elpd = getTime() - start
  print(stat, elpd, "engine")
  echo stat

main()
