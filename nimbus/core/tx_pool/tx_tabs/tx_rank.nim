# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Table: `rank` ~ `sender`
## =========================================
##

{.push raises: [].}

import
  std/[tables],
  eth/common,
  stew/[sorted_set],
  results


type
  TxRank* = ##\
    ## Order relation, determins how the `Addresses` are ranked
    distinct int64

  TxRankAddrRef* = ##\
    ## Set of adresses having the same rank.
    TableRef[Address,TxRank]

  TxRankTab* = object ##\
    ## Descriptor for `TxRank` <-> `Address` mapping.
    rankList: SortedSet[TxRank,TxRankAddrRef]
    addrTab: Table[Address,TxRank]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc cmp(a,b: TxRank): int {.borrow.}
  ## mixin for SortedSet

proc `==`(a,b: TxRank): bool {.borrow.}

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(rt: var TxRankTab) =
  ## Constructor
  rt.rankList.init

proc clear*(rt: var TxRankTab) =
  ## Flush tables
  rt.rankList.clear
  rt.addrTab.clear

# ------------------------------------------------------------------------------
# Public functions, base management operations
# ------------------------------------------------------------------------------

proc insert*(rt: var TxRankTab; rank: TxRank; sender: Address): bool
    {.gcsafe,raises: [KeyError].} =
  ## Add or update a new ranked address. This function returns `true` it the
  ## address exists already with the current rank.

  # Does this address exists already?
  if rt.addrTab.hasKey(sender):
    let oldRank = rt.addrTab[sender]
    if oldRank == rank:
      return false

    # Delete address from oldRank address set
    let oldRankSet = rt.rankList.eq(oldRank).value.data
    if 1 < oldRankSet.len:
      oldRankSet.del(sender)
    else:
      discard rt.rankList.delete(oldRank)

  # Add new ranked address
  var newRankSet: TxRankAddrRef
  let rc = rt.rankList.insert(rank)
  if rc.isOk:
    newRankSet = newTable[Address,TxRank](1)
    rc.value.data = newRankSet
  else:
    newRankSet = rt.rankList.eq(rank).value.data

  newRankSet[sender] = rank
  rt.addrTab[sender] = rank
  true


proc delete*(rt: var TxRankTab; sender: Address): bool
    {.gcsafe,raises: [KeyError].} =
  ## Delete argument address `sender` from rank table.
  if rt.addrTab.hasKey(sender):
    let
      rankNum = rt.addrTab[sender]
      rankSet = rt.rankList.eq(rankNum).value.data

    # Delete address from oldRank address set
    if 1 < rankSet.len:
      rankSet.del(sender)
    else:
      discard rt.rankList.delete(rankNum)

    rt.addrTab.del(sender)
    return true

# ------------------------------------------------------------------------------
# Public functions: `TxRank` > `Address`
# ------------------------------------------------------------------------------

proc len*(rt: var TxRankTab): int =
  ## Number of ranks available
  rt.rankList.len

proc eq*(rt: var TxRankTab; rank: TxRank):
       SortedSetResult[TxRank,TxRankAddrRef] =
  rt.rankList.eq(rank)

proc ge*(rt: var TxRankTab; rank: TxRank):
       SortedSetResult[TxRank,TxRankAddrRef] =
  rt.rankList.ge(rank)

proc gt*(rt: var TxRankTab; rank: TxRank):
       SortedSetResult[TxRank,TxRankAddrRef] =
  rt.rankList.gt(rank)

proc le*(rt: var TxRankTab; rank: TxRank):
       SortedSetResult[TxRank,TxRankAddrRef] =
  rt.rankList.le(rank)

proc lt*(rt: var TxRankTab; rank: TxRank):
       SortedSetResult[TxRank,TxRankAddrRef] =
  rt.rankList.lt(rank)

# ------------------------------------------------------------------------------
# Public functions: `Address` > `TxRank`
# ------------------------------------------------------------------------------

proc nItems*(rt: var TxRankTab): int =
  ## Total number of address items registered
  rt.addrTab.len

proc eq*(rt: var TxRankTab; sender: Address):
       SortedSetResult[Address,TxRank]
    {.gcsafe,raises: [KeyError].} =
  if rt.addrTab.hasKey(sender):
    return toSortedSetResult(key = sender, data = rt.addrTab[sender])
  err(rbNotFound)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
