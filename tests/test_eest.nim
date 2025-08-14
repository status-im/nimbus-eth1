# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[strutils, tables, json, os, sets],
  ./test_helpers, ./test_allowed_to_fail,
  ./test_generalstate_json,
  ../execution_chain/core/executor, test_config,
  ../execution_chain/transaction,
  ../execution_chain/[evm/state, evm/types],
  ../execution_chain/db/ledger,
  ../execution_chain/common/common,
  ../execution_chain/utils/[utils, debug],
  ../execution_chain/evm/tracer/legacy_tracer,
  ../tools/common/helpers as chp,
  ../tools/evmstate/helpers,
  ../tools/common/state_clearing,
  eth/common/transaction_utils,
  unittest2,
  stew/byteutils,
  results

const
  path = "/Users/advaitasaha/Downloads/fixtures-test-dev3/state_tests/osaka/eip7939_count_leading_zeros/count_leading_zeros"

proc eestTest() =
  let config = getConfiguration()
  let n = json.parseFile(path / "clz_code_copy_operation.json")
  var testStatusIMPL: TestStatus
  testFixture(n, testStatusIMPL, config.trace, true)

when isMainModule:
  eestTest()