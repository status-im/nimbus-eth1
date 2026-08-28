# Nimbus
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}
{.used.}

const chronicles_line_numbers {.strdefine.} = "0"
when chronicles_line_numbers notin ["0", "off"]:
  {.hint: "*** Compiling with logger line numbers enabled".}

const enable_mcl_lib* {.booldefine.} = true
when enable_mcl_lib:
  {.hint: "*** Compiling with mcl library".}

# BoringSSL backs the sha256, P256VERIFY and modexp precompiles. It is the
# fastest option on a hosted target and stays the default.
#
# Disabling it selects portable, freestanding implementations instead.
# TODO: modexp has no such implementation yet and uses BoringSSL either way.
const enable_boringssl* {.booldefine.} = true
when not enable_boringssl:
  {.hint: "*** Compiling without BoringSSL (portable precompile backends)".}
