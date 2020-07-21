import
  times, eth/common, stint,
  ../constants, ../config

const
  ExpDiffPeriod           = 100000.u256
  DifficultyBoundDivisorU = 2048.u256
  DifficultyBoundDivisorI = 2048.i256
  DurationLimit           = 13
  MinimumDifficultyU      = 131072.u256
  MinimumDifficultyI      = 131072.i256
  bigOne = 1.u256
  bigTwo = 2.u256
  bigNine = 9.i256
  bigOneI = 1.i256
  bigTwoI = 2.i256
  bigTenI = 10.i256
  bigMin99 = -99.i256

template difficultyBomb(periodCount: Uint256) =
  periodCount = periodCount div ExpDiffPeriod

  if periodCount > bigOne:
    # diff = diff + 2^(periodCount - 2)
    var expDiff = periodCount - bigTwo
    expDiff = bigTwo.pow(expDiff)

    diff = diff + expDiff
    diff = max(diff, MinimumDifficultyU)

# calcDifficultyFrontier is the difficulty adjustment algorithm. It returns the
# difficulty that a new block should have when created at time given the parent
# block's time and difficulty. The calculation uses the Frontier rules.
func calcDifficultyFrontier*(timeStamp: EthTime, parent: BlockHeader): DifficultyInt =
  var diff: DifficultyInt
  let adjust  = parent.difficulty div DifficultyBoundDivisorU
  let time = timeStamp.toUnix()
  let parentTime = parent.timeStamp.toUnix()

  if time - parentTime < DurationLimit:
    diff = parent.difficulty + adjust
  else:
    diff = parent.difficulty - adjust

  diff = max(diff, MinimumDifficultyU)

  var periodCount = parent.blockNumber + bigOne
  difficultyBomb(periodCount)
  result = diff

# calcDifficultyHomestead is the difficulty adjustment algorithm. It returns
# the difficulty that a new block should have when created at time given the
# parent block's time and difficulty. The calculation uses the Homestead rules.
func calcDifficultyHomestead*(timeStamp: EthTime, parent: BlockHeader): DifficultyInt =
  # https:#github.com/ethereum/EIPs/blob/master/EIPS/eip-2.md
  # algorithm:
  # diff = (parent_diff +
  #         (parent_diff / 2048 * max(1 - (block_timestamp - parent_timestamp) # 10, -99))
  #        ) + 2^(periodCount - 2)

  let time = timeStamp.toUnix()
  let parentTime = parent.timeStamp.toUnix()
  let parentDifficulty = cast[Int256](parent.difficulty)

  # 1 - (block_timestamp - parent_timestamp) # 10
  var x = (time - parentTime).i256
  x = x div bigTenI
  x = bigOneI - x

  # max(1 - (block_timestamp - parent_timestamp) # 10, -99)
  x = max(x, bigMin99)

  # (parent_diff + parent_diff # 2048 * max(1 - (block_timestamp - parent_timestamp) # 10, -99))
  var y = parentDifficulty div DifficultyBoundDivisorI
  x = y * x
  x = parentDifficulty + x

  # minimum difficulty can ever be (before exponential factor)
  var diff = cast[Uint256](max(x, MinimumDifficultyI))

  # for the exponential factor
  var periodCount = parent.blockNumber + bigOne
  difficultyBomb(periodCount)

  result = diff

# makeDifficultyCalculator creates a difficultyCalculator with the given bomb-delay.
# the difficulty is calculated with Byzantium rules, which differs from Homestead in
# how uncles affect the calculation
func makeDifficultyCalculator(bombDelay: static[int], timeStamp: EthTime, parent: BlockHeader): DifficultyInt =
  # Note, the calculations below looks at the parent number, which is 1 below
  # the block number. Thus we remove one from the delay given
  const
    bombDelayFromParent = bombDelay.u256 - bigOne

  # https:#github.com/ethereum/EIPs/issues/100.
  # algorithm:
  # diff = (parent_diff +
  #         (parent_diff / 2048 * max((2 if len(parent.uncles) else 1) - ((timestamp - parent.timestamp) # 9), -99))
  #        ) + 2^(periodCount - 2)

  let time = timeStamp.toUnix()
  let parentTime = parent.timeStamp.toUnix()
  let parentDifficulty = cast[Int256](parent.difficulty)

  # (2 if len(parent_uncles) else 1) - (block_timestamp - parent_timestamp) # 9
  var x = (time - parentTime).i256
  x = x div bigNine

  if parent.ommersHash == EMPTY_UNCLE_HASH:
    x = bigOneI - x
  else:
    x = bigTwoI - x

  # max((2 if len(parent_uncles) else 1) - (block_timestamp - parent_timestamp) # 9, -99)
  x = max(x, bigMin99)

  # parent_diff + (parent_diff / 2048 * max((2 if len(parent.uncles) else 1) - ((timestamp - parent.timestamp) # 9), -99))
  var y = parentDifficulty div DifficultyBoundDivisorI
  x = y * x
  x = parentDifficulty + x

  # minimum difficulty can ever be (before exponential factor)
  var diff = cast[Uint256](max(x, MinimumDifficultyI))

  # calculate a fake block number for the ice-age delay
  # Specification: https:#eips.ethereum.org/EIPS/eip-1234
  var periodCount: Uint256
  if parent.blockNumber >= bombDelayFromParent:
    periodCount = parent.blockNumber - bombDelayFromParent

  difficultyBomb(periodCount)

  result = diff

template calcDifficultyByzantium*(timeStamp: EthTime, parent: BlockHeader): DifficultyInt =
  makeDifficultyCalculator(3_000_000, timeStamp, parent)

template calcDifficultyConstantinople*(timeStamp: EthTime, parent: BlockHeader): DifficultyInt =
  makeDifficultyCalculator(5_000_000, timeStamp, parent)

template calcDifficultyMuirGlacier*(timeStamp: EthTime, parent: BlockHeader): DifficultyInt =
  makeDifficultyCalculator(9_000_000, timeStamp, parent)

func calcDifficulty*(c: ChainConfig, timeStamp: EthTime, parent: BlockHeader): DifficultyInt =
  let next = parent.blockNumber + bigOne
  if next >= c.muirGlacierBlock:
    result = calcDifficultyMuirGlacier(timeStamp, parent)
  elif next >= c.constantinopleBlock:
    result = calcDifficultyConstantinople(timeStamp, parent)
  elif next >= c.byzantiumBlock:
    result = calcDifficultyByzantium(timeStamp, parent)
  elif next >= c.homesteadBlock:
    result = calcDifficultyHomestead(timeStamp, parent)
  else:
    result = calcDifficultyFrontier(timeStamp, parent)
