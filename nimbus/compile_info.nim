# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ./db/core_db/base/base_config,
  ./db/ledger/base/base_config

func vmName(): string =
  when defined(evmc_enabled):
    "evmc"
  else:
    "nimvm"

const
  chronicles_line_numbers {.strdefine.} = "0"
  VmName* = vmName()
  warningMsg = block:
    var rc = "*** Compiling with " & VmName
    if chronicles_line_numbers notin ["0", "off"]:
      rc &= ", logger line numbers"
    when defined(boehmgc):
      rc &= ", boehm/gc"
    when 0 < coreDbBaseConfigExtras.len:
       rc &= ", " & coreDbBaseConfigExtras
    when 0 < ledgerBaseConfigExtras.len:
       rc &= ", " & ledgerBaseConfigExtras
    rc &= " enabled"
    rc

{.warning: warningMsg.}

{.used.}
