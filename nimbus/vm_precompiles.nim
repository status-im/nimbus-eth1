# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

when defined(evmc_enabled) or not defined(vm2_enabled):
  import
    ./vm/precompiles as vmp
else:
  import
    ./vm2/precompiles as vmp

export
  vmp.PrecompileAddresses,
  vmp.activePrecompiles,
  vmp.blake2bf,
  vmp.blsG1Add,
  vmp.blsG1Mul,
  vmp.blsG1MultiExp,
  vmp.blsG2Add,
  vmp.blsG2Mul,
  vmp.blsG2MultiExp,
  vmp.blsMapG1,
  vmp.blsMapG2,
  vmp.blsPairing,
  vmp.bn256ecAdd,
  vmp.bn256ecMul,
  vmp.ecRecover,
  vmp.execPrecompiles,
  vmp.identity,
  vmp.modExp,
  vmp.ripemd160,
  vmp.sha256,
  vmp.simpleDecode

# End
