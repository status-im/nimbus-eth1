# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  logging, constants, errors, validation, utils/header, vm / forks / frontier / vm

method computeDifficulty*(parentHeader: BlockHeader, timestamp: int): Int256 =
  validateGt(timestamp, parentHeader.timestamp, title="BlockHeader timestamp")
  let offset = parentHeader.difficulty div DIFFICULTY_ADJUSTMENT_DENOMINATOR
  # We set the minimum to the lowest of the protocol minimum and the parent
  # minimum to allow for the initial frontier *warming* period during which
  # the difficulty begins lower than the protocol minimum
  let difficultyMinimum = min(parentHeader.difficulty, DIFFICULTY_MINIMUM)
  # let test = (timestamp - parentHeader.timestamp).Int256 < FRONTIER_DIFFICULTY_ADJUSTMENT_CUTOFF
  # let baseDifficulty = max(parent.BlockHeader.difficulty + (if test: offset else: -offset), difficultyMinimum)
  # # Adjust for difficulty bomb
  # let numBombPeriods = ((parentHeader.blockNumber + 1) div BOMB_EXPONENTIAL_PERIOD) - BOMB_EXPONENTIAL_FREE_PERIODS
  # result = if numBombPeriods >= 0: max(baseDifficulty + 2.Int256 ^ numBombPeriods, DIFFICULTY_MINIMUM) else: baseDifficulty
  result = 0.Int256

method createHeaderFromParent*(parentHeader: BlockHeader): BlockHeader =
  # TODO
  result = BlockHeader()

