# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.warning[UnusedImport]: off.}

import
  ./test_content_db,
  ./test_discovery_rpc,
  ./wire_protocol_tests/all_wire_protocol_tests,
  ./history_network_tests/all_history_network_tests,
  ./beacon_network_tests/all_beacon_network_tests,
  ./state_network_tests/all_state_network_tests
