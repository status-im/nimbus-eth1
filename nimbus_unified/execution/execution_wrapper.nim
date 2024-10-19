# nimbus_unified
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import chronicles, std/[os, atomics], ../configs/nimbus_configs
export nimbus_configs

## log
logScope:
  topics = "Execution layer"

proc executionWrapper*(parameters: TaskParameters) =
  info "Execution wrapper:", worker = parameters.name

  while true:
    sleep(2000)
    info "looping execution"
    if isShutDownRequired.load() == true:
      break

  warn "\tExiting execution:", worker = parameters.name
