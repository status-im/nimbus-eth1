# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

# logging.nim is only importing and re-exporting to make the logging import
# clean without bring in additional code from nimbus_binary_common.
from beacon_chain/nimbus_binary_common import setupLogging, StdoutLogKind

export setupLogging, StdoutLogKind
