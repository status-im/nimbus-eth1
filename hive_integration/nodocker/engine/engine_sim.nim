# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/times,
  chronicles,
  results,
  ./types,
  ../sim_utils,
  ../../../nimbus/core/eip4844

import
  ./engine_tests,
  ./auths_tests,
  ./exchange_cap_tests,
  ./withdrawal_tests,
  ./cancun_tests

proc combineTests(): seq[TestDesc] =
  result.add wdTestList
  result.add ecTestList
  result.add authTestList
  result.add engineTestList
  result.add cancunTestList

let
  testList = combineTests()

proc main() =
  var stat: SimStat
  let start = getTime()

  let res = loadKzgTrustedSetup()
  if res.isErr:
    fatal "Cannot load baked in Kzg trusted setup", msg=res.error
    quit(QuitFailure)

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
