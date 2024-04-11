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
  else:
    "nimvm"

const
  VmName* = vmName()
  warningMsg = block:
    var rc = "*** Compiling with " & VmName
    when defined(eth66_enabled):
      rc &= ", eth/66"
    when defined(eth67_enabled):
      rc &= ", eth/67"
    when defined(eth68_enabled):
      rc &= ", eth/68"
    when defined(chunked_rlpx_enabled):
      rc &= ", chunked-rlpx"
    when defined(boehmgc):
      rc &= ", boehm/gc"
    rc &= " enabled"
    rc

{.warning: warningMsg.}

{.used.}
