# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Backend selection for the modexp precompile (EIP-198). BoringSSL is the
## default and the faster of the two; see `execution_chain/compile_info.nim`.
##
## Note the portable backend only handles operands up to 256 bytes - see
## `modexp_portable.nim`.

{.push raises: [].}

import ../compile_info

when enable_boringssl:
  import ./modexp_boringssl
  export modexp_boringssl
else:
  import ./modexp_portable
  export modexp_portable
