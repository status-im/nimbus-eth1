# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  evmc/evmc

type
  EVMFork* = evmc_revision

const
  FkFrontier*       = EVMC_FRONTIER
  FkHomestead*      = EVMC_HOMESTEAD
  FkTangerine*      = EVMC_TANGERINE_WHISTLE
  FkSpurious*       = EVMC_SPURIOUS_DRAGON
  FkByzantium*      = EVMC_BYZANTIUM
  FkConstantinople* = EVMC_CONSTANTINOPLE
  FkPetersburg*     = EVMC_PETERSBURG
  FkIstanbul*       = EVMC_ISTANBUL
  FkBerlin*         = EVMC_BERLIN
  FkLondon*         = EVMC_LONDON
  FkParis*          = EVMC_PARIS
  FkShanghai*       = EVMC_SHANGHAI
  FkCancun*         = EVMC_CANCUN
  FkPrague*         = EVMC_PRAGUE
