# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Block Miner
## ============================
##

import
  std/[hashes, sequtils, strutils, times],
  ../ec_recover,
  ../utils_defs,
  ./tx_info,
  eth/[common, common/transaction, keys],
  stew/results,
  stint

{.push raises: [Defect].}

type
  TxMiner* = object of RootObj ##\
    ## ...
    signer: PrivateKey  ## Signmer key

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc utcTime: Time =
  getTime().utc.toTime

# ------------------------------------------------------------------------------
# Public functions, Constructor
# ------------------------------------------------------------------------------

proc init*(tm: var TxMiner; signer: PrivateKey) =
  ## Constructor
  tm.signer = signer

proc init*(T: type TxMiner; signer: PrivateKey): T =
  ## Constructor
  result.init(signer)
  
# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
