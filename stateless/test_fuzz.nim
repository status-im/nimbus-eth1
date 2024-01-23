# Nimbus
# Copyright (c) 2020-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  testutils/fuzzing, ../../nimbus/db/core_db,
  ./tree_from_witness, ./witness_types

# please read instruction in status-im/nim-testutils/fuzzing/readme.md
# or status-im/nim-testutils/fuzzing/fuzzing_on_windows.md
# if you want to run fuzz test

test:
  var db = newCoreDbRef(LegacyDbMemory)
  try:
    var tb = initTreeBuilder(payload, db, {wfNoFlag})
    let root = tb.buildTree()
  except ParsingError, ContractCodeError:
    debugEcho "Error detected ", getCurrentExceptionMsg()
