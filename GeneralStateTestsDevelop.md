GeneralStateTestsDevelop
===
## acl
```diff
+ access_list.json                                                OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## all_opcodes
```diff
+ all_opcodes.json                                                OK
+ cover_revert.json                                               OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## basic_tload
```diff
+ basic_tload_after_store.json                                    OK
+ basic_tload_gasprice.json                                       OK
+ basic_tload_other_after_tstore.json                             OK
+ basic_tload_transaction_begin.json                              OK
+ basic_tload_works.json                                          OK
```
OK: 5/5 Fail: 0/5 Skip: 0/5
## blake2
```diff
+ blake2b.json                                                    OK
+ blake2b_gas_limit.json                                          OK
+ blake2b_invalid_gas.json                                        OK
+ blake2b_large_gas_limit.json                                    OK
```
OK: 4/4 Fail: 0/4 Skip: 0/4
## blake2_delegatecall
```diff
+ blake2_precompile_delegatecall.json                             OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## blob_txs
```diff
+ blob_gas_subtraction_tx.json                                    OK
+ blob_tx_attribute_calldata_opcodes.json                         OK
+ blob_tx_attribute_gasprice_opcode.json                          OK
+ blob_tx_attribute_opcodes.json                                  OK
+ blob_tx_attribute_value_opcode.json                             OK
+ blob_type_tx_pre_fork.json                                      OK
+ insufficient_balance_blob_tx.json                               OK
+ invalid_blob_hash_versioning_single_tx.json                     OK
+ invalid_normal_gas.json                                         OK
+ invalid_tx_blob_count.json                                      OK
+ invalid_tx_max_fee_per_blob_gas_state.json                      OK
+ sufficient_balance_blob_tx.json                                 OK
```
OK: 12/12 Fail: 0/12 Skip: 0/12
## blobgasfee_opcode
```diff
+ blobbasefee_before_fork.json                                    OK
+ blobbasefee_out_of_gas.json                                     OK
+ blobbasefee_stack_overflow.json                                 OK
```
OK: 3/3 Fail: 0/3 Skip: 0/3
## blobhash_opcode
```diff
+ blobhash_gas_cost.json                                          OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## bls12_g1add
```diff
+ call_types.json                                                 OK
+ gas.json                                                        OK
+ invalid.json                                                    OK
+ valid.json                                                      OK
```
OK: 4/4 Fail: 0/4 Skip: 0/4
## bls12_g1msm
```diff
+ call_types.json                                                 OK
+ invalid.json                                                    OK
+ valid.json                                                      OK
```
OK: 3/3 Fail: 0/3 Skip: 0/3
## bls12_g1mul
```diff
+ call_types.json                                                 OK
+ gas.json                                                        OK
+ invalid.json                                                    OK
+ valid.json                                                      OK
```
OK: 4/4 Fail: 0/4 Skip: 0/4
## bls12_g2add
```diff
+ call_types.json                                                 OK
+ gas.json                                                        OK
+ invalid.json                                                    OK
+ valid.json                                                      OK
```
OK: 4/4 Fail: 0/4 Skip: 0/4
## bls12_g2msm
```diff
+ call_types.json                                                 OK
+ invalid.json                                                    OK
+ valid.json                                                      OK
```
OK: 3/3 Fail: 0/3 Skip: 0/3
## bls12_g2mul
```diff
+ call_types.json                                                 OK
+ gas.json                                                        OK
+ invalid.json                                                    OK
+ valid.json                                                      OK
```
OK: 4/4 Fail: 0/4 Skip: 0/4
## bls12_map_fp2_to_g2
```diff
+ call_types.json                                                 OK
+ gas.json                                                        OK
+ invalid.json                                                    OK
+ valid.json                                                      OK
```
OK: 4/4 Fail: 0/4 Skip: 0/4
## bls12_map_fp_to_g1
```diff
+ call_types.json                                                 OK
+ gas.json                                                        OK
+ invalid.json                                                    OK
+ isogeny_kernel_values.json                                      OK
+ valid.json                                                      OK
```
OK: 5/5 Fail: 0/5 Skip: 0/5
## bls12_pairing
```diff
+ call_types.json                                                 OK
+ gas.json                                                        OK
+ invalid.json                                                    OK
+ valid.json                                                      OK
```
OK: 4/4 Fail: 0/4 Skip: 0/4
## bls12_precompiles_before_fork
```diff
+ precompile_before_fork.json                                     OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## bls12_variable_length_input_contracts
```diff
+ invalid_gas_g1msm.json                                          OK
+ invalid_gas_g2msm.json                                          OK
+ invalid_gas_pairing.json                                        OK
+ invalid_length_g1msm.json                                       OK
+ invalid_length_g2msm.json                                       OK
+ invalid_length_pairing.json                                     OK
+ valid_gas_g1msm.json                                            OK
+ valid_gas_g2msm.json                                            OK
+ valid_gas_pairing.json                                          OK
```
OK: 9/9 Fail: 0/9 Skip: 0/9
## call_and_callcode_gas_calculation
```diff
+ value_transfer_gas_calculation.json                             OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## calldatacopy
```diff
+ calldatacopy.json                                               OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## calldataload
```diff
+ calldataload.json                                               OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## calldatasize
```diff
+ calldatasize.json                                               OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## calls
```diff
+ delegate_call_targets.json                                      OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## chainid
```diff
+ chainid.json                                                    OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## coverage
```diff
+ coverage.json                                                   OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## create_returndata
```diff
+ create2_return_data.json                                        OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## dup
```diff
+ dup.json                                                        OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## dynamic_create2_selfdestruct_collision
```diff
+ dynamic_create2_selfdestruct_collision.json                     OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## execution_gas
```diff
+ full_gas_consumption.json                                       OK
+ gas_consumption_below_data_floor.json                           OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## gas
```diff
+ account_warming.json                                            OK
+ call_to_pre_authorized_oog.json                                 OK
+ gas_cost.json                                                   OK
+ intrinsic_gas_cost.json                                         OK
+ self_set_code_cost.json                                         OK
```
OK: 5/5 Fail: 0/5 Skip: 0/5
## initcode
```diff
+ contract_creating_tx.json                                       OK
+ create_opcode_initcode.json                                     OK
+ gas_usage.json                                                  OK
```
OK: 3/3 Fail: 0/3 Skip: 0/3
## mcopy
```diff
+ mcopy_on_empty_memory.json                                      OK
+ valid_mcopy_operations.json                                     OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## mcopy_contexts
```diff
+ no_memory_corruption_on_upper_call_stack_levels.json            OK
+ no_memory_corruption_on_upper_create_stack_levels.json          OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## mcopy_memory_expansion
```diff
+ mcopy_huge_memory_expansion.json                                OK
+ mcopy_memory_expansion.json                                     OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## modexp
```diff
+ modexp.json                                                     OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## point_evaluation_precompile
```diff
+ call_opcode_types.json                                          OK
+ external_vectors.json                                           OK
+ invalid_inputs.json                                             OK
+ precompile_before_fork.json                                     OK
+ tx_entry_point.json                                             OK
+ valid_inputs.json                                               OK
```
OK: 6/6 Fail: 0/6 Skip: 0/6
## point_evaluation_precompile_gas
```diff
+ point_evaluation_precompile_gas_usage.json                      OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## precompile_absence
```diff
+ precompile_absence.json                                         OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## precompiles
```diff
+ precompiles.json                                                OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## push
```diff
+ push.json                                                       OK
+ stack_overflow.json                                             OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## push0
```diff
+ push0_contract_during_call_contexts.json                        OK
+ push0_contracts.json                                            OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## reentrancy_selfdestruct_revert
```diff
+ reentrancy_selfdestruct_revert.json                             OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## refunds
```diff
+ gas_refunds_from_data_floor.json                                OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## selfdestruct
```diff
+ calling_from_new_contract_to_pre_existing_contract.json         OK
+ calling_from_pre_existing_contract_to_new_contract.json         OK
+ create_selfdestruct_same_tx.json                                OK
+ create_selfdestruct_same_tx_increased_nonce.json                OK
+ self_destructing_initcode.json                                  OK
+ self_destructing_initcode_create_tx.json                        OK
+ selfdestruct_pre_existing.json                                  OK
```
OK: 7/7 Fail: 0/7 Skip: 0/7
## selfdestruct_revert
```diff
+ selfdestruct_created_in_same_tx_with_revert.json                OK
+ selfdestruct_not_created_in_same_tx_with_revert.json            OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## set_code_txs
```diff
+ address_from_set_code.json                                      OK
+ call_into_chain_delegating_set_code.json                        OK
+ call_into_self_delegating_set_code.json                         OK
+ contract_create.json                                            OK
+ creating_delegation_designation_contract.json                   OK
+ delegation_clearing.json                                        OK
+ delegation_clearing_and_set.json                                OK
+ delegation_clearing_failing_tx.json                             OK
+ delegation_clearing_tx_to.json                                  OK
+ deploying_delegation_designation_contract.json                  OK
+ empty_authorization_list.json                                   OK
+ ext_code_on_chain_delegating_set_code.json                      OK
+ ext_code_on_self_delegating_set_code.json                       OK
+ ext_code_on_self_set_code.json                                  OK
+ ext_code_on_set_code.json                                       OK
+ many_delegations.json                                           OK
+ nonce_overflow_after_first_authorization.json                   OK
+ nonce_validity.json                                             OK
+ self_code_on_set_code.json                                      OK
+ self_sponsored_set_code.json                                    OK
+ set_code_address_and_authority_warm_state.json                  OK
+ set_code_address_and_authority_warm_state_call_types.json       OK
+ set_code_all_invalid_authorization_tuples.json                  OK
+ set_code_call_set_code.json                                     OK
+ set_code_from_account_with_non_delegating_code.json             OK
+ set_code_max_depth_call_stack.json                              OK
+ set_code_multiple_first_valid_authorization_tuples_same_signer. OK
+ set_code_multiple_valid_authorization_tuples_first_invalid_same OK
+ set_code_multiple_valid_authorization_tuples_same_signer_increa OK
+ set_code_multiple_valid_authorization_tuples_same_signer_increa OK
+ set_code_to_account_deployed_in_same_tx.json                    OK
+ set_code_to_contract_creator.json                               OK
+ set_code_to_log.json                                            OK
+ set_code_to_non_empty_storage_non_zero_nonce.json               OK
+ set_code_to_precompile.json                                     OK
+ set_code_to_precompile_not_enough_gas_for_precompile_execution. OK
+ set_code_to_self_caller.json                                    OK
+ set_code_to_self_destruct.json                                  OK
+ set_code_to_self_destructing_account_deployed_in_same_tx.json   OK
+ set_code_to_sstore.json                                         OK
+ set_code_to_tstore_available_at_correct_address.json            OK
+ set_code_to_tstore_reentry.json                                 OK
+ set_code_transaction_fee_validations.json                       OK
+ set_code_using_chain_specific_id.json                           OK
+ set_code_using_valid_synthetic_signatures.json                  OK
+ signature_s_out_of_range.json                                   OK
+ tx_into_chain_delegating_set_code.json                          OK
+ tx_into_self_delegating_set_code.json                           OK
+ valid_tx_invalid_auth_signature.json                            OK
+ valid_tx_invalid_chain_id.json                                  OK
```
OK: 50/50 Fail: 0/50 Skip: 0/50
## set_code_txs_2
```diff
+ call_pointer_to_created_from_create_after_oog_call_again.json   OK
+ call_to_precompile_in_pointer_context.json                      OK
+ contract_storage_to_pointer_with_storage.json                   OK
+ double_auth.json                                                OK
+ eoa_init_as_pointer.json                                        OK
+ pointer_call_followed_by_direct_call.json                       OK
+ pointer_contract_pointer_loop.json                              OK
+ pointer_reentry.json                                            OK
+ pointer_reverts.json                                            OK
+ pointer_to_pointer.json                                         OK
+ pointer_to_precompile.json                                      OK
+ pointer_to_static.json                                          OK
+ pointer_to_static_reentry.json                                  OK
+ set_code_type_tx_pre_fork.json                                  OK
+ static_to_pointer.json                                          OK
```
OK: 15/15 Fail: 0/15 Skip: 0/15
## tload_calls
```diff
+ tload_calls.json                                                OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## tload_reentrancy
```diff
+ tload_reentrancy.json                                           OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## transaction_validity
```diff
+ transaction_validity_type_0.json                                OK
+ transaction_validity_type_1_type_2.json                         OK
+ transaction_validity_type_3.json                                OK
+ transaction_validity_type_4.json                                OK
```
OK: 4/4 Fail: 0/4 Skip: 0/4
## tstorage
```diff
+ gas_usage.json                                                  OK
+ run_until_out_of_gas.json                                       OK
+ tload_after_sstore.json                                         OK
+ tload_after_tstore.json                                         OK
+ tload_after_tstore_is_zero.json                                 OK
+ transient_storage_unset_values.json                             OK
```
OK: 6/6 Fail: 0/6 Skip: 0/6
## tstorage_create_contexts
```diff
+ contract_creation.json                                          OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## tstorage_execution_contexts
```diff
+ subcall.json                                                    OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## tstorage_reentrancy_contexts
```diff
+ reentrant_call.json                                             OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## tstorage_selfdestruct
```diff
+ reentrant_selfdestructing_call.json                             OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## tstore_reentrancy
```diff
+ tstore_reentrancy.json                                          OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## tx_intrinsic_gas
```diff
+ tx_intrinsic_gas.json                                           OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## warm_coinbase
```diff
+ warm_coinbase_call_out_of_gas.json                              OK
+ warm_coinbase_gas_usage.json                                    OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## with_eof
```diff
+ legacy_create_edge_code_size.json                               OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## yul_example
```diff
+ yul.json                                                        OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1

---TOTAL---
OK: 212/212 Fail: 0/212 Skip: 0/212
