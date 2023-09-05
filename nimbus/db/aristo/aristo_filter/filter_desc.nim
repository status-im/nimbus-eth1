# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  ../aristo_desc

type
  StateRootPair* = object
    ## Helper structure for analysing state roots.
    be*: HashKey                   ## Backend state root
    fg*: HashKey                   ## Layer or filter implied state root

  # ----------------

  QidAction* = object
    ## Instruction for administering filter queue ID slots. The op-code is
    ## followed by one or two queue ID arguments. In case of a two arguments,
    ## the value of the second queue ID is never smaller than the first one.
    op*: QidOp                     ## Action, followed by at most two queue IDs
    qid*: QueueID                  ## Action argument
    xid*: QueueID                  ## Second action argument for range argument

  QidOp* = enum
    Oops = 0
    SaveQid                        ## Store new item
    HoldQid                        ## Move/append range items to local queue
    DequQid                        ## Store merged local queue items
    DelQid                         ## Delete entry from last overflow queue

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
