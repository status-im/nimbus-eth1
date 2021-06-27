# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

##
## Tuoole & Utils for Clique PoA Consensus Protocol
## ================================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##
## Caveat: Not supporting RLP serialisation encode()/decode()
##

import
  std/[algorithm, strformat, times],
  ../../chain_config,
  ../../config,
  ../../constants,
  ../../db/db_chain,
  ../../errors,
  ../../forks,
  ../../utils,
  ./clique_defs,
  eth/[common, rlp],
  stew/[objects, results],
  stint

type
  EthSortOrder* = enum
    EthDescending = SortOrder.Descending.ord
    EthAscending = SortOrder.Ascending.ord

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc gasLimitBounds(limit: GasInt): (GasInt, GasInt) =
  ## See also utils.header.gasLimitBounds()
  let
    bndRange = limit div GAS_LIMIT_ADJUSTMENT_FACTOR
    upperBound = if GAS_LIMIT_MAXIMUM - bndRange < limit: GAS_LIMIT_MAXIMUM
                 else: limit + bndRange
    lowerBound = max(GAS_LIMIT_MINIMUM, limit - bndRange)

  return (lowerBound, upperBound)

proc validateGasLimit(header: BlockHeader; limit: GasInt): CliqueResult =
  let (lowBound, highBound) = gasLimitBounds(limit)
  if header.gasLimit < lowBound:
    return err((errCliqueGasLimitTooLow,""))
  if highBound < header.gasLimit:
    return err((errCliqueGasLimitTooHigh,""))
  return ok()

func zeroItem[T](t: typedesc[T]): T {.inline.} =
  discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc isZero*[T: EthAddress|Hash256|Duration](a: T): bool =
  ## `true` if `a` is all zero
  a == zeroItem(T)

proc sorted*(e: openArray[EthAddress]; order = EthAscending): seq[EthAddress] =
  proc eCmp(x, y: EthAddress): int =
    for n in 0 ..< x.len:
      if x[n] < y[n]:
        return -1
      elif y[n] < x[n]:
        return 1
  e.sorted(cmp = eCmp, order = order.SortOrder)


proc cliqueResultErr*(w: CliqueError): CliqueResult =
  ## Return error result (syntactic sugar)
  err(w)


proc extraDataAddresses*(extraData: Blob): seq[EthAddress] =
  ## Extract signer addresses from extraData header field

  proc toEthAddress(a: openArray[byte]; start: int): EthAddress {.inline.} =
    toArray(EthAddress.len, a[start ..< start + EthAddress.len])

  if EXTRA_VANITY + EXTRA_SEAL < extraData.len and
      ((extraData.len - (EXTRA_VANITY + EXTRA_SEAL)) mod EthAddress.len) == 0:
    var addrOffset = EXTRA_VANITY
    while addrOffset + EthAddress.len <= extraData.len - EXTRA_SEAL:
      result.add extraData.toEthAddress(addrOffset)
      addrOffset += EthAddress.len


proc getBlockHeaderResult*(c: BaseChainDB;
                           number: BlockNumber): Result[BlockHeader,void] {.
                             gcsafe, raises: [Defect,RlpError].} =
  ## Slightly re-phrased dbChain.getBlockHeader(..) command
  var header: BlockHeader
  if c.getBlockHeader(number, header):
    return ok(header)
  err()


# core/types/block.go(343): func (b *Block) WithSeal(header [..]
proc withHeader*(b: EthBlock; header: BlockHeader): EthBlock =
  ## New block with the data from `b` but the header replaced with the
  ## argument one.
  EthBlock(
    header: header,
    txs:    b.txs,
    uncles: b.uncles)

# consensus/misc/forks.go(30): func VerifyForkHashes(config [..]
proc verifyForkHashes*(c: var ChainConfig; header: BlockHeader): CliqueResult {.
                       gcsafe, raises: [Defect,ValueError].} =
  ## Verify that blocks conforming to network hard-forks do have the correct
  ## hashes, to avoid clients going off on different chains.

  # If the homestead reprice hash is set, validate it
  if c.eip150Block.isZero or c.eip150Block != header.blockNumber:
    return ok()

  let hash = header.hash
  if c.eip150Hash.isZero or c.eip150Hash == hash:
    return ok()

  return err((errCliqueGasRepriceFork,
              &"Homestead gas reprice fork: have {c.eip150Hash}, want {hash}"))

