# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  karax/[karaxdsl, vdom]

import
  chronicles_tail/jsplugins

proc networkSectionContent: VNode =
  result = buildHtml(tdiv):
    text "Networking"

addSection("Network", networkSectionContent)

