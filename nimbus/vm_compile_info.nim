# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

func vmName(): string =
  when defined(evmc_enabled):
    "evmc"
  elif defined(vm2_enabled):
    "vm2"
  else:
    "nimvm"

const
  VmName* = vmName()
  warningMSg = block:
    const chronicles_colors {.strdefine.} = "*"
    var rc = "*** Compiling with " & VmName
    when defined(eth65_enabled):
      rc &= ", eth/65"
    else:
      rc &= ", eth/66"
    when chronicles_colors in ["no", "0", "off", "false", "none"]:
      rc &= ", decolourised-logging"
    rc &= " enabled"
    rc

{.warning: warningMsg.}

{.used.}
