# Nimbus - Enumerate Eth1 forks
#
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

type
  Fork* = enum
    FkFrontier       = "Frontier"
    FkHomestead      = "Homestead"
    FkTangerine      = "Tangerine Whistle"
    FkSpurious       = "Spurious Dragon"
    FkByzantium      = "Byzantium"
    FkConstantinople = "Constantinople"
    FkPetersburg     = "Petersburg"
    FkIstanbul       = "Istanbul"
    FkBerlin         = "Berlin"
    FkLondon         = "London"
