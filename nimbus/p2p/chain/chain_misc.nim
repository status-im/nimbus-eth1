# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../../chain_config,
  ../../db/db_chain,
  ./chain_desc,
  chronicles,
  eth/common,
  stew/endians2,
  stint

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

func toChainFork(c: ChainConfig, number: BlockNumber): ChainFork =
  if c.mergeForkBlock.isSome and number >= c.mergeForkBlock.get:
    return MergeFork
  if number >= c.arrowGlacierBlock: ArrowGlacier
  elif number >= c.londonBlock: London
  elif number >= c.berlinBlock: Berlin
  elif number >= c.muirGlacierBlock: MuirGlacier
  elif number >= c.istanbulBlock: Istanbul
  elif number >= c.petersburgBlock: Petersburg
  elif number >= c.constantinopleBlock: Constantinople
  elif number >= c.byzantiumBlock: Byzantium
  elif number >= c.eip158Block: Spurious
  elif number >= c.eip150Block: Tangerine
  elif number >= c.daoForkBlock: DAOFork
  elif number >= c.homesteadBlock: Homestead
  else: Frontier

func getForkId*(c: Chain, n: BlockNumber): ForkID {.gcsafe.} =
  ## EIP 2364/2124
  let fork = c.db.config.toChainFork(n)
  c.forkIds[fork]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
