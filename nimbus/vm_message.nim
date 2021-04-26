# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Should be considered part of another header file (e.g. vm_misc) once the
# circular computation.nim include/import dependency is solved. The problem is
# with vm_types.nim (included by message.nim) which includes computation.nim.

import
  ./vm_compile_flags

when evmc0_enabled or vm0_enabled:
  import
    ./vm/message as vmm
else:
  import
    ./vm2/message as vmm

export
  vmm.isCreate

# End
