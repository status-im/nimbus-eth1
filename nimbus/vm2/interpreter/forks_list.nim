# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## List of known Etheroum forks
## ============================
##
## See `here <../../ex/vm/interpreter/forks_list.html>`_ for an
## overview.
##
## Assumptions on the naming of the fork list:
##  * each symbol start with the prefix "Fk"
##  * the first word of the prettified text representaion is the same
##    text as the one following the "Fk" in the symbol name (irrespective
##    of character case.)

import
  strutils

type
  Fork* = enum
    FkFrontier = "frontier"
    FkHomestead = "homestead"
    FkTangerine = "tangerine whistle"
    FkSpurious = "spurious dragon"
    FkByzantium = "byzantium"
    FkConstantinople = "constantinople"
    FkPetersburg = "petersburg"
    FkIstanbul = "istanbul"
    FkBerlin = "berlin"

proc toSymbolName*(fork: Fork): string =
  ## Given a `fork` argument, print the symbol name so that it can be used
  ## in a macro statement.
  "Fk" & ($fork).split(' ')[0]

# End
