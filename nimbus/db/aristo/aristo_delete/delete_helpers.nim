# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  ".."/[aristo_desc, aristo_layers]


proc disposeOfVtx*(
    db: AristoDbRef;                   # Database, top layer
    rvid: RootedVertexID;              # Vertex ID to clear
      ) =
  # Remove entry
  db.layersResVtx(rvid)
  db.layersResKey(rvid)

# End
