GeneralStateTests
===
## blob_txs
```diff
+ blob_gas_subtraction_tx.json                                    OK
+ blob_tx_attribute_calldata_opcodes.json                         OK
+ blob_tx_attribute_gasprice_opcode.json                          OK
+ blob_tx_attribute_opcodes.json                                  OK
+ blob_tx_attribute_value_opcode.json                             OK
+ insufficient_balance_blob_tx.json                               OK
+ invalid_blob_hash_versioning_single_tx.json                     OK
+ invalid_normal_gas.json                                         OK
+ invalid_tx_blob_count.json                                      OK
+ invalid_tx_max_fee_per_blob_gas_state.json                      OK
+ sufficient_balance_blob_tx.json                                 OK
```
OK: 11/11 Fail: 0/11 Skip: 0/11
## count_leading_zeros
```diff
+ clz_code_copy_operation.json                                    OK
+ clz_gas_cost.json                                               OK
+ clz_gas_cost_boundary.json                                      OK
+ clz_jump_operation.json                                         OK
+ clz_opcode_scenarios.json                                       OK
+ clz_stack_underflow.json                                        OK
+ clz_with_memory_operation.json                                  OK
```
OK: 7/7 Fail: 0/7 Skip: 0/7
## initcode
```diff
+ contract_creating_tx.json                                       OK
+ create_opcode_initcode.json                                     OK
+ gas_usage.json                                                  OK
```
OK: 3/3 Fail: 0/3 Skip: 0/3
## max_blob_per_tx
```diff
+ invalid_max_blobs_per_tx.json                                   OK
+ valid_max_blobs_per_tx.json                                     OK
```
OK: 2/2 Fail: 0/2 Skip: 0/2
## modexp
```diff
+ modexp.json                                                     OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## modexp_thresholds
```diff
+ vectors_from_file.json                                          OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## modexp_upper_bounds
```diff
+ modexp_upper_bounds.json                                        OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## p256verify
```diff
+ call_types.json                                                 OK
+ gas.json                                                        OK
+ invalid.json                                                    OK
+ precompile_as_tx_entry_point.json                               OK
+ valid.json                                                      OK
```
OK: 5/5 Fail: 0/5 Skip: 0/5
## p256verify_before_fork
```diff
+ precompile_before_fork.json                                     OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## precompiles
```diff
+ precompiles.json                                                OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## set_code_txs
```diff
+ set_code_to_precompile.json                                     OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## tx_gas_limit
```diff
+ transaction_gas_limit_cap.json                                  OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## with_eof
```diff
+ legacy_create_edge_code_size.json                               OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1

---TOTAL---
OK: 36/36 Fail: 0/36 Skip: 0/36
