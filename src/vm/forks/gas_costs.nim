# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stint, ../../types

# TODO: Make that computation at compile-time.
#       Go-Ethereum uses pure uint64 for gas computation
let BaseGasCosts*: GasCosts = [
  GasZero:                     0.u256,
  GasBase:                     2.u256,
  GasVeryLow:                  3.u256,
  GasLow:                      5.u256,
  GasMid:                      8.u256,
  GasHigh:                     10.u256,
  GasSload:                    50.u256,     # Changed to 200 in Tangerine (EIP150)
  GasJumpDest:                 1.u256,
  GasSset:                     20_000.u256,
  GasSreset:                   5_000.u256,
  GasExtCode:                  20.u256,
  GasCoinbase:                 20.u256,
  GasSelfDestruct:             0.u256,      # Changed to 5000 in Tangerine (EIP150)
  GasInHandler:                0.u256,      # to be calculated in handler
  GasRefundSclear:             15000.u256,

  GasBalance:                  20.u256,     # Changed to 400 in Tangerine (EIP150)
  GasCall:                     40.u256,     # Changed to 700 in Tangerine (EIP150)
  GasExp:                      10.u256,
  GasSHA3:                     30.u256
]

proc tangerineGasCosts(baseCosts: GasCosts): GasCosts =

  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-150.md
  result = baseCosts
  result[GasSload]        = 200.u256
  result[GasSelfDestruct] = 5000.u256
  result[GasBalance]      = 20.u256
  result[GasCall]         = 40.u256

let TangerineGasCosts* = BaseGasCosts.tangerineGasCosts
