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
const BaseGasCosts*: GasCosts = [
  GasZero:                     0'i64,
  GasBase:                     2,
  GasVeryLow:                  3,
  GasLow:                      5,
  GasMid:                      8,
  GasHigh:                     10,
  GasSload:                    50,     # Changed to 200 in Tangerine (EIP150)
  GasJumpDest:                 1,
  GasSset:                     20_000,
  GasSreset:                   5_000,
  GasExtCode:                  20,
  GasCoinbase:                 20,
  GasSelfDestruct:             0,      # Changed to 5000 in Tangerine (EIP150)
  GasInHandler:                0,      # to be calculated in handler
  GasRefundSclear:             15000,

  GasBalance:                  20,     # Changed to 400 in Tangerine (EIP150)
  GasCall:                     40,     # Changed to 700 in Tangerine (EIP150)
  GasExp:                      10,
  GasSHA3:                     30
]

proc tangerineGasCosts(baseCosts: GasCosts): GasCosts =

  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-150.md
  result = baseCosts
  result[GasSload]        = 200
  result[GasSelfDestruct] = 5000
  result[GasBalance]      = 400
  result[GasCall]         = 40

const TangerineGasCosts* = BaseGasCosts.tangerineGasCosts
