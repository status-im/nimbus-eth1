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
## Tools & Utils for Clique PoA Consensus Protocol
## ===============================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  std/[algorithm, times],
  ../../constants,
  ../../utils/utils,
  ./clique_defs,
  eth/[common, rlp],
  stew/[objects, results],
  stint

type
  EthSortOrder* = enum
    EthDescending = SortOrder.Descending.ord
    EthAscending = SortOrder.Ascending.ord

{.push raises: [].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func zeroItem[T](t: typedesc[T]): T =
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
  e.sorted(cmp = eCmp, order = order.ord.SortOrder)


proc cliqueResultErr*(w: CliqueError): CliqueOkResult =
  ## Return error result (syntactic sugar)
  err(w)


proc extraDataAddresses*(extraData: Blob): seq[EthAddress] =
  ## Extract signer addresses from extraData header field

  proc toEthAddress(a: openArray[byte]; start: int): EthAddress =
    toArray(EthAddress.len, a[start ..< start + EthAddress.len])

  if EXTRA_VANITY + EXTRA_SEAL < extraData.len and
      ((extraData.len - (EXTRA_VANITY + EXTRA_SEAL)) mod EthAddress.len) == 0:
    var addrOffset = EXTRA_VANITY
    while addrOffset + EthAddress.len <= extraData.len - EXTRA_SEAL:
      result.add extraData.toEthAddress(addrOffset)
      addrOffset += EthAddress.len


# core/types/block.go(343): func (b *Block) WithSeal(header [..]
proc withHeader*(b: EthBlock; header: BlockHeader): EthBlock =
  ## New block with the data from `b` but the header replaced with the
  ## argument one.
  EthBlock(header: header,
           txs:    b.txs,
           uncles: b.uncles)

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
