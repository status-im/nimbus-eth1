# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[typetraits, tables],
  eth/common/base,
  eth/common/times,
  eth/common/hashes,
  eth/common/addresses,
  stew/endians2,
  stint,
  nimcrypto/sha2,
  ./chain_config

# ------------------------------------------------------------------------------
# When the client doing initialization step, it will go through
# complicated steps before the genesis hash is ready. See `CommonRef.init`.
# If the genesis happen to exists in database belonging to other network,
# it will replace the one in CommonRef cache.
# That is the reason why using genesis header or genesis hash + ChainId is
# not a good solution to prevent loading existing data directory for
# the wrong network.
# But the ChainConfig + raw Genesis hash will make the job done before
# CommonRef creation.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Private helper functions
# ------------------------------------------------------------------------------

func update(ctx: var sha256, val: uint64 | UInt256) =
  ctx.update(val.toBytesLE)

func update(ctx: var sha256, val: ChainId | EthTime | NetworkId) =
  ctx.update(distinctBase val)

func update(ctx: var sha256, val: bool) =
  ctx.update([val.byte])

func update(ctx: var sha256, val: Hash32 | Bytes8 | Bytes32 | Address) =
  ctx.update(val.data)

func update[T](ctx: var sha256, val: Opt[T]) =
  if val.isSome:
    ctx.update(val.get)

func update[K, V](ctx: var sha256, val: Table[K, V]) =
  mixin update
  for k, v in val:
    ctx.update(k)
    ctx.update(v)

func update[T: object](ctx: var sha256, val: T) =
  for f in fields(val):
    ctx.update(f)

func update[T: ref](ctx: var sha256, val: T) =
  for f in fields(val[]):
    ctx.update(f)

func update(ctx: var sha256, list: openArray[Opt[BlobSchedule]]) =
  mixin update
  for val in list:
    ctx.update(val)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func calcHash*(networkId: NetworkId, conf: ChainConfig, genesis: Genesis): Hash32 =
  var ctx: sha256
  ctx.init()
  ctx.update(networkId)
  ctx.update(conf.chainId)
  if genesis.isNil.not:
    ctx.update(genesis)
  ctx.finish(result.data)
  ctx.clear()

func calcHash*(networkId: NetworkId, params: NetworkParams): Hash32 =
  calcHash(networkId, params.config, params.genesis)
