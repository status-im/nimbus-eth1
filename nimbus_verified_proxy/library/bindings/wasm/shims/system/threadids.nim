# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# NOTE: THIS IS A SHIM

when defined(emscripten):
  proc getThreadId*(): int =
    ## Gets the ID of the currently running thread.
    ## Emscripten (single-threaded WASM): always returns 1.
    1

else:
  import threadids
