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
    FkThawing,
    FkHomestead,
    FkDao,
    FkTangerine,
    FkSpurious,
    FkByzantium,
    FkConstantinople,
    FkPetersburg,
    FkIstanbul,
    FkGlacierMuir

const
  forkBlocks*: array[Fork, BlockNumber] = [
    FkFrontier:               1.toBlockNumber, # 30/07/2015 19:26:28
    FkThawing:          200_000.toBlockNumber, # 08/09/2015 01:33:09
    FkHomestead:      1_150_000.toBlockNumber, # 14/03/2016 20:49:53
    FkDao:            1_920_000.toBlockNumber, # 20/07/2016 17:20:40
    FkTangerine:      2_463_000.toBlockNumber, # 18/10/2016 17:19:31
    FkSpurious:       2_675_000.toBlockNumber, # 22/11/2016 18:15:44
    FkByzantium:      4_370_000.toBlockNumber, # 16/10/2017 09:22:11
    FkConstantinople: 7_280_000.toBlockNumber, # Never Occured in MainNet
    FkPetersburg:     7_280_000.toBlockNumber, # 28/02/2019 07:52:04
    FkIstanbul:       9_069_000.toBlockNumber, # 08/12/2019 12:25:09
    FkGlacierMuir:    9_200_000.toBlockNumber  # 02/01/2020 08:30:49
  ]

proc toFork*(blockNumber: BlockNumber): Fork =

  # TODO: uint256 comparison is probably quite expensive
  #       hence binary search is probably worth it earlier than
  #       linear search

  # TODO: all toFork usage currently incurs comparison to get the fork and then another comparison to
  #       go to the ultimate needed result.

  # Genesis block 0 also uses the Frontier code path
  if blockNumber < forkBlocks[FkThawing]:     FkFrontier
  elif blockNumber < forkBlocks[FkHomestead]: FkThawing
  elif blockNumber < forkBlocks[FkDao]:       FkHomestead
  elif blockNumber < forkBlocks[FkTangerine]: FkDao
  elif blockNumber < forkBlocks[FkSpurious]:  FkTangerine
  elif blockNumber < forkBlocks[FkByzantium]: FkSpurious
  elif blockNumber < forkBlocks[FkConstantinople]: FkByzantium
  elif blockNumber < forkBlocks[FkIstanbul]: FkPetersburg
  elif blockNumber < forkBlocks[FkGlacierMuir]: FkIstanbul
  else: FkGlacierMuir

proc `$`*(fork: Fork): string =
  case fork
  of FkFrontier: result = "Frontier"
  of FkThawing: result = "Thawing"
  of FkHomestead: result = "Homestead"
  of FkDao: result = "Dao"
  of FkTangerine: result = "Tangerine Whistle"
  of FkSpurious: result = "Spurious Dragon"
  of FkByzantium: result = "Byzantium"
  of FkConstantinople: result = "Constantinople"
  of FkPetersburg: result = "Petersburg"
  of FkIstanbul: result = "Istanbul"
  of FkGlacierMuir: result = "Glacier Muir"
