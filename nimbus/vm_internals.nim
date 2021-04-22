# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# At the moment, this header file interface is only used for testing.

when defined(evmc_enabled) or not defined(vm2_enabled):
  import
    ./vm/memory as vmm
else:
  import
    ./vm2/memory as vmm
  
export
  vmm.Memory,
  vmm.extend,
  vmm.len,
  vmm.newMemory,
  vmm.read,
  vmm.write

when defined(evmc_enabled):
  export
    vmm.readPtr


when defined(evmc_enabled) or not defined(vm2_enabled):
  import
    ./vm/interpreter/utils/utils_numeric as vmn
else:
  import
    ./vm2/interpreter/utils/utils_numeric as vmn

  
export
  vmn.GasNatural,
  vmn.calcMemSize,
  vmn.ceil32,
  vmn.cleanMemRef,
  vmn.log2,
  vmn.log256,
  vmn.rangeToPadded,
  vmn.rangeToPadded2,
  vmn.safeInt,
  vmn.setSign,
  vmn.toInt,
  vmn.wordCount


# Wrapping the wrapper -- lol
when defined(evmc_enabled) or not defined(vm2_enabled):
  import
    ./vm/interpreter as vmi
else:
  import
    ./vm2/interpreter as vmi
    
export
  vmi

# End
