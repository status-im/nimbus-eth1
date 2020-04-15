# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import stint, eth/common/eth_types

type
  Fork* = enum
    FkFrontier,
    FkHomestead,
    FkTangerine,
    FkSpurious,
    FkByzantium,
    FkConstantinople,
    FkPetersburg,
    FkIstanbul

proc `$`*(fork: Fork): string =
  case fork
  of FkFrontier: result = "Frontier"
  of FkHomestead: result = "Homestead"
  of FkTangerine: result = "Tangerine Whistle"
  of FkSpurious: result = "Spurious Dragon"
  of FkByzantium: result = "Byzantium"
  of FkConstantinople: result = "Constantinople"
  of FkPetersburg: result = "Petersburg"
  of FkIstanbul: result = "Istanbul"
