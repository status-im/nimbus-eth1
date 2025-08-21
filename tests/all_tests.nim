# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.warning[UnusedImport]: off.}

import
  ./[
    test_aristo,
    test_configuration,
    test_coredb,
    test_difficulty,
    test_engine_api,
    test_evm_support,
    test_evm_errors,
    test_async_evm,
    test_filters,
    test_forked_chain,
    test_forkid,
    test_genesis,
    test_getproof_json,
    test_aristo_proof,
    test_jwt_auth,
    test_kvt,
    test_ledger,
    test_stateroot_mismatch,
    test_op_arith,
    test_op_bit,
    test_op_custom,
    test_op_env,
    test_op_memory,
    test_op_misc,
    test_precompiles,
    test_rpc,
    test_transaction_json,
    test_txpool,
    test_networking,
    test_pooled_tx,
    test_stateless_witness_types,
    test_stateless_witness_generation,
    test_stateless_witness_verification,
    # These two suites are much slower than all the rest, so run them last
    test_blockchain_json,
    test_generalstate_json,
]
