# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../verkle_accounts_cache as impl,
  ../base/base_desc

type
  AccountsCache* = ref object of LedgerRef
    ac*: impl.AccountsCache

  SavePoint* = ref object of LedgerSpRef
    sp*: impl.SavePoint

# End
