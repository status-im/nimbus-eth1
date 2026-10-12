# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Builds nimbus-eth2's generate_makefile from here, so that only this repo's
# "config.nims" is loaded (it sets the nimcache dir). Compiling the vendored
# file directly would also load nimbus-eth2's "config.nims", and the two clash.

include "../vendor/nimbus-eth2/tools/generate_makefile.nim"
