# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
import
  eth/common/blocks 

type
  CasperRef* = ref object
    feeRecipient: Address
    timestamp   : EthTime
    prevRandao  : Bytes32
    withdrawals : seq[Withdrawal] ## EIP-4895
    beaconRoot  : Hash32 ## EIP-4788

# ------------------------------------------------------------------------------
# Getters
# ------------------------------------------------------------------------------

func feeRecipient*(ctx: CasperRef): Address =
  ctx.feeRecipient

func timestamp*(ctx: CasperRef): EthTime =
  ctx.timestamp

func prevRandao*(ctx: CasperRef): Bytes32 =
  ctx.prevRandao

proc withdrawals*(ctx: CasperRef): seq[Withdrawal] =
  ctx.withdrawals

func parentBeaconBlockRoot*(ctx: CasperRef): Hash32 =
  ctx.beaconRoot

# ------------------------------------------------------------------------------
# Setters
# ------------------------------------------------------------------------------

proc `feeRecipient=`*(ctx: CasperRef, val: Address) =
  ctx.feeRecipient = val

proc `timestamp=`*(ctx: CasperRef, val: EthTime) =
  ctx.timestamp = val

proc `prevRandao=`*(ctx: CasperRef, val: Bytes32) =
  ctx.prevRandao = val

proc `withdrawals=`*(ctx: CasperRef, val: sink seq[Withdrawal]) =
  ctx.withdrawals = system.move(val)

proc `parentBeaconBlockRoot=`*(ctx: CasperRef, val: Hash32) =
  ctx.beaconRoot = val
