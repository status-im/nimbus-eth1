# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ./vm_compile_flags

when evmc2_enabled:
  {.warning: "*** Compiling with EVMC2 enabled".}

elif vm2_enabled:
  {.warning: "*** Compiling with VM2 enabled".}

elif evmc0_enabled:
  {.warning: "*** Compiling with EVMC enabled".}

elif vm0_enabled:
  {.warning: "*** Compiling with native NIM VM enabled".}

else:
  {.error: "Ooops - unsupported configuration".}

{.used.}
# End