proc validateGasLimit*(c: var BaseChainDB; header: BlockHeader): CliqueResult {.
                       gcsafe, raises: [Defect,RlpError,BlockNotFound].} =
  ## See also private function p2p.validate.validateGasLimit()
  let parent = c.getBlockHeader(header.parentHash)
  header.validateGasLimit(parent.gasLimit)

# ------------------------------------------------------------------------------
# Eip 1559 support
# ------------------------------------------------------------------------------

# params/config.go(450): func (c *ChainConfig) IsLondon(num [..]
proc isLondonOrLater*(c: var ChainConfig; number: BlockNumber): bool =
  ## FIXME: London is not defined yet, will come after Berlin
  FkBerlin < c.toFork(number)

# consensus/misc/eip1559.go(55): func CalcBaseFee(config [..]
proc calc1599BaseFee*(c: var ChainConfig; parent: BlockHeader): UInt256 =
  ## calculates the basefee of the header.

  # If the current block is the first EIP-1559 block, return the
  # initial base fee.
  if not c.isLondonOrLater(parent.blockNumber):
    return EIP1559_INITIAL_BASE_FEE

  let parentGasTarget = parent.gasLimit div EIP1559_ELASTICITY_MULTIPLIER

  # If the parent gasUsed is the same as the target, the baseFee remains
  # unchanged.
  if parent.gasUsed == parentGasTarget:
    return parent.baseFee

  let parentGasDenom = parentGasTarget.u256 *
                         EIP1559_BASE_FEE_CHANGE_DENOMINATOR.u256

  # baseFee is an Option[T]
  let parentBaseFee  = parent.baseFee

  if parentGasTarget < parent.gasUsed:
    # If the parent block used more gas than its target, the baseFee should
    # increase.
    let
      gasUsedDelta = (parent.gasUsed - parentGasTarget).u256
      baseFeeDelta = (parentBaseFee * gasUsedDelta) div parentGasDenom

    return parentBaseFee + max(baseFeeDelta, 1.u256)

  else:
    # Otherwise if the parent block used less gas than its target, the
    # baseFee should decrease.
    let
      gasUsedDelta = (parentGasTarget - parent.gasUsed).u256
      baseFeeDelta = (parentBaseFee * gasUsedDelta) div parentGasDenom

    return max(parentBaseFee - baseFeeDelta, 0.u256)


# consensus/misc/eip1559.go(32): func VerifyEip1559Header(config [..]
proc verify1559Header*(c: var ChainConfig;
                       parent, header: BlockHeader): CliqueResult {.
                         gcsafe, raises: [Defect,ValueError].} =
  ## Verify that the gas limit remains within allowed bounds
  let limit = if c.isLondonOrLater(parent.blockNumber):
                parent.gasLimit
              else:
                parent.gasLimit * EIP1559_ELASTICITY_MULTIPLIER
  let rc = header.validateGasLimit(limit)
  if rc.isErr:
    return err(rc.error)

  let headerBaseFee = header.baseFee
  # Verify the header is not malformed
  if headerBaseFee.isZero:
    return err((errCliqueExpectedBaseFee,""))

  # Verify the baseFee is correct based on the parent header.
  var expectedBaseFee = c.calc1599BaseFee(parent)
  if headerBaseFee != expectedBaseFee:
    return err((errCliqueBaseFeeError,
                &"invalid baseFee: have {expectedBaseFee}, "&
                &"want {header.baseFee}, " &
                &"parent.baseFee {parent.baseFee}, "&
                &"parent.gasUsed {parent.gasUsed}"))

  return ok()

# ------------------------------------------------------------------------------
# Seal hash support
# ------------------------------------------------------------------------------

# clique/clique.go(730): func encodeSigHeader(w [..]
proc encodeSealHeader*(header: BlockHeader): seq[byte] =
  ## Cut sigature off `extraData` header field and consider new `baseFee`
  ## field for Eip1559.
  doAssert EXTRA_SEAL < header.extraData.len

  var rlpHeader = header
  rlpHeader.extraData.setLen(header.extraData.len - EXTRA_SEAL)

  rlp.encode(rlpHeader)

# clique/clique.go(688): func SealHash(header *types.Header) common.Hash {
proc hashSealHeader*(header: BlockHeader): Hash256 =
  ## Returns the hash of a block prior to it being sealed.
  header.encodeSealHeader.keccakHash

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
