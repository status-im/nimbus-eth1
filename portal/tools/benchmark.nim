# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

from std/stats import RunningStat, mean, push, standardDeviationS
from std/strformat import `&`
from std/times import cpuTime

export RunningStat

template withTimer*(stats: var RunningStat, body: untyped) =
  let start = cpuTime()

  block:
    body

  let stop = cpuTime()
  stats.push stop - start

proc printTimers*[Timers: enum](timers: array[Timers, RunningStat]) =
  func fmtTime(t: float): string =
    &"{t * 1000 :>12.3f}, "

  echo "All timings are in ms and are cpu time."
  echo &"{\"Average\" :>12}, {\"StdDev\" :>12}, {\"Min\" :>12}, " &
    &"{\"Max\" :>12}, {\"Samples\" :>12}, {\"Test\" :>12} "

  for t in Timers:
    echo fmtTime(timers[t].mean),
      fmtTime(timers[t].standardDeviationS),
      fmtTime(timers[t].min),
      fmtTime(timers[t].max),
      &"{timers[t].n :>12}, ",
      $t
