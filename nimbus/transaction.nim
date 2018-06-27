# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  constants, errors, eth_common

type
  BaseTransaction* = ref object
    nonce*: Int256
    gasPrice*: GasInt
    gas*: GasInt
    to*: string
    value*: UInt256
    data*: string
    v*: Int256
    r*: Int256
    s*: Int256

proc intrinsicGas*(t: BaseTransaction): GasInt =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation)
  raise newException(ValueError, "not implemented intrinsicGas")






proc validate*(t: BaseTransaction) =
  # Hook called during instantiation to ensure that all transaction
  # parameters pass validation rules
  if t.intrinsicGas() > t.gas:
    raise newException(ValidationError, "Insufficient gas")
  #  self.check_signature_validity()

proc sender*(t: BaseTransaction): string =
  # TODO
  ""
