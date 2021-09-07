# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  accounts/manager

export manager

type
  EthContext* = ref object
    am*: AccountsManager


proc newEthContext*(): EthContext =
  result = new(EthContext)
  result.am = AccountsManager.init()
