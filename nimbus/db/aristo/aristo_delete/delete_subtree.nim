# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import ../aristo_constants

when DELETE_SUBTREE_VERTICES_MAX == 0:
  import ./delete_subtree_now as del_sub
else:
  import ./delete_subtree_lazy as del_sub

export del_sub

# End
