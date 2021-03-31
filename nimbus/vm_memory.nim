# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Wrapper for a wrapper -- lol

# At the moment, this header file interface is only used for testing, so it
# might be worth merging it into a vm_internals.nim (or so) header file.
import
  ./vm/memory as vmm

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

# End
