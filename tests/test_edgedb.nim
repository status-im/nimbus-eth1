# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ./test_edgedb/[
    test_era1_coredb,
  ]

proc edgeDbMain*() =
  testEra1CoreDbMain()

when isMainModule:
  edgeDbMain()

# End
