# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/strutils,
  stint,
  chronos,
  results,
  eth/common/eth_types_rlp,
  web3/eth_api_types,
  ../header_store,
  ../types

type
  QuantityTagKind = enum
    LatestBlock
    BlockNumber

  QuantityTag = object
    case kind: QuantityTagKind
    of LatestBlock:
      discard
    of BlockNumber:
      blockNumber: Quantity

func parseQuantityTag(blockTag: BlockTag): Result[QuantityTag, string] =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii
    case tag
    of "latest":
      return ok(QuantityTag(kind: LatestBlock))
    else:
      return err("Unsupported blockTag: " & tag)
  else:
    let quantity = blockTag.number
    return ok(QuantityTag(kind: BlockNumber, blockNumber: quantity))

template checkPreconditions(proxy: VerifiedRpcProxy) =
  if proxy.headerStore.isEmpty():
    raise newException(ValueError, "Syncing")

proc getHeaderByTag(
    proxy: VerifiedRpcProxy, quantityTag: BlockTag
): results.Opt[Header] {.raises: [ValueError].} =
  checkPreconditions(proxy)

  let tag = parseQuantityTag(quantityTag).valueOr:
    raise newException(ValueError, error)

  case tag.kind
  of LatestBlock:
    # this will always return some block, as we always checkPreconditions
    proxy.headerStore.latest
  of BlockNumber:
    proxy.headerStore.get(base.BlockNumber(distinctBase(tag.blockNumber)))

proc getHeaderByTagOrThrow*(
    proxy: VerifiedRpcProxy, quantityTag: BlockTag
): Header {.raises: [ValueError].} =
  getHeaderByTag(proxy, quantityTag).valueOr:
    raise newException(ValueError, "No block stored for given tag " & $quantityTag)
