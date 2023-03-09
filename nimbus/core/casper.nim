# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
import
  eth/common

type
  CasperRef* = ref object
    feeRecipient* : EthAddress
    timestamp*    : EthTime
    prevRandao*   : Hash256

proc prepare*(ctx: CasperRef, header: var BlockHeader) =
  header.coinbase   = ctx.feeRecipient
  header.timestamp  = ctx.timestamp
  header.prevRandao = ctx.prevRandao
  header.difficulty = DifficultyInt.zero

proc prepareForSeal*(ctx: CasperRef, header: var BlockHeader) =
  header.nonce      = default(BlockNonce)
  header.extraData  = @[] # TODO: probably this should be configurable by user?
  # this repetition, assigning prevRandao is because how txpool works
  header.prevRandao = ctx.prevRandao

# ------------------------------------------------------------------------------
# Getters
# ------------------------------------------------------------------------------

func feeRecipient*(ctx: CasperRef): EthAddress =
  ctx.feeRecipient

func timestamp*(ctx: CasperRef): EthTime =
  ctx.timestamp

func prevRandao*(ctx: CasperRef): Hash256 =
  ctx.prevRandao

# ------------------------------------------------------------------------------
# Setters
# ------------------------------------------------------------------------------

proc `feeRecipient=`*(ctx: CasperRef, val: EthAddress) =
  ctx.feeRecipient = val

proc `timestamp=`*(ctx: CasperRef, val: EthTime) =
  ctx.timestamp = val

proc `prevRandao=`*(ctx: CasperRef, val: Hash256) =
  ctx.prevRandao = val
