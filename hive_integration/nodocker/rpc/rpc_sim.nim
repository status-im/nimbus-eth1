# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[times],
  chronos,
  taskpools,
  "."/[rpc_tests, test_env],
  ../sim_utils

proc runRpcTest() =
  var stat: SimStat
  let taskPool = Taskpool.new()
  let start = getTime()
  for x in testList:
    try:
      let env = setupEnv(taskPool)
      let status = waitFor x.run(env)
      env.stopEnv()
      stat.inc(x.name, status)
    except ValueError as ex:
      stat.inc(x.name, TestStatus.Failed)
      echo ex.msg

  let elpd = getTime() - start
  print(stat, elpd, "rpc")


runRpcTest()
