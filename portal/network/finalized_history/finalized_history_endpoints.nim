# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import results, chronicles, chronos, ./finalized_history_network

export results, finalized_history_network

proc getBlockBody*(
    n: FinalizedHistoryNetwork, header: Header
): Future[Opt[BlockBody]] {.async: (raises: [CancelledError], raw: true).} =
  n.getContent(blockBodyContentKey(header.number), BlockBody, header)

proc getReceipts*(
    n: FinalizedHistoryNetwork, header: Header
): Future[Opt[BlockBody]] {.async: (raises: [CancelledError], raw: true).} =
  n.getContent(blockBodyContentKey(header.number), BlockBody, header)
