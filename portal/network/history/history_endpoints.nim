# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import results, chronicles, chronos, ./history_network

export results, history_network

proc getBlockBody*(
    n: HistoryNetwork, header: Header
): Future[Result[BlockBody, string]] {.async: (raises: [CancelledError], raw: true).} =
  n.getContent(blockBodyContentKey(header.number), BlockBody, header)

proc getReceipts*(
    n: HistoryNetwork, header: Header
): Future[Result[StoredReceipts, string]] {.
    async: (raises: [CancelledError], raw: true)
.} =
  n.getContent(receiptsContentKey(header.number), StoredReceipts, header)
