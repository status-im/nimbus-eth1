# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# The following should really go into vm_types once the circular computation.nim
# include/import dependency is solved. The problem is with vm_types.nim which
# includes computation.nim.
when defined(evmc_enabled) or not defined(vm2_enabled):
  import
    ./vm/interpreter/vm_forks as vmf
else:
  import
    ./vm2/interpreter/forks_list as vmf

export
  vmf.Fork

when defined(evmc_enabled) or not defined(vm2_enabled):
  import
    ./vm/interpreter/opcode_values as vmo
else:
  import
    ./vm2/interpreter/op_codes as vmo

export
  vmo.Op
  
# End
