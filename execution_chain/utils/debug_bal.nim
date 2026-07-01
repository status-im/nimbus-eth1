# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  ../../tools/t8n/serialize_bal

export
  serialize_bal

proc toJson*(x: AccountChanges): JsonNode =
  @@(x)

proc toJson*(bal: BlockAccessListRef): JsonNode =
  @@(bal)
