BlockchainTests
===
## bc4895-withdrawals
```diff
- accountInteractions.json                                        Fail
+ amountIs0.json                                                  OK
+ amountIs0TouchAccount.json                                      OK
- amountIs0TouchAccountAndTransaction.json                        Fail
+ differentValidatorToTheSameAddress.json                         OK
+ incorrectWithdrawalsRoot.json                                   OK
+ shanghaiWithoutWithdrawalsRLP.json                              OK
- staticcall.json                                                 Fail
+ twoIdenticalIndex.json                                          OK
+ twoIdenticalIndexDifferentValidator.json                        OK
- warmup.json                                                     Fail
+ withdrawalsAddressBounds.json                                   OK
+ withdrawalsAmountBounds.json                                    OK
+ withdrawalsIndexBounds.json                                     OK
+ withdrawalsValidatorIndexBounds.json                            OK
```
OK: 11/15 Fail: 4/15 Skip: 0/15
## bcArrowGlacierToParis
```diff
- difficultyFormula.json                                          Fail
- powToPosBlockRejection.json                                     Fail
- powToPosTest.json                                               Fail
```
OK: 0/3 Fail: 3/3 Skip: 0/3
## bcBerlinToLondon
```diff
- BerlinToLondonTransition.json                                   Fail
- initialVal.json                                                 Fail
+ londonUncles.json                                               OK
```
OK: 1/3 Fail: 2/3 Skip: 0/3
## bcBlockGasLimitTest
```diff
- BlockGasLimit2p63m1.json                                        Fail
+ GasUsedHigherThanBlockGasLimitButNotWithRefundsSuicideFirst.jso OK
+ GasUsedHigherThanBlockGasLimitButNotWithRefundsSuicideLast.json OK
- SuicideTransaction.json                                         Fail
- TransactionGasHigherThanLimit2p63m1.json                        Fail
- TransactionGasHigherThanLimit2p63m1_2.json                      Fail
```
OK: 2/6 Fail: 4/6 Skip: 0/6
## bcByzantiumToConstantinopleFix
```diff
- ConstantinopleFixTransition.json                                Fail
```
OK: 0/1 Fail: 1/1 Skip: 0/1
## bcEIP1153-transientStorage
```diff
+ tloadDoesNotPersistAcrossBlocks.json                            OK
+ tloadDoesNotPersistCrossTxn.json                                OK
+ transStorageBlockchain.json                                     OK
```
OK: 3/3 Fail: 0/3 Skip: 0/3
## bcEIP1559
```diff
+ badBlocks.json                                                  OK
- badUncles.json                                                  Fail
- baseFee.json                                                    Fail
- besuBaseFeeBug.json                                             Fail
- burnVerify.json                                                 Fail
- burnVerifyLondon.json                                           Fail
- checkGasLimit.json                                              Fail
- feeCap.json                                                     Fail
+ gasLimit20m.json                                                OK
+ gasLimit40m.json                                                OK
- highDemand.json                                                 Fail
- intrinsic.json                                                  Fail
- intrinsicOrFail.json                                            Fail
- intrinsicTip.json                                               Fail
- lowDemand.json                                                  Fail
- medDemand.json                                                  Fail
- tips.json                                                       Fail
- tipsLondon.json                                                 Fail
- transFail.json                                                  Fail
- transType.json                                                  Fail
- valCausesOOF.json                                               Fail
```
OK: 3/21 Fail: 18/21 Skip: 0/21
## bcEIP158ToByzantium
```diff
- ByzantiumTransition.json                                        Fail
```
OK: 0/1 Fail: 1/1 Skip: 0/1
## bcEIP3675
```diff
- timestampPerBlock.json                                          Fail
- tipInsideBlock.json                                             Fail
```
OK: 0/2 Fail: 2/2 Skip: 0/2
## bcEIP4844-blobtransactions
```diff
+ blockWithAllTransactionTypes.json                               OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## bcExample
```diff
- basefeeExample.json                                             Fail
- mergeExample.json                                               Fail
- optionsTest.json                                                Fail
- shanghaiExample.json                                            Fail
```
OK: 0/4 Fail: 4/4 Skip: 0/4
## bcExploitTest
```diff
  DelegateCallSpam.json                                           Skip
- ShanghaiLove.json                                               Fail
- StrangeContractCreation.json                                    Fail
- SuicideIssue.json                                               Fail
```
OK: 0/4 Fail: 3/4 Skip: 1/4
## bcForkStressTest
```diff
- AmIOnEIP150.json                                                Fail
- ForkStressTest.json                                             Fail
```
OK: 0/2 Fail: 2/2 Skip: 0/2
## bcFrontierToHomestead
```diff
- CallContractThatCreateContractBeforeAndAfterSwitchover.json     Fail
- ContractCreationFailsOnHomestead.json                           Fail
- HomesteadOverrideFrontier.json                                  Fail
- UncleFromFrontierInHomestead.json                               Fail
- UnclePopulation.json                                            Fail
- blockChainFrontierWithLargerTDvsHomesteadBlockchain.json        Fail
- blockChainFrontierWithLargerTDvsHomesteadBlockchain2.json       Fail
```
OK: 0/7 Fail: 7/7 Skip: 0/7
## bcGasPricerTest
```diff
- RPC_API_Test.json                                               Fail
- highGasUsage.json                                               Fail
+ notxs.json                                                      OK
```
OK: 1/3 Fail: 2/3 Skip: 0/3
## bcHomesteadToDao
```diff
- DaoTransactions.json                                            Fail
- DaoTransactions_EmptyTransactionAndForkBlocksAhead.json         Fail
- DaoTransactions_UncleExtradata.json                             Fail
- DaoTransactions_XBlockm1.json                                   Fail
```
OK: 0/4 Fail: 4/4 Skip: 0/4
## bcHomesteadToEIP150
```diff
- EIP150Transition.json                                           Fail
```
OK: 0/1 Fail: 1/1 Skip: 0/1
## bcInvalidHeaderTest
```diff
+ DifferentExtraData1025.json                                     OK
- DifficultyIsZero.json                                           Fail
+ ExtraData1024.json                                              OK
+ ExtraData33.json                                                OK
+ GasLimitHigherThan2p63m1.json                                   OK
+ GasLimitIsZero.json                                             OK
+ badTimestamp.json                                               OK
+ log1_wrongBlockNumber.json                                      OK
- log1_wrongBloom.json                                            Fail
- timeDiff0.json                                                  Fail
- wrongCoinbase.json                                              Fail
+ wrongDifficulty.json                                            OK
+ wrongGasLimit.json                                              OK
+ wrongGasUsed.json                                               OK
+ wrongNumber.json                                                OK
+ wrongParentHash.json                                            OK
+ wrongParentHash2.json                                           OK
- wrongReceiptTrie.json                                           Fail
- wrongStateRoot.json                                             Fail
+ wrongTimestamp.json                                             OK
+ wrongTransactionsTrie.json                                      OK
+ wrongUncleHash.json                                             OK
```
OK: 16/22 Fail: 6/22 Skip: 0/22
## bcMergeToShanghai
```diff
+ shanghaiBeforeTransition.json                                   OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## bcMultiChainTest
```diff
- CallContractFromNotBestBlock.json                               Fail
- ChainAtoChainB.json                                             Fail
- ChainAtoChainBCallContractFormA.json                            Fail
- ChainAtoChainB_BlockHash.json                                   Fail
- ChainAtoChainB_difficultyB.json                                 Fail
- ChainAtoChainBtoChainA.json                                     Fail
- ChainAtoChainBtoChainAtoChainB.json                             Fail
- UncleFromSideChain.json                                         Fail
- lotsOfLeafs.json                                                Fail
```
OK: 0/9 Fail: 9/9 Skip: 0/9
## bcRandomBlockhashTest
```diff
- 201503110226PYTHON_DUP6BC.json                                  Fail
- randomStatetest101BC.json                                       Fail
- randomStatetest109BC.json                                       Fail
- randomStatetest113BC.json                                       Fail
- randomStatetest127BC.json                                       Fail
- randomStatetest128BC.json                                       Fail
- randomStatetest132BC.json                                       Fail
- randomStatetest140BC.json                                       Fail
- randomStatetest141BC.json                                       Fail
- randomStatetest152BC.json                                       Fail
- randomStatetest165BC.json                                       Fail
- randomStatetest168BC.json                                       Fail
- randomStatetest181BC.json                                       Fail
- randomStatetest182BC.json                                       Fail
- randomStatetest186BC.json                                       Fail
- randomStatetest193BC.json                                       Fail
- randomStatetest203BC.json                                       Fail
- randomStatetest213BC.json                                       Fail
- randomStatetest218BC.json                                       Fail
- randomStatetest21BC.json                                        Fail
- randomStatetest224BC.json                                       Fail
- randomStatetest234BC.json                                       Fail
- randomStatetest235BC.json                                       Fail
- randomStatetest239BC.json                                       Fail
- randomStatetest240BC.json                                       Fail
- randomStatetest253BC.json                                       Fail
- randomStatetest255BC.json                                       Fail
- randomStatetest256BC.json                                       Fail
- randomStatetest258BC.json                                       Fail
- randomStatetest262BC.json                                       Fail
- randomStatetest272BC.json                                       Fail
- randomStatetest277BC.json                                       Fail
- randomStatetest284BC.json                                       Fail
- randomStatetest289BC.json                                       Fail
- randomStatetest314BC.json                                       Fail
- randomStatetest317BC.json                                       Fail
- randomStatetest319BC.json                                       Fail
- randomStatetest32BC.json                                        Fail
- randomStatetest330BC.json                                       Fail
- randomStatetest331BC.json                                       Fail
- randomStatetest344BC.json                                       Fail
- randomStatetest34BC.json                                        Fail
- randomStatetest35BC.json                                        Fail
- randomStatetest373BC.json                                       Fail
- randomStatetest374BC.json                                       Fail
- randomStatetest390BC.json                                       Fail
- randomStatetest392BC.json                                       Fail
- randomStatetest394BC.json                                       Fail
- randomStatetest400BC.json                                       Fail
- randomStatetest403BC.json                                       Fail
- randomStatetest40BC.json                                        Fail
- randomStatetest423BC.json                                       Fail
- randomStatetest427BC.json                                       Fail
- randomStatetest431BC.json                                       Fail
- randomStatetest432BC.json                                       Fail
- randomStatetest434BC.json                                       Fail
- randomStatetest44BC.json                                        Fail
- randomStatetest453BC.json                                       Fail
- randomStatetest459BC.json                                       Fail
- randomStatetest463BC.json                                       Fail
- randomStatetest468BC.json                                       Fail
- randomStatetest479BC.json                                       Fail
- randomStatetest486BC.json                                       Fail
- randomStatetest490BC.json                                       Fail
- randomStatetest492BC.json                                       Fail
- randomStatetest50BC.json                                        Fail
- randomStatetest515BC.json                                       Fail
- randomStatetest522BC.json                                       Fail
- randomStatetest529BC.json                                       Fail
- randomStatetest530BC.json                                       Fail
- randomStatetest538BC.json                                       Fail
- randomStatetest540BC.json                                       Fail
- randomStatetest551BC.json                                       Fail
- randomStatetest557BC.json                                       Fail
- randomStatetest561BC.json                                       Fail
- randomStatetest568BC.json                                       Fail
- randomStatetest56BC.json                                        Fail
- randomStatetest570BC.json                                       Fail
- randomStatetest573BC.json                                       Fail
- randomStatetest590BC.json                                       Fail
- randomStatetest591BC.json                                       Fail
- randomStatetest593BC.json                                       Fail
- randomStatetest595BC.json                                       Fail
- randomStatetest598BC.json                                       Fail
- randomStatetest606BC.json                                       Fail
- randomStatetest613BC.json                                       Fail
- randomStatetest614BC.json                                       Fail
- randomStatetest617BC.json                                       Fail
- randomStatetest61BC.json                                        Fail
- randomStatetest622BC.json                                       Fail
- randomStatetest623BC.json                                       Fail
- randomStatetest631BC.json                                       Fail
- randomStatetest634BC.json                                       Fail
- randomStatetest65BC.json                                        Fail
- randomStatetest68BC.json                                        Fail
- randomStatetest70BC.json                                        Fail
- randomStatetest71BC.json                                        Fail
- randomStatetest76BC.json                                        Fail
- randomStatetest79BC.json                                        Fail
- randomStatetest7BC.json                                         Fail
- randomStatetest86BC.json                                        Fail
- randomStatetest8BC.json                                         Fail
- randomStatetest91BC.json                                        Fail
- randomStatetest93BC.json                                        Fail
- randomStatetest99BC.json                                        Fail
```
OK: 0/105 Fail: 105/105 Skip: 0/105
## bcStateTests
```diff
- BLOCKHASH_Bounds.json                                           Fail
- BadStateRootTxBC.json                                           Fail
- CreateTransactionReverted.json                                  Fail
+ EmptyTransaction.json                                           OK
- EmptyTransaction2.json                                          Fail
+ NotEnoughCashContractCreation.json                              OK
- OOGStateCopyContainingDeletedContract.json                      Fail
- OverflowGasRequire.json                                         Fail
- RefundOverflow.json                                             Fail
- RefundOverflow2.json                                            Fail
- SuicidesMixingCoinbase.json                                     Fail
- SuicidesMixingCoinbase2.json                                    Fail
- TransactionFromCoinbaseHittingBlockGasLimit1.json               Fail
+ TransactionFromCoinbaseNotEnoughFounds.json                     OK
+ TransactionNonceCheck.json                                      OK
+ TransactionNonceCheck2.json                                     OK
+ TransactionToItselfNotEnoughFounds.json                         OK
+ UserTransactionGasLimitIsTooLowWhenZeroCost.json                OK
- UserTransactionZeroCost.json                                    Fail
- UserTransactionZeroCost2.json                                   Fail
- UserTransactionZeroCostWithData.json                            Fail
+ ZeroValue_TransactionCALL_OOGRevert.json                        OK
+ ZeroValue_TransactionCALL_ToEmpty_OOGRevert.json                OK
+ ZeroValue_TransactionCALL_ToEmpty_OOGRevert_Paris.json          OK
+ ZeroValue_TransactionCALL_ToNonZeroBalance_OOGRevert.json       OK
+ ZeroValue_TransactionCALL_ToOneStorageKey_OOGRevert.json        OK
+ ZeroValue_TransactionCALL_ToOneStorageKey_OOGRevert_Paris.json  OK
- ZeroValue_TransactionCALLwithData_OOGRevert.json                Fail
- ZeroValue_TransactionCALLwithData_ToEmpty_OOGRevert.json        Fail
+ ZeroValue_TransactionCALLwithData_ToEmpty_OOGRevert_Istanbul.js OK
+ ZeroValue_TransactionCALLwithData_ToEmpty_OOGRevert_Istanbul_Pa OK
- ZeroValue_TransactionCALLwithData_ToEmpty_OOGRevert_Paris.json  Fail
- ZeroValue_TransactionCALLwithData_ToNonZeroBalance_OOGRevert.js Fail
- ZeroValue_TransactionCALLwithData_ToOneStorageKey_OOGRevert.jso Fail
+ ZeroValue_TransactionCALLwithData_ToOneStorageKey_OOGRevert_Ist OK
+ ZeroValue_TransactionCALLwithData_ToOneStorageKey_OOGRevert_Ist OK
- ZeroValue_TransactionCALLwithData_ToOneStorageKey_OOGRevert_Par Fail
- blockhashNonConstArg.json                                       Fail
- blockhashTests.json                                             Fail
- callcodeOutput1.json                                            Fail
- callcodeOutput2.json                                            Fail
- callcodeOutput3partial.json                                     Fail
- create2collisionwithSelfdestructSameBlock.json                  Fail
+ createNameRegistratorPerTxsNotEnoughGasAfter.json               OK
- createNameRegistratorPerTxsNotEnoughGasAt.json                  Fail
+ createNameRegistratorPerTxsNotEnoughGasBefore.json              OK
+ createRevert.json                                               OK
- dataTx.json                                                     Fail
- extCodeHashOfDeletedAccount.json                                Fail
- extCodeHashOfDeletedAccountDynamic.json                         Fail
- extcodehashEmptySuicide.json                                    Fail
+ gasLimitTooHigh.json                                            OK
- logRevert.json                                                  Fail
- multimpleBalanceInstruction.json                                Fail
- random.json                                                     Fail
- randomStatetest123.json                                         Fail
- randomStatetest136.json                                         Fail
- randomStatetest160.json                                         Fail
- randomStatetest170.json                                         Fail
- randomStatetest223.json                                         Fail
- randomStatetest229.json                                         Fail
- randomStatetest241.json                                         Fail
- randomStatetest324.json                                         Fail
- randomStatetest328.json                                         Fail
- randomStatetest375.json                                         Fail
- randomStatetest377.json                                         Fail
- randomStatetest38.json                                          Fail
- randomStatetest441.json                                         Fail
- randomStatetest46.json                                          Fail
- randomStatetest549.json                                         Fail
- randomStatetest594.json                                         Fail
- randomStatetest619.json                                         Fail
  randomStatetest94.json                                          Skip
- refundReset.json                                                Fail
- selfdestructBalance.json                                        Fail
- simpleSuicide.json                                              Fail
- suicideCoinbase.json                                            Fail
- suicideCoinbaseState.json                                       Fail
- suicideStorageCheck.json                                        Fail
- suicideStorageCheckVCreate.json                                 Fail
- suicideStorageCheckVCreate2.json                                Fail
- suicideThenCheckBalance.json                                    Fail
- testOpcode_00.json                                              Fail
- testOpcode_10.json                                              Fail
- testOpcode_20.json                                              Fail
- testOpcode_30.json                                              Fail
- testOpcode_40.json                                              Fail
- testOpcode_50.json                                              Fail
- testOpcode_60.json                                              Fail
- testOpcode_70.json                                              Fail
- testOpcode_80.json                                              Fail
- testOpcode_90.json                                              Fail
- testOpcode_a0.json                                              Fail
- testOpcode_b0.json                                              Fail
- testOpcode_c0.json                                              Fail
- testOpcode_d0.json                                              Fail
- testOpcode_f0.json                                              Fail
- transactionFromNotExistingAccount.json                          Fail
- transactionFromSelfDestructedContract.json                      Fail
+ txCost-sec73.json                                               OK
```
OK: 22/100 Fail: 77/100 Skip: 1/100
## bcTotalDifficultyTest
```diff
- lotsOfBranchesOverrideAtTheEnd.json                             Fail
- lotsOfBranchesOverrideAtTheMiddle.json                          Fail
- newChainFrom4Block.json                                         Fail
- newChainFrom5Block.json                                         Fail
- newChainFrom6Block.json                                         Fail
- sideChainWithMoreTransactions.json                              Fail
- sideChainWithMoreTransactions2.json                             Fail
- sideChainWithNewMaxDifficultyStartingFromBlock3AfterBlock4.json Fail
- uncleBlockAtBlock3AfterBlock3.json                              Fail
- uncleBlockAtBlock3afterBlock4.json                              Fail
```
OK: 0/10 Fail: 10/10 Skip: 0/10
## bcUncleHeaderValidity
```diff
- correct.json                                                    Fail
- diffTooHigh.json                                                Fail
- diffTooLow.json                                                 Fail
- diffTooLow2.json                                                Fail
- gasLimitLTGasUsageUncle.json                                    Fail
- gasLimitTooHigh.json                                            Fail
- gasLimitTooHighExactBound.json                                  Fail
- gasLimitTooLow.json                                             Fail
- gasLimitTooLowExactBound.json                                   Fail
- gasLimitTooLowExactBound2.json                                  Fail
- gasLimitTooLowExactBoundLondon.json                             Fail
- incorrectUncleNumber0.json                                      Fail
- incorrectUncleNumber1.json                                      Fail
- incorrectUncleNumber500.json                                    Fail
- incorrectUncleTimestamp.json                                    Fail
- incorrectUncleTimestamp2.json                                   Fail
- incorrectUncleTimestamp3.json                                   Fail
- incorrectUncleTimestamp4.json                                   Fail
- incorrectUncleTimestamp5.json                                   Fail
- pastUncleTimestamp.json                                         Fail
- timestampTooHigh.json                                           Fail
- timestampTooLow.json                                            Fail
- unknownUncleParentHash.json                                     Fail
- wrongParentHash.json                                            Fail
- wrongStateRoot.json                                             Fail
```
OK: 0/25 Fail: 25/25 Skip: 0/25
## bcUncleSpecialTests
```diff
- futureUncleTimestamp2.json                                      Fail
- futureUncleTimestamp3.json                                      Fail
- futureUncleTimestampDifficultyDrop.json                         Fail
- futureUncleTimestampDifficultyDrop2.json                        Fail
- futureUncleTimestampDifficultyDrop3.json                        Fail
- futureUncleTimestampDifficultyDrop4.json                        Fail
- uncleBloomNot0.json                                             Fail
- uncleBloomNot0_2.json                                           Fail
- uncleBloomNot0_3.json                                           Fail
```
OK: 0/9 Fail: 9/9 Skip: 0/9
## bcUncleTest
```diff
- EqualUncleInTwoDifferentBlocks.json                             Fail
- EqualUncleInTwoDifferentBlocks2.json                            Fail
- InChainUncle.json                                               Fail
- InChainUncleFather.json                                         Fail
- InChainUncleGrandPa.json                                        Fail
- InChainUncleGreatGrandPa.json                                   Fail
- InChainUncleGreatGreatGrandPa.json                              Fail
- InChainUncleGreatGreatGreatGrandPa.json                         Fail
- InChainUncleGreatGreatGreatGreatGrandPa.json                    Fail
- UncleIsBrother.json                                             Fail
- oneUncle.json                                                   Fail
- oneUncleGeneration2.json                                        Fail
- oneUncleGeneration3.json                                        Fail
- oneUncleGeneration4.json                                        Fail
- oneUncleGeneration5.json                                        Fail
- oneUncleGeneration6.json                                        Fail
- oneUncleGeneration7.json                                        Fail
- threeUncle.json                                                 Fail
- twoEqualUncle.json                                              Fail
- twoUncle.json                                                   Fail
- uncleHeaderAtBlock2.json                                        Fail
- uncleHeaderWithGeneration0.json                                 Fail
- uncleWithSameBlockNumber.json                                   Fail
```
OK: 0/23 Fail: 23/23 Skip: 0/23
## bcValidBlockTest
```diff
- ExtraData32.json                                                Fail
- RecallSuicidedContract.json                                     Fail
- RecallSuicidedContractInOneBlock.json                           Fail
- SimpleTx.json                                                   Fail
- SimpleTx3LowS.json                                              Fail
- callRevert.json                                                 Fail
- dataTx2.json                                                    Fail
- diff1024.json                                                   Fail
- eip2930.json                                                    Fail
- emptyPostTransfer.json                                          Fail
- gasLimitTooHigh2.json                                           Fail
- gasPrice0.json                                                  Fail
- log1_correct.json                                               Fail
- reentrencySuicide.json                                          Fail
- timeDiff12.json                                                 Fail
- timeDiff13.json                                                 Fail
- timeDiff14.json                                                 Fail
```
OK: 0/17 Fail: 17/17 Skip: 0/17
## bcWalletTest
```diff
- wallet2outOf3txs.json                                           Fail
- wallet2outOf3txs2.json                                          Fail
- wallet2outOf3txsRevoke.json                                     Fail
- wallet2outOf3txsRevokeAndConfirmAgain.json                      Fail
- walletReorganizeOwners.json                                     Fail
```
OK: 0/5 Fail: 5/5 Skip: 0/5
## create2
```diff
- recreate.json                                                   Fail
```
OK: 0/1 Fail: 1/1 Skip: 0/1
## eip1153_tstore
```diff
+ contract_creation.json                                          OK
+ gas_usage.json                                                  OK
+ reentrant_call.json                                             OK
+ reentrant_selfdestructing_call.json                             OK
+ run_until_out_of_gas.json                                       OK
+ subcall.json                                                    OK
+ tload_after_sstore.json                                         OK
+ tload_after_tstore.json                                         OK
+ tload_after_tstore_is_zero.json                                 OK
+ transient_storage_unset_values.json                             OK
```
OK: 10/10 Fail: 0/10 Skip: 0/10
## eip1344_chainid
```diff
- chainid.json                                                    Fail
```
OK: 0/1 Fail: 1/1 Skip: 0/1
## eip198_modexp_precompile
```diff
- modexp.json                                                     Fail
```
OK: 0/1 Fail: 1/1 Skip: 0/1
## eip2930_access_list
```diff
- access_list.json                                                Fail
```
OK: 0/1 Fail: 1/1 Skip: 0/1
## eip3651_warm_coinbase
```diff
- warm_coinbase_call_out_of_gas.json                              Fail
- warm_coinbase_gas_usage.json                                    Fail
```
OK: 0/2 Fail: 2/2 Skip: 0/2
## eip3855_push0
```diff
- push0_before_jumpdest.json                                      Fail
- push0_during_staticcall.json                                    Fail
- push0_fill_stack.json                                           Fail
- push0_gas_cost.json                                             Fail
- push0_key_sstore.json                                           Fail
- push0_stack_overflow.json                                       Fail
- push0_storage_overwrite.json                                    Fail
```
OK: 0/7 Fail: 7/7 Skip: 0/7
## eip3860_initcode
```diff
- contract_creating_tx.json                                       Fail
- create_opcode_initcode.json                                     Fail
- gas_usage.json                                                  Fail
```
OK: 0/3 Fail: 3/3 Skip: 0/3
## eip4788_beacon_root
```diff
+ beacon_root_contract_calls.json                                 OK
- beacon_root_contract_deploy.json                                Fail
+ beacon_root_contract_timestamps.json                            OK
+ beacon_root_equal_to_timestamp.json                             OK
+ beacon_root_selfdestruct.json                                   OK
- beacon_root_transition.json                                     Fail
+ calldata_lengths.json                                           OK
+ invalid_beacon_root_calldata_value.json                         OK
+ multi_block_beacon_root_timestamp_calls.json                    OK
+ no_beacon_root_contract_at_transition.json                      OK
+ tx_to_beacon_root_contract.json                                 OK
```
OK: 9/11 Fail: 2/11 Skip: 0/11
## eip4844_blobs
```diff
+ blob_gas_subtraction_tx.json                                    OK
+ blob_tx_attribute_calldata_opcodes.json                         OK
+ blob_tx_attribute_gasprice_opcode.json                          OK
+ blob_tx_attribute_opcodes.json                                  OK
+ blob_tx_attribute_value_opcode.json                             OK
+ blob_type_tx_pre_fork.json                                      OK
+ blobhash_gas_cost.json                                          OK
+ blobhash_invalid_blob_index.json                                OK
+ blobhash_multiple_txs_in_block.json                             OK
+ blobhash_opcode_contexts.json                                   OK
+ blobhash_scenarios.json                                         OK
+ correct_decreasing_blob_gas_costs.json                          OK
+ correct_excess_blob_gas_calculation.json                        OK
+ correct_increasing_blob_gas_costs.json                          OK
+ fork_transition_excess_blob_gas.json                            OK
+ insufficient_balance_blob_tx.json                               OK
+ insufficient_balance_blob_tx_combinations.json                  OK
+ invalid_blob_gas_used_in_header.json                            OK
+ invalid_blob_hash_versioning_multiple_txs.json                  OK
+ invalid_blob_hash_versioning_single_tx.json                     OK
+ invalid_blob_tx_contract_creation.json                          OK
+ invalid_block_blob_count.json                                   OK
+ invalid_excess_blob_gas_above_target_change.json                OK
+ invalid_excess_blob_gas_change.json                             OK
+ invalid_excess_blob_gas_target_blobs_increase_from_zero.json    OK
+ invalid_negative_excess_blob_gas.json                           OK
+ invalid_non_multiple_excess_blob_gas.json                       OK
+ invalid_normal_gas.json                                         OK
+ invalid_post_fork_block_without_blob_fields.json                OK
+ invalid_pre_fork_block_with_blob_fields.json                    OK
+ invalid_precompile_calls.json                                   OK
+ invalid_static_excess_blob_gas.json                             OK
+ invalid_static_excess_blob_gas_from_zero_on_blobs_above_target. OK
+ invalid_tx_blob_count.json                                      OK
+ invalid_tx_max_fee_per_blob_gas.json                            OK
+ invalid_zero_excess_blob_gas_in_header.json                     OK
- point_evaluation_precompile_before_fork.json                    Fail
+ point_evaluation_precompile_calls.json                          OK
- point_evaluation_precompile_during_fork.json                    Fail
+ point_evaluation_precompile_external_vectors.json               OK
+ point_evaluation_precompile_gas_tx_to.json                      OK
+ point_evaluation_precompile_gas_usage.json                      OK
+ reject_valid_full_blob_in_block_rlp.json                        OK
+ sufficient_balance_blob_tx.json                                 OK
+ sufficient_balance_blob_tx_pre_fund_tx.json                     OK
+ valid_blob_tx_combinations.json                                 OK
+ valid_precompile_calls.json                                     OK
```
OK: 45/47 Fail: 2/47 Skip: 0/47
## eip4895_withdrawals
```diff
- balance_within_block.json                                       Fail
+ large_amount.json                                               OK
+ many_withdrawals.json                                           OK
+ multiple_withdrawals_same_address.json                          OK
- newly_created_contract.json                                     Fail
- no_evm_execution.json                                           Fail
- self_destructing_account.json                                   Fail
- use_value_in_contract.json                                      Fail
- use_value_in_tx.json                                            Fail
- withdrawing_to_precompiles.json                                 Fail
+ zero_amount.json                                                OK
```
OK: 4/11 Fail: 7/11 Skip: 0/11
## eip5656_mcopy
```diff
+ mcopy_huge_memory_expansion.json                                OK
+ mcopy_memory_expansion.json                                     OK
+ mcopy_on_empty_memory.json                                      OK
+ no_memory_corruption_on_upper_call_stack_levels.json            OK
+ valid_mcopy_operations.json                                     OK
```
OK: 5/5 Fail: 0/5 Skip: 0/5
## eip6780_selfdestruct
```diff
- create_selfdestruct_same_tx.json                                Fail
- delegatecall_from_new_contract_to_pre_existing_contract.json    Fail
- delegatecall_from_pre_existing_contract_to_new_contract.json    Fail
- dynamic_create2_selfdestruct_collision.json                     Fail
- dynamic_create2_selfdestruct_collision_multi_tx.json            Fail
- dynamic_create2_selfdestruct_collision_two_different_transactio Fail
- recreate_self_destructed_contract_different_txs.json            Fail
- reentrancy_selfdestruct_revert.json                             Fail
- self_destructing_initcode.json                                  Fail
- self_destructing_initcode_create_tx.json                        Fail
+ selfdestruct_created_in_same_tx_with_revert.json                OK
- selfdestruct_created_same_block_different_tx.json               Fail
+ selfdestruct_not_created_in_same_tx_with_revert.json            OK
- selfdestruct_pre_existing.json                                  Fail
```
OK: 2/14 Fail: 12/14 Skip: 0/14
## eip7516_blobgasfee
```diff
- blobbasefee_before_fork.json                                    Fail
- blobbasefee_during_fork.json                                    Fail
+ blobbasefee_out_of_gas.json                                     OK
+ blobbasefee_stack_overflow.json                                 OK
```
OK: 2/4 Fail: 2/4 Skip: 0/4
## opcodes
```diff
- double_kill.json                                                Fail
- dup.json                                                        Fail
- value_transfer_gas_calculation.json                             Fail
```
OK: 0/3 Fail: 3/3 Skip: 0/3
## security
```diff
- tx_selfdestruct_balance_bug.json                                Fail
```
OK: 0/1 Fail: 1/1 Skip: 0/1
## stArgsZeroOneBalance
```diff
- addNonConst.json                                                Fail
- addmodNonConst.json                                             Fail
- andNonConst.json                                                Fail
- balanceNonConst.json                                            Fail
- byteNonConst.json                                               Fail
- callNonConst.json                                               Fail
- callcodeNonConst.json                                           Fail
- calldatacopyNonConst.json                                       Fail
- calldataloadNonConst.json                                       Fail
- codecopyNonConst.json                                           Fail
- createNonConst.json                                             Fail
- delegatecallNonConst.json                                       Fail
- divNonConst.json                                                Fail
- eqNonConst.json                                                 Fail
- expNonConst.json                                                Fail
- extcodecopyNonConst.json                                        Fail
- extcodesizeNonConst.json                                        Fail
- gtNonConst.json                                                 Fail
- iszeroNonConst.json                                             Fail
- jumpNonConst.json                                               Fail
- jumpiNonConst.json                                              Fail
- log0NonConst.json                                               Fail
- log1NonConst.json                                               Fail
- log2NonConst.json                                               Fail
- log3NonConst.json                                               Fail
- ltNonConst.json                                                 Fail
- mloadNonConst.json                                              Fail
- modNonConst.json                                                Fail
- mstore8NonConst.json                                            Fail
- mstoreNonConst.json                                             Fail
- mulNonConst.json                                                Fail
- mulmodNonConst.json                                             Fail
- notNonConst.json                                                Fail
- orNonConst.json                                                 Fail
- returnNonConst.json                                             Fail
- sdivNonConst.json                                               Fail
- sgtNonConst.json                                                Fail
- sha3NonConst.json                                               Fail
- signextNonConst.json                                            Fail
- sloadNonConst.json                                              Fail
- sltNonConst.json                                                Fail
- smodNonConst.json                                               Fail
- sstoreNonConst.json                                             Fail
- subNonConst.json                                                Fail
- suicideNonConst.json                                            Fail
- xorNonConst.json                                                Fail
```
OK: 0/46 Fail: 46/46 Skip: 0/46
## stAttackTest
```diff
  ContractCreationSpam.json                                       Skip
- CrashingTransaction.json                                        Fail
```
OK: 0/2 Fail: 1/2 Skip: 1/2
## stBadOpcode
```diff
- badOpcodes.json                                                 Fail
- eip2315NotRemoved.json                                          Fail
- invalidAddr.json                                                Fail
- invalidDiffPlaces.json                                          Fail
- measureGas.json                                                 Fail
- opc0CDiffPlaces.json                                            Fail
- opc0DDiffPlaces.json                                            Fail
- opc0EDiffPlaces.json                                            Fail
- opc0FDiffPlaces.json                                            Fail
- opc1EDiffPlaces.json                                            Fail
- opc1FDiffPlaces.json                                            Fail
- opc21DiffPlaces.json                                            Fail
- opc22DiffPlaces.json                                            Fail
- opc23DiffPlaces.json                                            Fail
- opc24DiffPlaces.json                                            Fail
- opc25DiffPlaces.json                                            Fail
- opc26DiffPlaces.json                                            Fail
- opc27DiffPlaces.json                                            Fail
- opc28DiffPlaces.json                                            Fail
- opc29DiffPlaces.json                                            Fail
- opc2ADiffPlaces.json                                            Fail
- opc2BDiffPlaces.json                                            Fail
- opc2CDiffPlaces.json                                            Fail
- opc2DDiffPlaces.json                                            Fail
- opc2EDiffPlaces.json                                            Fail
- opc2FDiffPlaces.json                                            Fail
- opc49DiffPlaces.json                                            Fail
- opc4ADiffPlaces.json                                            Fail
- opc4BDiffPlaces.json                                            Fail
- opc4CDiffPlaces.json                                            Fail
- opc4DDiffPlaces.json                                            Fail
- opc4EDiffPlaces.json                                            Fail
- opc4FDiffPlaces.json                                            Fail
- opc5CDiffPlaces.json                                            Fail
- opc5DDiffPlaces.json                                            Fail
- opc5EDiffPlaces.json                                            Fail
- opc5FDiffPlaces.json                                            Fail
- opcA5DiffPlaces.json                                            Fail
- opcA6DiffPlaces.json                                            Fail
- opcA7DiffPlaces.json                                            Fail
- opcA8DiffPlaces.json                                            Fail
- opcA9DiffPlaces.json                                            Fail
- opcAADiffPlaces.json                                            Fail
- opcABDiffPlaces.json                                            Fail
- opcACDiffPlaces.json                                            Fail
- opcADDiffPlaces.json                                            Fail
- opcAEDiffPlaces.json                                            Fail
- opcAFDiffPlaces.json                                            Fail
- opcB0DiffPlaces.json                                            Fail
- opcB1DiffPlaces.json                                            Fail
- opcB2DiffPlaces.json                                            Fail
- opcB3DiffPlaces.json                                            Fail
- opcB4DiffPlaces.json                                            Fail
- opcB5DiffPlaces.json                                            Fail
- opcB6DiffPlaces.json                                            Fail
- opcB7DiffPlaces.json                                            Fail
- opcB8DiffPlaces.json                                            Fail
- opcB9DiffPlaces.json                                            Fail
- opcBADiffPlaces.json                                            Fail
- opcBBDiffPlaces.json                                            Fail
- opcBCDiffPlaces.json                                            Fail
- opcBDDiffPlaces.json                                            Fail
- opcBEDiffPlaces.json                                            Fail
- opcBFDiffPlaces.json                                            Fail
- opcC0DiffPlaces.json                                            Fail
- opcC1DiffPlaces.json                                            Fail
- opcC2DiffPlaces.json                                            Fail
- opcC3DiffPlaces.json                                            Fail
- opcC4DiffPlaces.json                                            Fail
- opcC5DiffPlaces.json                                            Fail
- opcC6DiffPlaces.json                                            Fail
- opcC7DiffPlaces.json                                            Fail
- opcC8DiffPlaces.json                                            Fail
- opcC9DiffPlaces.json                                            Fail
- opcCADiffPlaces.json                                            Fail
- opcCBDiffPlaces.json                                            Fail
- opcCCDiffPlaces.json                                            Fail
- opcCDDiffPlaces.json                                            Fail
- opcCEDiffPlaces.json                                            Fail
- opcCFDiffPlaces.json                                            Fail
- opcD0DiffPlaces.json                                            Fail
- opcD1DiffPlaces.json                                            Fail
- opcD2DiffPlaces.json                                            Fail
- opcD3DiffPlaces.json                                            Fail
- opcD4DiffPlaces.json                                            Fail
- opcD5DiffPlaces.json                                            Fail
- opcD6DiffPlaces.json                                            Fail
- opcD7DiffPlaces.json                                            Fail
- opcD8DiffPlaces.json                                            Fail
- opcD9DiffPlaces.json                                            Fail
- opcDADiffPlaces.json                                            Fail
- opcDBDiffPlaces.json                                            Fail
- opcDCDiffPlaces.json                                            Fail
- opcDDDiffPlaces.json                                            Fail
- opcDEDiffPlaces.json                                            Fail
- opcDFDiffPlaces.json                                            Fail
- opcE0DiffPlaces.json                                            Fail
- opcE1DiffPlaces.json                                            Fail
- opcE2DiffPlaces.json                                            Fail
- opcE3DiffPlaces.json                                            Fail
- opcE4DiffPlaces.json                                            Fail
- opcE5DiffPlaces.json                                            Fail
- opcE6DiffPlaces.json                                            Fail
- opcE7DiffPlaces.json                                            Fail
- opcE8DiffPlaces.json                                            Fail
- opcE9DiffPlaces.json                                            Fail
- opcEADiffPlaces.json                                            Fail
- opcEBDiffPlaces.json                                            Fail
- opcECDiffPlaces.json                                            Fail
- opcEDDiffPlaces.json                                            Fail
- opcEEDiffPlaces.json                                            Fail
- opcEFDiffPlaces.json                                            Fail
- opcF6DiffPlaces.json                                            Fail
- opcF7DiffPlaces.json                                            Fail
- opcF8DiffPlaces.json                                            Fail
- opcF9DiffPlaces.json                                            Fail
- opcFBDiffPlaces.json                                            Fail
- opcFCDiffPlaces.json                                            Fail
- opcFEDiffPlaces.json                                            Fail
- operationDiffGas.json                                           Fail
- undefinedOpcodeFirstByte.json                                   Fail
```
OK: 0/121 Fail: 121/121 Skip: 0/121
## stBugs
```diff
- evmBytecode.json                                                Fail
- randomStatetestDEFAULT-Tue_07_58_41-15153-575192.json           Fail
- randomStatetestDEFAULT-Tue_07_58_41-15153-575192_london.json    Fail
- returndatacopyPythonBug_Tue_03_48_41-1432.json                  Fail
- staticcall_createfails.json                                     Fail
```
OK: 0/5 Fail: 5/5 Skip: 0/5
## stCallCodes
```diff
- call_OOG_additionalGasCosts1.json                               Fail
- call_OOG_additionalGasCosts2.json                               Fail
- callcall_00.json                                                Fail
- callcall_00_OOGE.json                                           Fail
- callcall_00_OOGE_valueTransfer.json                             Fail
- callcall_00_SuicideEnd.json                                     Fail
- callcallcall_000.json                                           Fail
- callcallcall_000_OOGE.json                                      Fail
- callcallcall_000_OOGMAfter.json                                 Fail
- callcallcall_000_OOGMBefore.json                                Fail
- callcallcall_000_SuicideEnd.json                                Fail
- callcallcall_000_SuicideMiddle.json                             Fail
- callcallcall_ABCB_RECURSIVE.json                                Fail
- callcallcallcode_001.json                                       Fail
- callcallcallcode_001_OOGE.json                                  Fail
- callcallcallcode_001_OOGMAfter.json                             Fail
- callcallcallcode_001_OOGMBefore.json                            Fail
- callcallcallcode_001_SuicideEnd.json                            Fail
- callcallcallcode_001_SuicideMiddle.json                         Fail
  callcallcallcode_ABCB_RECURSIVE.json                            Skip
- callcallcode_01.json                                            Fail
- callcallcode_01_OOGE.json                                       Fail
- callcallcode_01_SuicideEnd.json                                 Fail
- callcallcodecall_010.json                                       Fail
- callcallcodecall_010_OOGE.json                                  Fail
- callcallcodecall_010_OOGMAfter.json                             Fail
- callcallcodecall_010_OOGMBefore.json                            Fail
- callcallcodecall_010_SuicideEnd.json                            Fail
- callcallcodecall_010_SuicideMiddle.json                         Fail
  callcallcodecall_ABCB_RECURSIVE.json                            Skip
- callcallcodecallcode_011.json                                   Fail
- callcallcodecallcode_011_OOGE.json                              Fail
- callcallcodecallcode_011_OOGMAfter.json                         Fail
- callcallcodecallcode_011_OOGMBefore.json                        Fail
- callcallcodecallcode_011_SuicideEnd.json                        Fail
- callcallcodecallcode_011_SuicideMiddle.json                     Fail
  callcallcodecallcode_ABCB_RECURSIVE.json                        Skip
- callcodeDynamicCode.json                                        Fail
- callcodeDynamicCode2SelfCall.json                               Fail
- callcodeEmptycontract.json                                      Fail
- callcodeInInitcodeToEmptyContract.json                          Fail
- callcodeInInitcodeToExisContractWithVTransferNEMoney.json       Fail
- callcodeInInitcodeToExistingContract.json                       Fail
- callcodeInInitcodeToExistingContractWithValueTransfer.json      Fail
- callcode_checkPC.json                                           Fail
- callcodecall_10.json                                            Fail
- callcodecall_10_OOGE.json                                       Fail
- callcodecall_10_SuicideEnd.json                                 Fail
- callcodecallcall_100.json                                       Fail
- callcodecallcall_100_OOGE.json                                  Fail
- callcodecallcall_100_OOGMAfter.json                             Fail
- callcodecallcall_100_OOGMBefore.json                            Fail
- callcodecallcall_100_SuicideEnd.json                            Fail
- callcodecallcall_100_SuicideMiddle.json                         Fail
  callcodecallcall_ABCB_RECURSIVE.json                            Skip
- callcodecallcallcode_101.json                                   Fail
- callcodecallcallcode_101_OOGE.json                              Fail
- callcodecallcallcode_101_OOGMAfter.json                         Fail
- callcodecallcallcode_101_OOGMBefore.json                        Fail
- callcodecallcallcode_101_SuicideEnd.json                        Fail
- callcodecallcallcode_101_SuicideMiddle.json                     Fail
  callcodecallcallcode_ABCB_RECURSIVE.json                        Skip
- callcodecallcode_11.json                                        Fail
- callcodecallcode_11_OOGE.json                                   Fail
- callcodecallcode_11_SuicideEnd.json                             Fail
- callcodecallcodecall_110.json                                   Fail
- callcodecallcodecall_110_OOGE.json                              Fail
- callcodecallcodecall_110_OOGMAfter.json                         Fail
- callcodecallcodecall_110_OOGMBefore.json                        Fail
- callcodecallcodecall_110_SuicideEnd.json                        Fail
- callcodecallcodecall_110_SuicideMiddle.json                     Fail
  callcodecallcodecall_ABCB_RECURSIVE.json                        Skip
- callcodecallcodecallcode_111.json                               Fail
- callcodecallcodecallcode_111_OOGE.json                          Fail
- callcodecallcodecallcode_111_OOGMAfter.json                     Fail
- callcodecallcodecallcode_111_OOGMBefore.json                    Fail
- callcodecallcodecallcode_111_SuicideEnd.json                    Fail
- callcodecallcodecallcode_111_SuicideMiddle.json                 Fail
  callcodecallcodecallcode_ABCB_RECURSIVE.json                    Skip
- touchAndGo.json                                                 Fail
```
OK: 0/80 Fail: 73/80 Skip: 7/80
## stCallCreateCallCodeTest
```diff
  Call1024BalanceTooLow.json                                      Skip
  Call1024OOG.json                                                Skip
  Call1024PreCalls.json                                           Skip
- CallLoseGasOOG.json                                             Fail
  CallRecursiveBombPreCall.json                                   Skip
  Callcode1024BalanceTooLow.json                                  Skip
  Callcode1024OOG.json                                            Skip
- CallcodeLoseGasOOG.json                                         Fail
- callOutput1.json                                                Fail
- callOutput2.json                                                Fail
- callOutput3.json                                                Fail
- callOutput3Fail.json                                            Fail
- callOutput3partial.json                                         Fail
- callOutput3partialFail.json                                     Fail
- callWithHighValue.json                                          Fail
- callWithHighValueAndGasOOG.json                                 Fail
- callWithHighValueAndOOGatTxLevel.json                           Fail
- callWithHighValueOOGinCall.json                                 Fail
- callcodeOutput1.json                                            Fail
- callcodeOutput2.json                                            Fail
- callcodeOutput3.json                                            Fail
- callcodeOutput3Fail.json                                        Fail
- callcodeOutput3partial.json                                     Fail
- callcodeOutput3partialFail.json                                 Fail
- callcodeWithHighValue.json                                      Fail
- callcodeWithHighValueAndGasOOG.json                             Fail
- contractCreationMakeCallThatAskMoreGasThenTransactionProvided.j Fail
- createFailBalanceTooLow.json                                    Fail
- createInitFailBadJumpDestination.json                           Fail
- createInitFailBadJumpDestination2.json                          Fail
- createInitFailStackSizeLargerThan1024.json                      Fail
- createInitFailStackUnderflow.json                               Fail
- createInitFailUndefinedInstruction.json                         Fail
- createInitFailUndefinedInstruction2.json                        Fail
- createInitFail_OOGduringInit.json                               Fail
- createInitFail_OOGduringInit2.json                              Fail
- createInitOOGforCREATE.json                                     Fail
- createJS_ExampleContract.json                                   Fail
- createJS_NoCollision.json                                       Fail
- createNameRegistratorPerTxs.json                                Fail
- createNameRegistratorPerTxsNotEnoughGas.json                    Fail
- createNameRegistratorPreStore1NotEnoughGas.json                 Fail
- createNameRegistratorendowmentTooHigh.json                      Fail
```
OK: 0/43 Fail: 37/43 Skip: 6/43
## stCallDelegateCodesCallCodeHomestead
```diff
- callcallcallcode_001.json                                       Fail
- callcallcallcode_001_OOGE.json                                  Fail
- callcallcallcode_001_OOGMAfter.json                             Fail
- callcallcallcode_001_OOGMBefore.json                            Fail
- callcallcallcode_001_SuicideEnd.json                            Fail
- callcallcallcode_001_SuicideMiddle.json                         Fail
  callcallcallcode_ABCB_RECURSIVE.json                            Skip
- callcallcode_01.json                                            Fail
- callcallcode_01_OOGE.json                                       Fail
- callcallcode_01_SuicideEnd.json                                 Fail
- callcallcodecall_010.json                                       Fail
- callcallcodecall_010_OOGE.json                                  Fail
- callcallcodecall_010_OOGMAfter.json                             Fail
- callcallcodecall_010_OOGMBefore.json                            Fail
- callcallcodecall_010_SuicideEnd.json                            Fail
- callcallcodecall_010_SuicideMiddle.json                         Fail
  callcallcodecall_ABCB_RECURSIVE.json                            Skip
- callcallcodecallcode_011.json                                   Fail
- callcallcodecallcode_011_OOGE.json                              Fail
- callcallcodecallcode_011_OOGMAfter.json                         Fail
- callcallcodecallcode_011_OOGMBefore.json                        Fail
- callcallcodecallcode_011_SuicideEnd.json                        Fail
- callcallcodecallcode_011_SuicideMiddle.json                     Fail
  callcallcodecallcode_ABCB_RECURSIVE.json                        Skip
- callcodecall_10.json                                            Fail
- callcodecall_10_OOGE.json                                       Fail
- callcodecall_10_SuicideEnd.json                                 Fail
- callcodecallcall_100.json                                       Fail
- callcodecallcall_100_OOGE.json                                  Fail
- callcodecallcall_100_OOGMAfter.json                             Fail
- callcodecallcall_100_OOGMBefore.json                            Fail
- callcodecallcall_100_SuicideEnd.json                            Fail
- callcodecallcall_100_SuicideMiddle.json                         Fail
  callcodecallcall_ABCB_RECURSIVE.json                            Skip
- callcodecallcallcode_101.json                                   Fail
- callcodecallcallcode_101_OOGE.json                              Fail
- callcodecallcallcode_101_OOGMAfter.json                         Fail
- callcodecallcallcode_101_OOGMBefore.json                        Fail
- callcodecallcallcode_101_SuicideEnd.json                        Fail
- callcodecallcallcode_101_SuicideMiddle.json                     Fail
  callcodecallcallcode_ABCB_RECURSIVE.json                        Skip
- callcodecallcode_11.json                                        Fail
- callcodecallcode_11_OOGE.json                                   Fail
- callcodecallcode_11_SuicideEnd.json                             Fail
- callcodecallcodecall_110.json                                   Fail
- callcodecallcodecall_110_OOGE.json                              Fail
- callcodecallcodecall_110_OOGMAfter.json                         Fail
- callcodecallcodecall_110_OOGMBefore.json                        Fail
- callcodecallcodecall_110_SuicideEnd.json                        Fail
- callcodecallcodecall_110_SuicideMiddle.json                     Fail
  callcodecallcodecall_ABCB_RECURSIVE.json                        Skip
- callcodecallcodecallcode_111.json                               Fail
- callcodecallcodecallcode_111_OOGE.json                          Fail
- callcodecallcodecallcode_111_OOGMAfter.json                     Fail
- callcodecallcodecallcode_111_OOGMBefore.json                    Fail
- callcodecallcodecallcode_111_SuicideEnd.json                    Fail
- callcodecallcodecallcode_111_SuicideMiddle.json                 Fail
  callcodecallcodecallcode_ABCB_RECURSIVE.json                    Skip
```
OK: 0/58 Fail: 51/58 Skip: 7/58
## stCallDelegateCodesHomestead
```diff
- callcallcallcode_001.json                                       Fail
- callcallcallcode_001_OOGE.json                                  Fail
- callcallcallcode_001_OOGMAfter.json                             Fail
- callcallcallcode_001_OOGMBefore.json                            Fail
- callcallcallcode_001_SuicideEnd.json                            Fail
- callcallcallcode_001_SuicideMiddle.json                         Fail
  callcallcallcode_ABCB_RECURSIVE.json                            Skip
- callcallcode_01.json                                            Fail
- callcallcode_01_OOGE.json                                       Fail
- callcallcode_01_SuicideEnd.json                                 Fail
- callcallcodecall_010.json                                       Fail
- callcallcodecall_010_OOGE.json                                  Fail
- callcallcodecall_010_OOGMAfter.json                             Fail
- callcallcodecall_010_OOGMBefore.json                            Fail
- callcallcodecall_010_SuicideEnd.json                            Fail
- callcallcodecall_010_SuicideMiddle.json                         Fail
  callcallcodecall_ABCB_RECURSIVE.json                            Skip
- callcallcodecallcode_011.json                                   Fail
- callcallcodecallcode_011_OOGE.json                              Fail
- callcallcodecallcode_011_OOGMAfter.json                         Fail
- callcallcodecallcode_011_OOGMBefore.json                        Fail
- callcallcodecallcode_011_SuicideEnd.json                        Fail
- callcallcodecallcode_011_SuicideMiddle.json                     Fail
  callcallcodecallcode_ABCB_RECURSIVE.json                        Skip
- callcodecall_10.json                                            Fail
- callcodecall_10_OOGE.json                                       Fail
- callcodecall_10_SuicideEnd.json                                 Fail
- callcodecallcall_100.json                                       Fail
- callcodecallcall_100_OOGE.json                                  Fail
- callcodecallcall_100_OOGMAfter.json                             Fail
- callcodecallcall_100_OOGMBefore.json                            Fail
- callcodecallcall_100_SuicideEnd.json                            Fail
- callcodecallcall_100_SuicideMiddle.json                         Fail
  callcodecallcall_ABCB_RECURSIVE.json                            Skip
- callcodecallcallcode_101.json                                   Fail
- callcodecallcallcode_101_OOGE.json                              Fail
- callcodecallcallcode_101_OOGMAfter.json                         Fail
- callcodecallcallcode_101_OOGMBefore.json                        Fail
- callcodecallcallcode_101_SuicideEnd.json                        Fail
- callcodecallcallcode_101_SuicideMiddle.json                     Fail
  callcodecallcallcode_ABCB_RECURSIVE.json                        Skip
- callcodecallcode_11.json                                        Fail
- callcodecallcode_11_OOGE.json                                   Fail
- callcodecallcode_11_SuicideEnd.json                             Fail
- callcodecallcodecall_110.json                                   Fail
- callcodecallcodecall_110_OOGE.json                              Fail
- callcodecallcodecall_110_OOGMAfter.json                         Fail
- callcodecallcodecall_110_OOGMBefore.json                        Fail
- callcodecallcodecall_110_SuicideEnd.json                        Fail
- callcodecallcodecall_110_SuicideMiddle.json                     Fail
  callcodecallcodecall_ABCB_RECURSIVE.json                        Skip
- callcodecallcodecallcode_111.json                               Fail
- callcodecallcodecallcode_111_OOGE.json                          Fail
- callcodecallcodecallcode_111_OOGMAfter.json                     Fail
- callcodecallcodecallcode_111_OOGMBefore.json                    Fail
- callcodecallcodecallcode_111_SuicideEnd.json                    Fail
- callcodecallcodecallcode_111_SuicideMiddle.json                 Fail
  callcodecallcodecallcode_ABCB_RECURSIVE.json                    Skip
```
OK: 0/58 Fail: 51/58 Skip: 7/58
## stChainId
```diff
- chainId.json                                                    Fail
- chainIdGasCost.json                                             Fail
```
OK: 0/2 Fail: 2/2 Skip: 0/2
## stCodeCopyTest
```diff
- ExtCodeCopyTargetRangeLongerThanCodeTests.json                  Fail
- ExtCodeCopyTests.json                                           Fail
- ExtCodeCopyTestsParis.json                                      Fail
```
OK: 0/3 Fail: 3/3 Skip: 0/3
## stCodeSizeLimit
```diff
- codesizeInit.json                                               Fail
- codesizeOOGInvalidSize.json                                     Fail
- codesizeValid.json                                              Fail
- create2CodeSizeLimit.json                                       Fail
- createCodeSizeLimit.json                                        Fail
```
OK: 0/5 Fail: 5/5 Skip: 0/5
## stCreate2
```diff
- CREATE2_Bounds.json                                             Fail
- CREATE2_Bounds2.json                                            Fail
- CREATE2_Bounds3.json                                            Fail
- CREATE2_ContractSuicideDuringInit_ThenStoreThenReturn.json      Fail
- CREATE2_FirstByte_loop.json                                     Fail
- CREATE2_HighNonce.json                                          Fail
- CREATE2_HighNonceDelegatecall.json                              Fail
- CREATE2_HighNonceMinus1.json                                    Fail
- CREATE2_Suicide.json                                            Fail
- Create2OOGFromCallRefunds.json                                  Fail
- Create2OOGafterInitCode.json                                    Fail
- Create2OOGafterInitCodeReturndata.json                          Fail
- Create2OOGafterInitCodeReturndata2.json                         Fail
- Create2OOGafterInitCodeReturndata3.json                         Fail
- Create2OOGafterInitCodeReturndataSize.json                      Fail
- Create2OOGafterInitCodeRevert.json                              Fail
- Create2OOGafterInitCodeRevert2.json                             Fail
- Create2OnDepth1023.json                                         Fail
- Create2OnDepth1024.json                                         Fail
  Create2Recursive.json                                           Skip
- CreateMessageReverted.json                                      Fail
- CreateMessageRevertedOOGInInit.json                             Fail
- CreateMessageRevertedOOGInInit2.json                            Fail
- RevertDepthCreate2OOG.json                                      Fail
- RevertDepthCreate2OOGBerlin.json                                Fail
- RevertDepthCreateAddressCollision.json                          Fail
- RevertDepthCreateAddressCollisionBerlin.json                    Fail
- RevertInCreateInInitCreate2.json                                Fail
- RevertInCreateInInitCreate2Paris.json                           Fail
- RevertOpcodeCreate.json                                         Fail
- RevertOpcodeInCreateReturnsCreate2.json                         Fail
- call_outsize_then_create2_successful_then_returndatasize.json   Fail
- call_then_create2_successful_then_returndatasize.json           Fail
- create2InitCodes.json                                           Fail
- create2SmartInitCode.json                                       Fail
- create2callPrecompiles.json                                     Fail
- create2checkFieldsInInitcode.json                               Fail
- create2collisionBalance.json                                    Fail
- create2collisionCode.json                                       Fail
- create2collisionCode2.json                                      Fail
- create2collisionNonce.json                                      Fail
- create2collisionSelfdestructed.json                             Fail
- create2collisionSelfdestructed2.json                            Fail
- create2collisionSelfdestructedOOG.json                          Fail
- create2collisionSelfdestructedRevert.json                       Fail
- create2collisionStorage.json                                    Fail
- create2collisionStorageParis.json                               Fail
- create2noCash.json                                              Fail
- returndatacopy_0_0_following_successful_create.json             Fail
- returndatacopy_afterFailing_create.json                         Fail
- returndatacopy_following_create.json                            Fail
- returndatacopy_following_revert_in_create.json                  Fail
- returndatacopy_following_successful_create.json                 Fail
- returndatasize_following_successful_create.json                 Fail
```
OK: 0/54 Fail: 53/54 Skip: 1/54
## stCreateTest
```diff
- CREATE2_CallData.json                                           Fail
- CREATE2_RefundEF.json                                           Fail
- CREATE_AcreateB_BSuicide_BStore.json                            Fail
- CREATE_ContractRETURNBigOffset.json                             Fail
- CREATE_ContractSSTOREDuringInit.json                            Fail
- CREATE_ContractSuicideDuringInit.json                           Fail
- CREATE_ContractSuicideDuringInit_ThenStoreThenReturn.json       Fail
- CREATE_ContractSuicideDuringInit_WithValue.json                 Fail
- CREATE_ContractSuicideDuringInit_WithValueToItself.json         Fail
- CREATE_EContractCreateEContractInInit_Tr.json                   Fail
- CREATE_EContractCreateNEContractInInitOOG_Tr.json               Fail
- CREATE_EContractCreateNEContractInInit_Tr.json                  Fail
- CREATE_EContract_ThenCALLToNonExistentAcc.json                  Fail
- CREATE_EmptyContract.json                                       Fail
- CREATE_EmptyContractAndCallIt_0wei.json                         Fail
- CREATE_EmptyContractAndCallIt_1wei.json                         Fail
- CREATE_EmptyContractWithBalance.json                            Fail
- CREATE_EmptyContractWithStorage.json                            Fail
- CREATE_EmptyContractWithStorageAndCallIt_0wei.json              Fail
- CREATE_EmptyContractWithStorageAndCallIt_1wei.json              Fail
- CREATE_FirstByte_loop.json                                      Fail
- CREATE_HighNonce.json                                           Fail
- CREATE_HighNonceMinus1.json                                     Fail
- CREATE_empty000CreateinInitCode_Transaction.json                Fail
- CodeInConstructor.json                                          Fail
- CreateAddressWarmAfterFail.json                                 Fail
- CreateCollisionResults.json                                     Fail
- CreateCollisionToEmpty.json                                     Fail
- CreateCollisionToEmpty2.json                                    Fail
- CreateOOGFromCallRefunds.json                                   Fail
- CreateOOGFromEOARefunds.json                                    Fail
- CreateOOGafterInitCode.json                                     Fail
- CreateOOGafterInitCodeReturndata.json                           Fail
- CreateOOGafterInitCodeReturndata2.json                          Fail
- CreateOOGafterInitCodeReturndata3.json                          Fail
- CreateOOGafterInitCodeReturndataSize.json                       Fail
- CreateOOGafterInitCodeRevert.json                               Fail
- CreateOOGafterInitCodeRevert2.json                              Fail
- CreateOOGafterMaxCodesize.json                                  Fail
- CreateResults.json                                              Fail
- CreateTransactionCallData.json                                  Fail
+ CreateTransactionHighNonce.json                                 OK
- CreateTransactionRefundEF.json                                  Fail
- TransactionCollisionToEmpty.json                                Fail
- TransactionCollisionToEmpty2.json                               Fail
- TransactionCollisionToEmptyButCode.json                         Fail
- TransactionCollisionToEmptyButNonce.json                        Fail
- createFailResult.json                                           Fail
- createLargeResult.json                                          Fail
```
OK: 1/49 Fail: 48/49 Skip: 0/49
## stDelegatecallTestHomestead
```diff
  Call1024BalanceTooLow.json                                      Skip
  Call1024OOG.json                                                Skip
  Call1024PreCalls.json                                           Skip
- CallLoseGasOOG.json                                             Fail
  CallRecursiveBombPreCall.json                                   Skip
- CallcodeLoseGasOOG.json                                         Fail
  Delegatecall1024.json                                           Skip
  Delegatecall1024OOG.json                                        Skip
- callOutput1.json                                                Fail
- callOutput2.json                                                Fail
- callOutput3.json                                                Fail
- callOutput3partial.json                                         Fail
- callOutput3partialFail.json                                     Fail
- callWithHighValueAndGasOOG.json                                 Fail
- callcodeOutput3.json                                            Fail
- callcodeWithHighValueAndGasOOG.json                             Fail
- deleagateCallAfterValueTransfer.json                            Fail
- delegatecallAndOOGatTxLevel.json                                Fail
- delegatecallBasic.json                                          Fail
- delegatecallEmptycontract.json                                  Fail
- delegatecallInInitcodeToEmptyContract.json                      Fail
- delegatecallInInitcodeToExistingContract.json                   Fail
- delegatecallInInitcodeToExistingContractOOG.json                Fail
- delegatecallOOGinCall.json                                      Fail
- delegatecallSenderCheck.json                                    Fail
- delegatecallValueCheck.json                                     Fail
- delegatecodeDynamicCode.json                                    Fail
- delegatecodeDynamicCode2SelfCall.json                           Fail
```
OK: 0/28 Fail: 22/28 Skip: 6/28
## stEIP1153-transientStorage
```diff
+ 01_tloadBeginningTxn.json                                       OK
+ 02_tloadAfterTstore.json                                        OK
+ 03_tloadAfterStoreIs0.json                                      OK
+ 04_tloadAfterCall.json                                          OK
+ 05_tloadReentrancy.json                                         OK
+ 06_tstoreInReentrancyCall.json                                  OK
+ 07_tloadAfterReentrancyStore.json                               OK
+ 08_revertUndoesTransientStore.json                              OK
+ 09_revertUndoesAll.json                                         OK
+ 10_revertUndoesStoreAfterReturn.json                            OK
+ 11_tstoreDelegateCall.json                                      OK
+ 12_tloadDelegateCall.json                                       OK
+ 13_tloadStaticCall.json                                         OK
+ 14_revertAfterNestedStaticcall.json                             OK
+ 15_tstoreCannotBeDosd.json                                      OK
+ 16_tloadGas.json                                                OK
+ 17_tstoreGas.json                                               OK
+ 18_tloadAfterStore.json                                         OK
+ 19_oogUndoesTransientStore.json                                 OK
+ 20_oogUndoesTransientStoreInCall.json                           OK
+ 21_tstoreCannotBeDosdOOO.json                                   OK
+ transStorageOK.json                                             OK
+ transStorageReset.json                                          OK
```
OK: 23/23 Fail: 0/23 Skip: 0/23
## stEIP150Specific
```diff
- CallAndCallcodeConsumeMoreGasThenTransactionHas.json            Fail
- CallAskMoreGasOnDepth2ThenTransactionHas.json                   Fail
- CallGoesOOGOnSecondLevel.json                                   Fail
- CallGoesOOGOnSecondLevel2.json                                  Fail
- CreateAndGasInsideCreate.json                                   Fail
- DelegateCallOnEIP.json                                          Fail
- ExecuteCallThatAskForeGasThenTrabsactionHas.json                Fail
- NewGasPriceForCodes.json                                        Fail
- SuicideToExistingContract.json                                  Fail
- SuicideToNotExistingContract.json                               Fail
- Transaction64Rule_d64e0.json                                    Fail
- Transaction64Rule_d64m1.json                                    Fail
- Transaction64Rule_d64p1.json                                    Fail
- Transaction64Rule_integerBoundaries.json                        Fail
```
OK: 0/14 Fail: 14/14 Skip: 0/14
## stEIP150singleCodeGasPrices
```diff
- RawBalanceGas.json                                              Fail
- RawCallCodeGas.json                                             Fail
- RawCallCodeGasAsk.json                                          Fail
- RawCallCodeGasMemory.json                                       Fail
- RawCallCodeGasMemoryAsk.json                                    Fail
- RawCallCodeGasValueTransfer.json                                Fail
- RawCallCodeGasValueTransferAsk.json                             Fail
- RawCallCodeGasValueTransferMemory.json                          Fail
- RawCallCodeGasValueTransferMemoryAsk.json                       Fail
- RawCallGas.json                                                 Fail
- RawCallGasAsk.json                                              Fail
- RawCallGasValueTransfer.json                                    Fail
- RawCallGasValueTransferAsk.json                                 Fail
- RawCallGasValueTransferMemory.json                              Fail
- RawCallGasValueTransferMemoryAsk.json                           Fail
- RawCallMemoryGas.json                                           Fail
- RawCallMemoryGasAsk.json                                        Fail
- RawCreateFailGasValueTransfer.json                              Fail
- RawCreateFailGasValueTransfer2.json                             Fail
- RawCreateGas.json                                               Fail
- RawCreateGasMemory.json                                         Fail
- RawCreateGasValueTransfer.json                                  Fail
- RawCreateGasValueTransferMemory.json                            Fail
- RawDelegateCallGas.json                                         Fail
- RawDelegateCallGasAsk.json                                      Fail
- RawDelegateCallGasMemory.json                                   Fail
- RawDelegateCallGasMemoryAsk.json                                Fail
- RawExtCodeCopyGas.json                                          Fail
- RawExtCodeCopyMemoryGas.json                                    Fail
- RawExtCodeSizeGas.json                                          Fail
- eip2929-ff.json                                                 Fail
- eip2929.json                                                    Fail
- eip2929OOG.json                                                 Fail
- gasCost.json                                                    Fail
- gasCostBerlin.json                                              Fail
- gasCostExp.json                                                 Fail
- gasCostJump.json                                                Fail
- gasCostMemSeg.json                                              Fail
- gasCostMemory.json                                              Fail
- gasCostReturn.json                                              Fail
```
OK: 0/40 Fail: 40/40 Skip: 0/40
## stEIP1559
```diff
- baseFeeDiffPlaces.json                                          Fail
- gasPriceDiffPlaces.json                                         Fail
- intrinsic.json                                                  Fail
+ lowFeeCap.json                                                  OK
- lowGasLimit.json                                                Fail
+ lowGasPriceOldTypes.json                                        OK
- outOfFunds.json                                                 Fail
- outOfFundsOldTypes.json                                         Fail
- senderBalance.json                                              Fail
+ tipTooHigh.json                                                 OK
+ transactionIntinsicBug.json                                     OK
+ transactionIntinsicBug_Paris.json                               OK
- typeTwoBerlin.json                                              Fail
- valCausesOOF.json                                               Fail
```
OK: 5/14 Fail: 9/14 Skip: 0/14
## stEIP158Specific
```diff
- CALL_OneVCallSuicide.json                                       Fail
- CALL_OneVCallSuicide2.json                                      Fail
- CALL_ZeroVCallSuicide.json                                      Fail
- EXP_Empty.json                                                  Fail
- EXTCODESIZE_toEpmty.json                                        Fail
- EXTCODESIZE_toEpmtyParis.json                                   Fail
- EXTCODESIZE_toNonExistent.json                                  Fail
- callToEmptyThenCallError.json                                   Fail
- callToEmptyThenCallErrorParis.json                              Fail
- vitalikTransactionTest.json                                     Fail
- vitalikTransactionTestParis.json                                Fail
```
OK: 0/11 Fail: 11/11 Skip: 0/11
## stEIP2930
```diff
- addressOpcodes.json                                             Fail
- coinbaseT01.json                                                Fail
- coinbaseT2.json                                                 Fail
- manualCreate.json                                               Fail
- storageCosts.json                                               Fail
- transactionCosts.json                                           Fail
- variedContext.json                                              Fail
```
OK: 0/7 Fail: 7/7 Skip: 0/7
## stEIP3607
```diff
- initCollidingWithNonEmptyAccount.json                           Fail
+ transactionCollidingWithNonEmptyAccount_calls.json              OK
+ transactionCollidingWithNonEmptyAccount_callsItself.json        OK
+ transactionCollidingWithNonEmptyAccount_init.json               OK
+ transactionCollidingWithNonEmptyAccount_init_Paris.json         OK
+ transactionCollidingWithNonEmptyAccount_send.json               OK
+ transactionCollidingWithNonEmptyAccount_send_Paris.json         OK
```
OK: 6/7 Fail: 1/7 Skip: 0/7
## stEIP3651-warmcoinbase
```diff
- coinbaseWarmAccountCallGas.json                                 Fail
- coinbaseWarmAccountCallGasFail.json                             Fail
```
OK: 0/2 Fail: 2/2 Skip: 0/2
## stEIP3855-push0
```diff
- push0.json                                                      Fail
- push0Gas.json                                                   Fail
- push0Gas2.json                                                  Fail
```
OK: 0/3 Fail: 3/3 Skip: 0/3
## stEIP3860-limitmeterinitcode
```diff
- create2InitCodeSizeLimit.json                                   Fail
- createInitCodeSizeLimit.json                                    Fail
- creationTxInitCodeSizeLimit.json                                Fail
```
OK: 0/3 Fail: 3/3 Skip: 0/3
## stEIP4844-blobtransactions
```diff
+ blobhashListBounds3.json                                        OK
+ blobhashListBounds4.json                                        OK
+ blobhashListBounds5.json                                        OK
+ blobhashListBounds6.json                                        OK
+ blobhashListBounds7.json                                        OK
+ createBlobhashTx.json                                           OK
+ emptyBlobhashList.json                                          OK
+ opcodeBlobhBounds.json                                          OK
+ opcodeBlobhashOutOfRange.json                                   OK
+ wrongBlobhashVersion.json                                       OK
```
OK: 10/10 Fail: 0/10 Skip: 0/10
## stEIP5656-MCOPY
```diff
+ MCOPY.json                                                      OK
+ MCOPY_copy_cost.json                                            OK
+ MCOPY_memory_expansion_cost.json                                OK
+ MCOPY_memory_hash.json                                          OK
```
OK: 4/4 Fail: 0/4 Skip: 0/4
## stExample
```diff
- accessListExample.json                                          Fail
- add11.json                                                      Fail
- add11_yml.json                                                  Fail
- basefeeExample.json                                             Fail
- eip1559.json                                                    Fail
- indexesOmitExample.json                                         Fail
+ invalidTr.json                                                  OK
- labelsExample.json                                              Fail
- mergeTest.json                                                  Fail
- rangesExample.json                                              Fail
- solidityExample.json                                            Fail
- yulExample.json                                                 Fail
```
OK: 1/12 Fail: 11/12 Skip: 0/12
## stExtCodeHash
```diff
- callToNonExistent.json                                          Fail
- callToSuicideThenExtcodehash.json                               Fail
- codeCopyZero.json                                               Fail
- codeCopyZero_Paris.json                                         Fail
- createEmptyThenExtcodehash.json                                 Fail
- dynamicAccountOverwriteEmpty.json                               Fail
- dynamicAccountOverwriteEmpty_Paris.json                         Fail
- extCodeCopyBounds.json                                          Fail
- extCodeHashAccountWithoutCode.json                              Fail
- extCodeHashCALL.json                                            Fail
- extCodeHashCALLCODE.json                                        Fail
- extCodeHashChangedAccount.json                                  Fail
- extCodeHashCreatedAndDeletedAccount.json                        Fail
- extCodeHashCreatedAndDeletedAccountCall.json                    Fail
- extCodeHashCreatedAndDeletedAccountRecheckInOuterCall.json      Fail
- extCodeHashCreatedAndDeletedAccountStaticCall.json              Fail
- extCodeHashDELEGATECALL.json                                    Fail
- extCodeHashDeletedAccount.json                                  Fail
- extCodeHashDeletedAccount1.json                                 Fail
- extCodeHashDeletedAccount1Cancun.json                           Fail
- extCodeHashDeletedAccount2.json                                 Fail
- extCodeHashDeletedAccount2Cancun.json                           Fail
- extCodeHashDeletedAccount3.json                                 Fail
- extCodeHashDeletedAccount4.json                                 Fail
- extCodeHashDeletedAccountCancun.json                            Fail
- extCodeHashDynamicArgument.json                                 Fail
- extCodeHashInInitCode.json                                      Fail
- extCodeHashMaxCodeSize.json                                     Fail
- extCodeHashNewAccount.json                                      Fail
- extCodeHashNonExistingAccount.json                              Fail
- extCodeHashPrecompiles.json                                     Fail
- extCodeHashSTATICCALL.json                                      Fail
- extCodeHashSelf.json                                            Fail
- extCodeHashSelfInInit.json                                      Fail
- extCodeHashSubcallOOG.json                                      Fail
- extCodeHashSubcallSuicide.json                                  Fail
- extCodeHashSubcallSuicideCancun.json                            Fail
- extcodehashEmpty.json                                           Fail
- extcodehashEmpty_Paris.json                                     Fail
```
OK: 0/39 Fail: 39/39 Skip: 0/39
## stHomesteadSpecific
```diff
- contractCreationOOGdontLeaveEmptyContract.json                  Fail
- contractCreationOOGdontLeaveEmptyContractViaTransaction.json    Fail
- createContractViaContract.json                                  Fail
- createContractViaContractOOGInitCode.json                       Fail
- createContractViaTransactionCost53000.json                      Fail
```
OK: 0/5 Fail: 5/5 Skip: 0/5
## stInitCodeTest
```diff
- CallContractToCreateContractAndCallItOOG.json                   Fail
- CallContractToCreateContractNoCash.json                         Fail
- CallContractToCreateContractOOG.json                            Fail
- CallContractToCreateContractOOGBonusGas.json                    Fail
- CallContractToCreateContractWhichWouldCreateContractIfCalled.js Fail
- CallContractToCreateContractWhichWouldCreateContractInInitCode. Fail
- CallRecursiveContract.json                                      Fail
- CallTheContractToCreateEmptyContract.json                       Fail
- OutOfGasContractCreation.json                                   Fail
- OutOfGasPrefundedContractCreation.json                          Fail
- ReturnTest.json                                                 Fail
- ReturnTest2.json                                                Fail
- StackUnderFlowContractCreation.json                             Fail
- TransactionCreateAutoSuicideContract.json                       Fail
- TransactionCreateRandomInitCode.json                            Fail
- TransactionCreateStopInInitcode.json                            Fail
- TransactionCreateSuicideInInitcode.json                         Fail
```
OK: 0/17 Fail: 17/17 Skip: 0/17
## stLogTests
```diff
- log0_emptyMem.json                                              Fail
- log0_logMemStartTooHigh.json                                    Fail
- log0_logMemsizeTooHigh.json                                     Fail
- log0_logMemsizeZero.json                                        Fail
- log0_nonEmptyMem.json                                           Fail
- log0_nonEmptyMem_logMemSize1.json                               Fail
- log0_nonEmptyMem_logMemSize1_logMemStart31.json                 Fail
- log1_Caller.json                                                Fail
- log1_MaxTopic.json                                              Fail
- log1_emptyMem.json                                              Fail
- log1_logMemStartTooHigh.json                                    Fail
- log1_logMemsizeTooHigh.json                                     Fail
- log1_logMemsizeZero.json                                        Fail
- log1_nonEmptyMem.json                                           Fail
- log1_nonEmptyMem_logMemSize1.json                               Fail
- log1_nonEmptyMem_logMemSize1_logMemStart31.json                 Fail
- log2_Caller.json                                                Fail
- log2_MaxTopic.json                                              Fail
- log2_emptyMem.json                                              Fail
- log2_logMemStartTooHigh.json                                    Fail
- log2_logMemsizeTooHigh.json                                     Fail
- log2_logMemsizeZero.json                                        Fail
- log2_nonEmptyMem.json                                           Fail
- log2_nonEmptyMem_logMemSize1.json                               Fail
- log2_nonEmptyMem_logMemSize1_logMemStart31.json                 Fail
- log3_Caller.json                                                Fail
- log3_MaxTopic.json                                              Fail
- log3_PC.json                                                    Fail
- log3_emptyMem.json                                              Fail
- log3_logMemStartTooHigh.json                                    Fail
- log3_logMemsizeTooHigh.json                                     Fail
- log3_logMemsizeZero.json                                        Fail
- log3_nonEmptyMem.json                                           Fail
- log3_nonEmptyMem_logMemSize1.json                               Fail
- log3_nonEmptyMem_logMemSize1_logMemStart31.json                 Fail
- log4_Caller.json                                                Fail
- log4_MaxTopic.json                                              Fail
- log4_PC.json                                                    Fail
- log4_emptyMem.json                                              Fail
- log4_logMemStartTooHigh.json                                    Fail
- log4_logMemsizeTooHigh.json                                     Fail
- log4_logMemsizeZero.json                                        Fail
- log4_nonEmptyMem.json                                           Fail
- log4_nonEmptyMem_logMemSize1.json                               Fail
- log4_nonEmptyMem_logMemSize1_logMemStart31.json                 Fail
- logInOOG_Call.json                                              Fail
```
OK: 0/46 Fail: 46/46 Skip: 0/46
## stMemExpandingEIP150Calls
```diff
- CallAndCallcodeConsumeMoreGasThenTransactionHasWithMemExpanding Fail
- CallAskMoreGasOnDepth2ThenTransactionHasWithMemExpandingCalls.j Fail
- CallGoesOOGOnSecondLevel2WithMemExpandingCalls.json             Fail
- CallGoesOOGOnSecondLevelWithMemExpandingCalls.json              Fail
- CreateAndGasInsideCreateWithMemExpandingCalls.json              Fail
- DelegateCallOnEIPWithMemExpandingCalls.json                     Fail
- ExecuteCallThatAskMoreGasThenTransactionHasWithMemExpandingCall Fail
- NewGasPriceForCodesWithMemExpandingCalls.json                   Fail
- OOGinReturn.json                                                Fail
```
OK: 0/9 Fail: 9/9 Skip: 0/9
## stMemoryStressTest
```diff
  CALLCODE_Bounds.json                                            Skip
  CALLCODE_Bounds2.json                                           Skip
  CALLCODE_Bounds3.json                                           Skip
  CALLCODE_Bounds4.json                                           Skip
  CALL_Bounds.json                                                Skip
  CALL_Bounds2.json                                               Skip
  CALL_Bounds2a.json                                              Skip
  CALL_Bounds3.json                                               Skip
- CREATE_Bounds.json                                              Fail
- CREATE_Bounds2.json                                             Fail
- CREATE_Bounds3.json                                             Fail
  DELEGATECALL_Bounds.json                                        Skip
  DELEGATECALL_Bounds2.json                                       Skip
  DELEGATECALL_Bounds3.json                                       Skip
- DUP_Bounds.json                                                 Fail
- FillStack.json                                                  Fail
- JUMPI_Bounds.json                                               Fail
- JUMP_Bounds.json                                                Fail
- JUMP_Bounds2.json                                               Fail
- MLOAD_Bounds.json                                               Fail
- MLOAD_Bounds2.json                                              Fail
- MLOAD_Bounds3.json                                              Fail
- MSTORE_Bounds.json                                              Fail
- MSTORE_Bounds2.json                                             Fail
- MSTORE_Bounds2a.json                                            Fail
- POP_Bounds.json                                                 Fail
- RETURN_Bounds.json                                              Fail
- SLOAD_Bounds.json                                               Fail
- SSTORE_Bounds.json                                              Fail
- mload32bitBound.json                                            Fail
- mload32bitBound2.json                                           Fail
- mload32bitBound_Msize.json                                      Fail
- mload32bitBound_return.json                                     Fail
- mload32bitBound_return2.json                                    Fail
- static_CALL_Bounds.json                                         Fail
- static_CALL_Bounds2.json                                        Fail
- static_CALL_Bounds2a.json                                       Fail
- static_CALL_Bounds3.json                                        Fail
```
OK: 0/38 Fail: 27/38 Skip: 11/38
## stMemoryTest
```diff
- buffer.json                                                     Fail
- bufferSrcOffset.json                                            Fail
- callDataCopyOffset.json                                         Fail
- calldatacopy_dejavu.json                                        Fail
- calldatacopy_dejavu2.json                                       Fail
- codeCopyOffset.json                                             Fail
- codecopy_dejavu.json                                            Fail
- codecopy_dejavu2.json                                           Fail
- extcodecopy_dejavu.json                                         Fail
- log1_dejavu.json                                                Fail
- log2_dejavu.json                                                Fail
- log3_dejavu.json                                                Fail
- log4_dejavu.json                                                Fail
- mem0b_singleByte.json                                           Fail
- mem31b_singleByte.json                                          Fail
- mem32b_singleByte.json                                          Fail
- mem32kb+1.json                                                  Fail
- mem32kb+31.json                                                 Fail
- mem32kb+32.json                                                 Fail
- mem32kb+33.json                                                 Fail
- mem32kb-1.json                                                  Fail
- mem32kb-31.json                                                 Fail
- mem32kb-32.json                                                 Fail
- mem32kb-33.json                                                 Fail
- mem32kb.json                                                    Fail
- mem32kb_singleByte+1.json                                       Fail
- mem32kb_singleByte+31.json                                      Fail
- mem32kb_singleByte+32.json                                      Fail
- mem32kb_singleByte+33.json                                      Fail
- mem32kb_singleByte-1.json                                       Fail
- mem32kb_singleByte-31.json                                      Fail
- mem32kb_singleByte-32.json                                      Fail
- mem32kb_singleByte-33.json                                      Fail
- mem32kb_singleByte.json                                         Fail
- mem33b_singleByte.json                                          Fail
- mem64kb+1.json                                                  Fail
- mem64kb+31.json                                                 Fail
- mem64kb+32.json                                                 Fail
- mem64kb+33.json                                                 Fail
- mem64kb-1.json                                                  Fail
- mem64kb-31.json                                                 Fail
- mem64kb-32.json                                                 Fail
- mem64kb-33.json                                                 Fail
- mem64kb.json                                                    Fail
- mem64kb_singleByte+1.json                                       Fail
- mem64kb_singleByte+31.json                                      Fail
- mem64kb_singleByte+32.json                                      Fail
- mem64kb_singleByte+33.json                                      Fail
- mem64kb_singleByte-1.json                                       Fail
- mem64kb_singleByte-31.json                                      Fail
- mem64kb_singleByte-32.json                                      Fail
- mem64kb_singleByte-33.json                                      Fail
- mem64kb_singleByte.json                                         Fail
- memCopySelf.json                                                Fail
- memReturn.json                                                  Fail
- mload16bitBound.json                                            Fail
- mload8bitBound.json                                             Fail
- mload_dejavu.json                                               Fail
- mstore_dejavu.json                                              Fail
- mstroe8_dejavu.json                                             Fail
- oog.json                                                        Fail
- sha3_dejavu.json                                                Fail
- stackLimitGas_1023.json                                         Fail
- stackLimitGas_1024.json                                         Fail
- stackLimitGas_1025.json                                         Fail
- stackLimitPush31_1023.json                                      Fail
- stackLimitPush31_1024.json                                      Fail
- stackLimitPush31_1025.json                                      Fail
- stackLimitPush32_1023.json                                      Fail
- stackLimitPush32_1024.json                                      Fail
- stackLimitPush32_1025.json                                      Fail
```
OK: 0/71 Fail: 71/71 Skip: 0/71
## stNonZeroCallsTest
```diff
- NonZeroValue_CALL.json                                          Fail
- NonZeroValue_CALLCODE.json                                      Fail
- NonZeroValue_CALLCODE_ToEmpty.json                              Fail
- NonZeroValue_CALLCODE_ToEmpty_Paris.json                        Fail
- NonZeroValue_CALLCODE_ToNonNonZeroBalance.json                  Fail
- NonZeroValue_CALLCODE_ToOneStorageKey.json                      Fail
- NonZeroValue_CALLCODE_ToOneStorageKey_Paris.json                Fail
- NonZeroValue_CALL_ToEmpty.json                                  Fail
- NonZeroValue_CALL_ToEmpty_Paris.json                            Fail
- NonZeroValue_CALL_ToNonNonZeroBalance.json                      Fail
- NonZeroValue_CALL_ToOneStorageKey.json                          Fail
- NonZeroValue_CALL_ToOneStorageKey_Paris.json                    Fail
- NonZeroValue_DELEGATECALL.json                                  Fail
- NonZeroValue_DELEGATECALL_ToEmpty.json                          Fail
- NonZeroValue_DELEGATECALL_ToEmpty_Paris.json                    Fail
- NonZeroValue_DELEGATECALL_ToNonNonZeroBalance.json              Fail
- NonZeroValue_DELEGATECALL_ToOneStorageKey.json                  Fail
- NonZeroValue_DELEGATECALL_ToOneStorageKey_Paris.json            Fail
- NonZeroValue_SUICIDE.json                                       Fail
- NonZeroValue_SUICIDE_ToEmpty.json                               Fail
- NonZeroValue_SUICIDE_ToEmpty_Paris.json                         Fail
- NonZeroValue_SUICIDE_ToNonNonZeroBalance.json                   Fail
- NonZeroValue_SUICIDE_ToOneStorageKey.json                       Fail
- NonZeroValue_SUICIDE_ToOneStorageKey_Paris.json                 Fail
- NonZeroValue_TransactionCALL.json                               Fail
- NonZeroValue_TransactionCALL_ToEmpty.json                       Fail
- NonZeroValue_TransactionCALL_ToEmpty_Paris.json                 Fail
- NonZeroValue_TransactionCALL_ToNonNonZeroBalance.json           Fail
- NonZeroValue_TransactionCALL_ToOneStorageKey.json               Fail
- NonZeroValue_TransactionCALL_ToOneStorageKey_Paris.json         Fail
- NonZeroValue_TransactionCALLwithData.json                       Fail
- NonZeroValue_TransactionCALLwithData_ToEmpty.json               Fail
- NonZeroValue_TransactionCALLwithData_ToEmpty_Paris.json         Fail
- NonZeroValue_TransactionCALLwithData_ToNonNonZeroBalance.json   Fail
- NonZeroValue_TransactionCALLwithData_ToOneStorageKey.json       Fail
- NonZeroValue_TransactionCALLwithData_ToOneStorageKey_Paris.json Fail
```
OK: 0/36 Fail: 36/36 Skip: 0/36
## stPreCompiledContracts
```diff
- blake2B.json                                                    Fail
- delegatecall09Undefined.json                                    Fail
- idPrecomps.json                                                 Fail
- identity_to_bigger.json                                         Fail
- identity_to_smaller.json                                        Fail
- modexp.json                                                     Fail
- modexpTests.json                                                Fail
- precompsEIP2929.json                                            Fail
+ precompsEIP2929Cancun.json                                      OK
- sec80.json                                                      Fail
```
OK: 1/10 Fail: 9/10 Skip: 0/10
## stPreCompiledContracts2
```diff
- CALLBlake2f.json                                                Fail
- CALLCODEBlake2f.json                                            Fail
- CALLCODEEcrecover0.json                                         Fail
- CALLCODEEcrecover0_0input.json                                  Fail
- CALLCODEEcrecover0_Gas2999.json                                 Fail
- CALLCODEEcrecover0_NoGas.json                                   Fail
- CALLCODEEcrecover0_completeReturnValue.json                     Fail
- CALLCODEEcrecover0_gas3000.json                                 Fail
- CALLCODEEcrecover0_overlappingInputOutput.json                  Fail
- CALLCODEEcrecover1.json                                         Fail
- CALLCODEEcrecover2.json                                         Fail
- CALLCODEEcrecover3.json                                         Fail
- CALLCODEEcrecover80.json                                        Fail
- CALLCODEEcrecoverH_prefixed0.json                               Fail
- CALLCODEEcrecoverR_prefixed0.json                               Fail
- CALLCODEEcrecoverS_prefixed0.json                               Fail
- CALLCODEEcrecoverV_prefixed0.json                               Fail
- CALLCODEEcrecoverV_prefixedf0.json                              Fail
- CALLCODEIdentitiy_0.json                                        Fail
- CALLCODEIdentitiy_1.json                                        Fail
- CALLCODEIdentity_1_nonzeroValue.json                            Fail
- CALLCODEIdentity_2.json                                         Fail
- CALLCODEIdentity_3.json                                         Fail
- CALLCODEIdentity_4.json                                         Fail
- CALLCODEIdentity_4_gas17.json                                   Fail
- CALLCODEIdentity_4_gas18.json                                   Fail
- CALLCODEIdentity_5.json                                         Fail
- CALLCODERipemd160_0.json                                        Fail
- CALLCODERipemd160_1.json                                        Fail
- CALLCODERipemd160_2.json                                        Fail
- CALLCODERipemd160_3.json                                        Fail
- CALLCODERipemd160_3_postfixed0.json                             Fail
- CALLCODERipemd160_3_prefixed0.json                              Fail
- CALLCODERipemd160_4.json                                        Fail
- CALLCODERipemd160_4_gas719.json                                 Fail
- CALLCODERipemd160_5.json                                        Fail
- CALLCODESha256_0.json                                           Fail
- CALLCODESha256_1.json                                           Fail
- CALLCODESha256_1_nonzeroValue.json                              Fail
- CALLCODESha256_2.json                                           Fail
- CALLCODESha256_3.json                                           Fail
- CALLCODESha256_3_postfix0.json                                  Fail
- CALLCODESha256_3_prefix0.json                                   Fail
- CALLCODESha256_4.json                                           Fail
- CALLCODESha256_4_gas99.json                                     Fail
- CALLCODESha256_5.json                                           Fail
- CallEcrecover0.json                                             Fail
- CallEcrecover0_0input.json                                      Fail
- CallEcrecover0_Gas2999.json                                     Fail
- CallEcrecover0_NoGas.json                                       Fail
- CallEcrecover0_completeReturnValue.json                         Fail
- CallEcrecover0_gas3000.json                                     Fail
- CallEcrecover0_overlappingInputOutput.json                      Fail
- CallEcrecover1.json                                             Fail
- CallEcrecover2.json                                             Fail
- CallEcrecover3.json                                             Fail
- CallEcrecover80.json                                            Fail
- CallEcrecoverCheckLength.json                                   Fail
- CallEcrecoverCheckLengthWrongV.json                             Fail
- CallEcrecoverH_prefixed0.json                                   Fail
- CallEcrecoverInvalidSignature.json                              Fail
- CallEcrecoverR_prefixed0.json                                   Fail
- CallEcrecoverS_prefixed0.json                                   Fail
- CallEcrecoverUnrecoverableKey.json                              Fail
- CallEcrecoverV_prefixed0.json                                   Fail
- CallEcrecover_Overflow.json                                     Fail
- CallIdentitiy_0.json                                            Fail
- CallIdentitiy_1.json                                            Fail
- CallIdentity_1_nonzeroValue.json                                Fail
- CallIdentity_2.json                                             Fail
- CallIdentity_3.json                                             Fail
- CallIdentity_4.json                                             Fail
- CallIdentity_4_gas17.json                                       Fail
- CallIdentity_4_gas18.json                                       Fail
- CallIdentity_5.json                                             Fail
- CallIdentity_6_inputShorterThanOutput.json                      Fail
- CallRipemd160_0.json                                            Fail
- CallRipemd160_1.json                                            Fail
- CallRipemd160_2.json                                            Fail
- CallRipemd160_3.json                                            Fail
- CallRipemd160_3_postfixed0.json                                 Fail
- CallRipemd160_3_prefixed0.json                                  Fail
- CallRipemd160_4.json                                            Fail
- CallRipemd160_4_gas719.json                                     Fail
- CallRipemd160_5.json                                            Fail
- CallSha256_0.json                                               Fail
- CallSha256_1.json                                               Fail
- CallSha256_1_nonzeroValue.json                                  Fail
- CallSha256_2.json                                               Fail
- CallSha256_3.json                                               Fail
- CallSha256_3_postfix0.json                                      Fail
- CallSha256_3_prefix0.json                                       Fail
- CallSha256_4.json                                               Fail
- CallSha256_4_gas99.json                                         Fail
- CallSha256_5.json                                               Fail
- ecrecoverShortBuff.json                                         Fail
- ecrecoverWeirdV.json                                            Fail
- modexpRandomInput.json                                          Fail
- modexp_0_0_0_20500.json                                         Fail
- modexp_0_0_0_22000.json                                         Fail
- modexp_0_0_0_25000.json                                         Fail
- modexp_0_0_0_35000.json                                         Fail
```
OK: 0/102 Fail: 102/102 Skip: 0/102
## stQuadraticComplexityTest
```diff
  Call1MB1024Calldepth.json                                       Skip
  Call20KbytesContract50_1.json                                   Skip
  Call20KbytesContract50_2.json                                   Skip
  Call20KbytesContract50_3.json                                   Skip
  Call50000.json                                                  Skip
  Call50000_ecrec.json                                            Skip
  Call50000_identity.json                                         Skip
  Call50000_identity2.json                                        Skip
  Call50000_rip160.json                                           Skip
  Call50000_sha256.json                                           Skip
  Callcode50000.json                                              Skip
  Create1000.json                                                 Skip
  Create1000Byzantium.json                                        Skip
  Create1000Shnghai.json                                          Skip
  QuadraticComplexitySolidity_CallDataCopy.json                   Skip
  Return50000.json                                                Skip
  Return50000_2.json                                              Skip
```
OK: 0/17 Fail: 0/17 Skip: 17/17
## stRandom
```diff
- randomStatetest0.json                                           Fail
  randomStatetest1.json                                           Skip
- randomStatetest10.json                                          Fail
- randomStatetest100.json                                         Fail
- randomStatetest102.json                                         Fail
- randomStatetest103.json                                         Fail
- randomStatetest104.json                                         Fail
- randomStatetest105.json                                         Fail
- randomStatetest106.json                                         Fail
- randomStatetest107.json                                         Fail
- randomStatetest108.json                                         Fail
- randomStatetest11.json                                          Fail
- randomStatetest110.json                                         Fail
- randomStatetest111.json                                         Fail
- randomStatetest112.json                                         Fail
- randomStatetest114.json                                         Fail
- randomStatetest115.json                                         Fail
- randomStatetest116.json                                         Fail
- randomStatetest117.json                                         Fail
- randomStatetest118.json                                         Fail
- randomStatetest119.json                                         Fail
- randomStatetest12.json                                          Fail
- randomStatetest120.json                                         Fail
- randomStatetest121.json                                         Fail
- randomStatetest122.json                                         Fail
- randomStatetest124.json                                         Fail
- randomStatetest125.json                                         Fail
- randomStatetest126.json                                         Fail
- randomStatetest129.json                                         Fail
- randomStatetest13.json                                          Fail
- randomStatetest130.json                                         Fail
- randomStatetest131.json                                         Fail
- randomStatetest133.json                                         Fail
- randomStatetest134.json                                         Fail
- randomStatetest135.json                                         Fail
- randomStatetest137.json                                         Fail
- randomStatetest138.json                                         Fail
- randomStatetest139.json                                         Fail
- randomStatetest14.json                                          Fail
- randomStatetest142.json                                         Fail
- randomStatetest143.json                                         Fail
- randomStatetest144.json                                         Fail
- randomStatetest145.json                                         Fail
- randomStatetest146.json                                         Fail
- randomStatetest147.json                                         Fail
- randomStatetest148.json                                         Fail
- randomStatetest149.json                                         Fail
- randomStatetest15.json                                          Fail
- randomStatetest150.json                                         Fail
- randomStatetest151.json                                         Fail
- randomStatetest153.json                                         Fail
- randomStatetest154.json                                         Fail
- randomStatetest155.json                                         Fail
- randomStatetest156.json                                         Fail
- randomStatetest157.json                                         Fail
- randomStatetest158.json                                         Fail
- randomStatetest159.json                                         Fail
- randomStatetest16.json                                          Fail
- randomStatetest161.json                                         Fail
- randomStatetest162.json                                         Fail
- randomStatetest163.json                                         Fail
- randomStatetest164.json                                         Fail
- randomStatetest166.json                                         Fail
- randomStatetest167.json                                         Fail
- randomStatetest169.json                                         Fail
- randomStatetest17.json                                          Fail
- randomStatetest171.json                                         Fail
- randomStatetest172.json                                         Fail
- randomStatetest173.json                                         Fail
- randomStatetest174.json                                         Fail
- randomStatetest175.json                                         Fail
- randomStatetest176.json                                         Fail
- randomStatetest177.json                                         Fail
- randomStatetest178.json                                         Fail
- randomStatetest179.json                                         Fail
- randomStatetest18.json                                          Fail
- randomStatetest180.json                                         Fail
- randomStatetest183.json                                         Fail
- randomStatetest184.json                                         Fail
- randomStatetest185.json                                         Fail
- randomStatetest187.json                                         Fail
- randomStatetest188.json                                         Fail
- randomStatetest189.json                                         Fail
- randomStatetest19.json                                          Fail
- randomStatetest190.json                                         Fail
- randomStatetest191.json                                         Fail
- randomStatetest192.json                                         Fail
- randomStatetest194.json                                         Fail
- randomStatetest195.json                                         Fail
- randomStatetest196.json                                         Fail
- randomStatetest197.json                                         Fail
- randomStatetest198.json                                         Fail
- randomStatetest199.json                                         Fail
- randomStatetest2.json                                           Fail
- randomStatetest20.json                                          Fail
- randomStatetest200.json                                         Fail
- randomStatetest201.json                                         Fail
- randomStatetest202.json                                         Fail
- randomStatetest204.json                                         Fail
- randomStatetest205.json                                         Fail
- randomStatetest206.json                                         Fail
- randomStatetest207.json                                         Fail
- randomStatetest208.json                                         Fail
- randomStatetest209.json                                         Fail
- randomStatetest210.json                                         Fail
- randomStatetest211.json                                         Fail
- randomStatetest212.json                                         Fail
- randomStatetest214.json                                         Fail
- randomStatetest215.json                                         Fail
- randomStatetest216.json                                         Fail
- randomStatetest217.json                                         Fail
- randomStatetest219.json                                         Fail
- randomStatetest22.json                                          Fail
- randomStatetest220.json                                         Fail
- randomStatetest221.json                                         Fail
- randomStatetest222.json                                         Fail
- randomStatetest225.json                                         Fail
- randomStatetest226.json                                         Fail
- randomStatetest227.json                                         Fail
- randomStatetest228.json                                         Fail
- randomStatetest23.json                                          Fail
- randomStatetest230.json                                         Fail
- randomStatetest231.json                                         Fail
- randomStatetest232.json                                         Fail
- randomStatetest233.json                                         Fail
- randomStatetest236.json                                         Fail
- randomStatetest237.json                                         Fail
- randomStatetest238.json                                         Fail
- randomStatetest24.json                                          Fail
- randomStatetest242.json                                         Fail
- randomStatetest243.json                                         Fail
- randomStatetest244.json                                         Fail
- randomStatetest245.json                                         Fail
- randomStatetest246.json                                         Fail
- randomStatetest247.json                                         Fail
- randomStatetest248.json                                         Fail
- randomStatetest249.json                                         Fail
- randomStatetest25.json                                          Fail
- randomStatetest250.json                                         Fail
- randomStatetest251.json                                         Fail
- randomStatetest252.json                                         Fail
- randomStatetest254.json                                         Fail
- randomStatetest257.json                                         Fail
- randomStatetest259.json                                         Fail
- randomStatetest26.json                                          Fail
- randomStatetest260.json                                         Fail
- randomStatetest261.json                                         Fail
- randomStatetest263.json                                         Fail
- randomStatetest264.json                                         Fail
- randomStatetest265.json                                         Fail
- randomStatetest266.json                                         Fail
- randomStatetest267.json                                         Fail
- randomStatetest268.json                                         Fail
- randomStatetest269.json                                         Fail
- randomStatetest27.json                                          Fail
- randomStatetest270.json                                         Fail
- randomStatetest271.json                                         Fail
- randomStatetest273.json                                         Fail
- randomStatetest274.json                                         Fail
- randomStatetest275.json                                         Fail
- randomStatetest276.json                                         Fail
- randomStatetest278.json                                         Fail
- randomStatetest279.json                                         Fail
- randomStatetest28.json                                          Fail
- randomStatetest280.json                                         Fail
- randomStatetest281.json                                         Fail
- randomStatetest282.json                                         Fail
- randomStatetest283.json                                         Fail
- randomStatetest285.json                                         Fail
- randomStatetest286.json                                         Fail
- randomStatetest287.json                                         Fail
- randomStatetest288.json                                         Fail
- randomStatetest29.json                                          Fail
- randomStatetest290.json                                         Fail
- randomStatetest291.json                                         Fail
- randomStatetest292.json                                         Fail
- randomStatetest293.json                                         Fail
- randomStatetest294.json                                         Fail
- randomStatetest295.json                                         Fail
- randomStatetest296.json                                         Fail
- randomStatetest297.json                                         Fail
- randomStatetest298.json                                         Fail
- randomStatetest299.json                                         Fail
- randomStatetest3.json                                           Fail
- randomStatetest30.json                                          Fail
- randomStatetest300.json                                         Fail
- randomStatetest301.json                                         Fail
- randomStatetest302.json                                         Fail
- randomStatetest303.json                                         Fail
- randomStatetest304.json                                         Fail
- randomStatetest305.json                                         Fail
- randomStatetest306.json                                         Fail
- randomStatetest307.json                                         Fail
- randomStatetest308.json                                         Fail
- randomStatetest309.json                                         Fail
- randomStatetest31.json                                          Fail
- randomStatetest310.json                                         Fail
- randomStatetest311.json                                         Fail
- randomStatetest312.json                                         Fail
- randomStatetest313.json                                         Fail
- randomStatetest315.json                                         Fail
- randomStatetest316.json                                         Fail
- randomStatetest318.json                                         Fail
- randomStatetest320.json                                         Fail
- randomStatetest321.json                                         Fail
- randomStatetest322.json                                         Fail
- randomStatetest323.json                                         Fail
- randomStatetest325.json                                         Fail
- randomStatetest326.json                                         Fail
- randomStatetest327.json                                         Fail
- randomStatetest329.json                                         Fail
- randomStatetest33.json                                          Fail
- randomStatetest332.json                                         Fail
- randomStatetest333.json                                         Fail
- randomStatetest334.json                                         Fail
- randomStatetest335.json                                         Fail
- randomStatetest336.json                                         Fail
- randomStatetest337.json                                         Fail
- randomStatetest338.json                                         Fail
- randomStatetest339.json                                         Fail
- randomStatetest340.json                                         Fail
- randomStatetest341.json                                         Fail
- randomStatetest342.json                                         Fail
- randomStatetest343.json                                         Fail
- randomStatetest345.json                                         Fail
- randomStatetest346.json                                         Fail
  randomStatetest347.json                                         Skip
- randomStatetest348.json                                         Fail
- randomStatetest349.json                                         Fail
- randomStatetest350.json                                         Fail
- randomStatetest351.json                                         Fail
  randomStatetest352.json                                         Skip
- randomStatetest353.json                                         Fail
- randomStatetest354.json                                         Fail
- randomStatetest355.json                                         Fail
- randomStatetest356.json                                         Fail
- randomStatetest357.json                                         Fail
- randomStatetest358.json                                         Fail
- randomStatetest359.json                                         Fail
- randomStatetest36.json                                          Fail
- randomStatetest360.json                                         Fail
- randomStatetest361.json                                         Fail
- randomStatetest362.json                                         Fail
- randomStatetest363.json                                         Fail
- randomStatetest364.json                                         Fail
- randomStatetest365.json                                         Fail
- randomStatetest366.json                                         Fail
- randomStatetest367.json                                         Fail
- randomStatetest368.json                                         Fail
- randomStatetest369.json                                         Fail
- randomStatetest37.json                                          Fail
- randomStatetest370.json                                         Fail
- randomStatetest371.json                                         Fail
- randomStatetest372.json                                         Fail
- randomStatetest376.json                                         Fail
- randomStatetest378.json                                         Fail
- randomStatetest379.json                                         Fail
- randomStatetest380.json                                         Fail
- randomStatetest381.json                                         Fail
- randomStatetest382.json                                         Fail
- randomStatetest383.json                                         Fail
- randomStatetest384.json                                         Fail
- randomStatetest39.json                                          Fail
- randomStatetest4.json                                           Fail
- randomStatetest41.json                                          Fail
- randomStatetest42.json                                          Fail
- randomStatetest43.json                                          Fail
- randomStatetest45.json                                          Fail
- randomStatetest47.json                                          Fail
- randomStatetest48.json                                          Fail
- randomStatetest49.json                                          Fail
- randomStatetest5.json                                           Fail
- randomStatetest51.json                                          Fail
- randomStatetest52.json                                          Fail
- randomStatetest53.json                                          Fail
- randomStatetest54.json                                          Fail
- randomStatetest55.json                                          Fail
- randomStatetest57.json                                          Fail
- randomStatetest58.json                                          Fail
- randomStatetest59.json                                          Fail
- randomStatetest6.json                                           Fail
- randomStatetest60.json                                          Fail
- randomStatetest62.json                                          Fail
- randomStatetest63.json                                          Fail
- randomStatetest64.json                                          Fail
- randomStatetest66.json                                          Fail
- randomStatetest67.json                                          Fail
- randomStatetest69.json                                          Fail
- randomStatetest72.json                                          Fail
- randomStatetest73.json                                          Fail
- randomStatetest74.json                                          Fail
- randomStatetest75.json                                          Fail
- randomStatetest77.json                                          Fail
- randomStatetest78.json                                          Fail
- randomStatetest80.json                                          Fail
- randomStatetest81.json                                          Fail
- randomStatetest82.json                                          Fail
- randomStatetest83.json                                          Fail
- randomStatetest84.json                                          Fail
- randomStatetest85.json                                          Fail
- randomStatetest87.json                                          Fail
- randomStatetest88.json                                          Fail
- randomStatetest89.json                                          Fail
- randomStatetest9.json                                           Fail
- randomStatetest90.json                                          Fail
- randomStatetest92.json                                          Fail
- randomStatetest95.json                                          Fail
- randomStatetest96.json                                          Fail
- randomStatetest97.json                                          Fail
- randomStatetest98.json                                          Fail
```
OK: 0/310 Fail: 307/310 Skip: 3/310
## stRandom2
```diff
- randomStatetest.json                                            Fail
- randomStatetest384.json                                         Fail
- randomStatetest385.json                                         Fail
- randomStatetest386.json                                         Fail
- randomStatetest387.json                                         Fail
- randomStatetest388.json                                         Fail
- randomStatetest389.json                                         Fail
  randomStatetest393.json                                         Skip
- randomStatetest395.json                                         Fail
- randomStatetest396.json                                         Fail
- randomStatetest397.json                                         Fail
- randomStatetest398.json                                         Fail
- randomStatetest399.json                                         Fail
- randomStatetest401.json                                         Fail
- randomStatetest402.json                                         Fail
- randomStatetest404.json                                         Fail
- randomStatetest405.json                                         Fail
- randomStatetest406.json                                         Fail
- randomStatetest407.json                                         Fail
- randomStatetest408.json                                         Fail
- randomStatetest409.json                                         Fail
- randomStatetest410.json                                         Fail
- randomStatetest411.json                                         Fail
- randomStatetest412.json                                         Fail
- randomStatetest413.json                                         Fail
- randomStatetest414.json                                         Fail
- randomStatetest415.json                                         Fail
- randomStatetest416.json                                         Fail
- randomStatetest417.json                                         Fail
- randomStatetest418.json                                         Fail
- randomStatetest419.json                                         Fail
- randomStatetest420.json                                         Fail
- randomStatetest421.json                                         Fail
- randomStatetest422.json                                         Fail
- randomStatetest424.json                                         Fail
- randomStatetest425.json                                         Fail
- randomStatetest426.json                                         Fail
- randomStatetest428.json                                         Fail
- randomStatetest429.json                                         Fail
- randomStatetest430.json                                         Fail
- randomStatetest433.json                                         Fail
- randomStatetest435.json                                         Fail
- randomStatetest436.json                                         Fail
- randomStatetest437.json                                         Fail
- randomStatetest438.json                                         Fail
- randomStatetest439.json                                         Fail
- randomStatetest440.json                                         Fail
- randomStatetest442.json                                         Fail
- randomStatetest443.json                                         Fail
- randomStatetest444.json                                         Fail
- randomStatetest445.json                                         Fail
- randomStatetest446.json                                         Fail
- randomStatetest447.json                                         Fail
- randomStatetest448.json                                         Fail
- randomStatetest449.json                                         Fail
- randomStatetest450.json                                         Fail
- randomStatetest451.json                                         Fail
- randomStatetest452.json                                         Fail
- randomStatetest454.json                                         Fail
- randomStatetest455.json                                         Fail
- randomStatetest456.json                                         Fail
- randomStatetest457.json                                         Fail
- randomStatetest458.json                                         Fail
- randomStatetest460.json                                         Fail
- randomStatetest461.json                                         Fail
- randomStatetest462.json                                         Fail
- randomStatetest464.json                                         Fail
- randomStatetest465.json                                         Fail
- randomStatetest466.json                                         Fail
- randomStatetest467.json                                         Fail
- randomStatetest469.json                                         Fail
- randomStatetest470.json                                         Fail
- randomStatetest471.json                                         Fail
- randomStatetest472.json                                         Fail
- randomStatetest473.json                                         Fail
- randomStatetest474.json                                         Fail
- randomStatetest475.json                                         Fail
- randomStatetest476.json                                         Fail
- randomStatetest477.json                                         Fail
- randomStatetest478.json                                         Fail
- randomStatetest480.json                                         Fail
- randomStatetest481.json                                         Fail
- randomStatetest482.json                                         Fail
- randomStatetest483.json                                         Fail
- randomStatetest484.json                                         Fail
- randomStatetest485.json                                         Fail
- randomStatetest487.json                                         Fail
- randomStatetest488.json                                         Fail
- randomStatetest489.json                                         Fail
- randomStatetest491.json                                         Fail
- randomStatetest493.json                                         Fail
- randomStatetest494.json                                         Fail
- randomStatetest495.json                                         Fail
- randomStatetest496.json                                         Fail
- randomStatetest497.json                                         Fail
- randomStatetest498.json                                         Fail
- randomStatetest499.json                                         Fail
- randomStatetest500.json                                         Fail
- randomStatetest501.json                                         Fail
- randomStatetest502.json                                         Fail
- randomStatetest503.json                                         Fail
- randomStatetest504.json                                         Fail
- randomStatetest505.json                                         Fail
- randomStatetest506.json                                         Fail
- randomStatetest507.json                                         Fail
- randomStatetest508.json                                         Fail
- randomStatetest509.json                                         Fail
- randomStatetest510.json                                         Fail
- randomStatetest511.json                                         Fail
- randomStatetest512.json                                         Fail
- randomStatetest513.json                                         Fail
- randomStatetest514.json                                         Fail
- randomStatetest516.json                                         Fail
- randomStatetest517.json                                         Fail
- randomStatetest518.json                                         Fail
- randomStatetest519.json                                         Fail
- randomStatetest520.json                                         Fail
- randomStatetest521.json                                         Fail
- randomStatetest523.json                                         Fail
- randomStatetest524.json                                         Fail
- randomStatetest525.json                                         Fail
- randomStatetest526.json                                         Fail
- randomStatetest527.json                                         Fail
- randomStatetest528.json                                         Fail
- randomStatetest531.json                                         Fail
- randomStatetest532.json                                         Fail
- randomStatetest533.json                                         Fail
- randomStatetest534.json                                         Fail
- randomStatetest535.json                                         Fail
- randomStatetest536.json                                         Fail
- randomStatetest537.json                                         Fail
- randomStatetest539.json                                         Fail
- randomStatetest541.json                                         Fail
- randomStatetest542.json                                         Fail
- randomStatetest543.json                                         Fail
- randomStatetest544.json                                         Fail
- randomStatetest545.json                                         Fail
- randomStatetest546.json                                         Fail
- randomStatetest547.json                                         Fail
- randomStatetest548.json                                         Fail
- randomStatetest550.json                                         Fail
- randomStatetest552.json                                         Fail
- randomStatetest553.json                                         Fail
- randomStatetest554.json                                         Fail
- randomStatetest555.json                                         Fail
- randomStatetest556.json                                         Fail
- randomStatetest558.json                                         Fail
- randomStatetest559.json                                         Fail
- randomStatetest560.json                                         Fail
- randomStatetest562.json                                         Fail
- randomStatetest563.json                                         Fail
- randomStatetest564.json                                         Fail
- randomStatetest565.json                                         Fail
- randomStatetest566.json                                         Fail
- randomStatetest567.json                                         Fail
- randomStatetest569.json                                         Fail
- randomStatetest571.json                                         Fail
- randomStatetest572.json                                         Fail
- randomStatetest574.json                                         Fail
- randomStatetest575.json                                         Fail
- randomStatetest576.json                                         Fail
- randomStatetest577.json                                         Fail
- randomStatetest578.json                                         Fail
- randomStatetest579.json                                         Fail
- randomStatetest580.json                                         Fail
- randomStatetest581.json                                         Fail
- randomStatetest582.json                                         Fail
- randomStatetest583.json                                         Fail
- randomStatetest584.json                                         Fail
- randomStatetest585.json                                         Fail
- randomStatetest586.json                                         Fail
- randomStatetest587.json                                         Fail
- randomStatetest588.json                                         Fail
- randomStatetest589.json                                         Fail
- randomStatetest592.json                                         Fail
- randomStatetest596.json                                         Fail
- randomStatetest597.json                                         Fail
- randomStatetest599.json                                         Fail
- randomStatetest600.json                                         Fail
- randomStatetest601.json                                         Fail
- randomStatetest602.json                                         Fail
- randomStatetest603.json                                         Fail
- randomStatetest604.json                                         Fail
- randomStatetest605.json                                         Fail
- randomStatetest607.json                                         Fail
- randomStatetest608.json                                         Fail
- randomStatetest609.json                                         Fail
- randomStatetest610.json                                         Fail
- randomStatetest611.json                                         Fail
- randomStatetest612.json                                         Fail
- randomStatetest615.json                                         Fail
- randomStatetest616.json                                         Fail
- randomStatetest618.json                                         Fail
- randomStatetest620.json                                         Fail
- randomStatetest621.json                                         Fail
- randomStatetest624.json                                         Fail
- randomStatetest625.json                                         Fail
  randomStatetest626.json                                         Skip
- randomStatetest627.json                                         Fail
- randomStatetest628.json                                         Fail
- randomStatetest629.json                                         Fail
- randomStatetest630.json                                         Fail
- randomStatetest632.json                                         Fail
- randomStatetest633.json                                         Fail
- randomStatetest635.json                                         Fail
- randomStatetest636.json                                         Fail
- randomStatetest637.json                                         Fail
- randomStatetest638.json                                         Fail
- randomStatetest639.json                                         Fail
- randomStatetest640.json                                         Fail
- randomStatetest641.json                                         Fail
- randomStatetest642.json                                         Fail
- randomStatetest643.json                                         Fail
- randomStatetest644.json                                         Fail
- randomStatetest645.json                                         Fail
- randomStatetest646.json                                         Fail
- randomStatetest647.json                                         Fail
- randomStatetest648.json                                         Fail
- randomStatetest649.json                                         Fail
- randomStatetest650.json                                         Fail
```
OK: 0/220 Fail: 218/220 Skip: 2/220
## stRecursiveCreate
```diff
- recursiveCreate.json                                            Fail
  recursiveCreateReturnValue.json                                 Skip
```
OK: 0/2 Fail: 1/2 Skip: 1/2
## stRefundTest
```diff
- refund50_1.json                                                 Fail
- refund50_2.json                                                 Fail
- refund50percentCap.json                                         Fail
- refund600.json                                                  Fail
- refundFF.json                                                   Fail
- refundMax.json                                                  Fail
- refundResetFrontier.json                                        Fail
- refundSSTORE.json                                               Fail
- refundSuicide50procentCap.json                                  Fail
- refund_CallA.json                                               Fail
- refund_CallA_OOG.json                                           Fail
- refund_CallA_notEnoughGasInCall.json                            Fail
- refund_CallToSuicideNoStorage.json                              Fail
- refund_CallToSuicideStorage.json                                Fail
- refund_CallToSuicideTwice.json                                  Fail
- refund_NoOOG_1.json                                             Fail
- refund_OOG.json                                                 Fail
- refund_TxToSuicide.json                                         Fail
- refund_TxToSuicideOOG.json                                      Fail
- refund_changeNonZeroStorage.json                                Fail
- refund_getEtherBack.json                                        Fail
- refund_multimpleSuicide.json                                    Fail
- refund_singleSuicide.json                                       Fail
```
OK: 0/23 Fail: 23/23 Skip: 0/23
## stReturnDataTest
```diff
- call_ecrec_success_empty_then_returndatasize.json               Fail
- call_outsize_then_create_successful_then_returndatasize.json    Fail
- call_then_call_value_fail_then_returndatasize.json              Fail
- call_then_create_successful_then_returndatasize.json            Fail
- clearReturnBuffer.json                                          Fail
- create_callprecompile_returndatasize.json                       Fail
- modexp_modsize0_returndatasize.json                             Fail
- returndatacopy_0_0_following_successful_create.json             Fail
- returndatacopy_afterFailing_create.json                         Fail
- returndatacopy_after_failing_callcode.json                      Fail
- returndatacopy_after_failing_delegatecall.json                  Fail
- returndatacopy_after_failing_staticcall.json                    Fail
- returndatacopy_after_revert_in_staticcall.json                  Fail
- returndatacopy_after_successful_callcode.json                   Fail
- returndatacopy_after_successful_delegatecall.json               Fail
- returndatacopy_after_successful_staticcall.json                 Fail
- returndatacopy_following_call.json                              Fail
- returndatacopy_following_create.json                            Fail
- returndatacopy_following_failing_call.json                      Fail
- returndatacopy_following_revert.json                            Fail
- returndatacopy_following_revert_in_create.json                  Fail
- returndatacopy_following_successful_create.json                 Fail
- returndatacopy_following_too_big_transfer.json                  Fail
- returndatacopy_initial.json                                     Fail
- returndatacopy_initial_256.json                                 Fail
- returndatacopy_initial_big_sum.json                             Fail
- returndatacopy_overrun.json                                     Fail
- returndatasize_after_failing_callcode.json                      Fail
- returndatasize_after_failing_delegatecall.json                  Fail
- returndatasize_after_failing_staticcall.json                    Fail
- returndatasize_after_oog_after_deeper.json                      Fail
- returndatasize_after_successful_callcode.json                   Fail
- returndatasize_after_successful_delegatecall.json               Fail
- returndatasize_after_successful_staticcall.json                 Fail
- returndatasize_bug.json                                         Fail
- returndatasize_following_successful_create.json                 Fail
- returndatasize_initial.json                                     Fail
- returndatasize_initial_zero_read.json                           Fail
- revertRetDataSize.json                                          Fail
- subcallReturnMoreThenExpected.json                              Fail
- tooLongReturnDataCopy.json                                      Fail
```
OK: 0/41 Fail: 41/41 Skip: 0/41
## stRevertTest
```diff
  LoopCallsDepthThenRevert.json                                   Skip
  LoopCallsDepthThenRevert2.json                                  Skip
  LoopCallsDepthThenRevert3.json                                  Skip
  LoopCallsThenRevert.json                                        Skip
  LoopDelegateCallsDepthThenRevert.json                           Skip
- NashatyrevSuicideRevert.json                                    Fail
- PythonRevertTestTue201814-1430.json                             Fail
- RevertDepth2.json                                               Fail
- RevertDepthCreateAddressCollision.json                          Fail
- RevertDepthCreateOOG.json                                       Fail
- RevertInCallCode.json                                           Fail
- RevertInCreateInInit.json                                       Fail
- RevertInCreateInInit_Paris.json                                 Fail
- RevertInDelegateCall.json                                       Fail
- RevertInStaticCall.json                                         Fail
- RevertOnEmptyStack.json                                         Fail
- RevertOpcode.json                                               Fail
- RevertOpcodeCalls.json                                          Fail
- RevertOpcodeCreate.json                                         Fail
- RevertOpcodeDirectCall.json                                     Fail
- RevertOpcodeInCallsOnNonEmptyReturnData.json                    Fail
- RevertOpcodeInCreateReturns.json                                Fail
- RevertOpcodeInInit.json                                         Fail
- RevertOpcodeMultipleSubCalls.json                               Fail
- RevertOpcodeReturn.json                                         Fail
- RevertOpcodeWithBigOutputInInit.json                            Fail
- RevertPrecompiledTouch.json                                     Fail
- RevertPrecompiledTouchExactOOG.json                             Fail
- RevertPrecompiledTouchExactOOG_Paris.json                       Fail
- RevertPrecompiledTouch_Paris.json                               Fail
- RevertPrecompiledTouch_nonce.json                               Fail
- RevertPrecompiledTouch_noncestorage.json                        Fail
- RevertPrecompiledTouch_storage.json                             Fail
- RevertPrecompiledTouch_storage_Paris.json                       Fail
- RevertPrefound.json                                             Fail
- RevertPrefoundCall.json                                         Fail
- RevertPrefoundCallOOG.json                                      Fail
- RevertPrefoundEmpty.json                                        Fail
- RevertPrefoundEmptyCall.json                                    Fail
- RevertPrefoundEmptyCallOOG.json                                 Fail
- RevertPrefoundEmptyCallOOG_Paris.json                           Fail
- RevertPrefoundEmptyCall_Paris.json                              Fail
- RevertPrefoundEmptyOOG.json                                     Fail
- RevertPrefoundEmptyOOG_Paris.json                               Fail
- RevertPrefoundEmpty_Paris.json                                  Fail
- RevertPrefoundOOG.json                                          Fail
- RevertRemoteSubCallStorageOOG.json                              Fail
- RevertSubCallStorageOOG.json                                    Fail
- RevertSubCallStorageOOG2.json                                   Fail
- TouchToEmptyAccountRevert.json                                  Fail
- TouchToEmptyAccountRevert2.json                                 Fail
- TouchToEmptyAccountRevert2_Paris.json                           Fail
- TouchToEmptyAccountRevert3.json                                 Fail
- TouchToEmptyAccountRevert3_Paris.json                           Fail
- TouchToEmptyAccountRevert_Paris.json                            Fail
- costRevert.json                                                 Fail
- stateRevert.json                                                Fail
```
OK: 0/57 Fail: 52/57 Skip: 5/57
## stSLoadTest
```diff
- sloadGasCost.json                                               Fail
```
OK: 0/1 Fail: 1/1 Skip: 0/1
## stSStoreTest
```diff
- InitCollision.json                                              Fail
- InitCollisionNonZeroNonce.json                                  Fail
- InitCollisionParis.json                                         Fail
- SstoreCallToSelfSubRefundBelowZero.json                         Fail
- sstoreGas.json                                                  Fail
- sstore_0to0.json                                                Fail
- sstore_0to0to0.json                                             Fail
- sstore_0to0toX.json                                             Fail
- sstore_0toX.json                                                Fail
- sstore_0toXto0.json                                             Fail
- sstore_0toXto0toX.json                                          Fail
- sstore_0toXtoX.json                                             Fail
- sstore_0toXtoY.json                                             Fail
- sstore_Xto0.json                                                Fail
- sstore_Xto0to0.json                                             Fail
- sstore_Xto0toX.json                                             Fail
- sstore_Xto0toXto0.json                                          Fail
- sstore_Xto0toY.json                                             Fail
- sstore_XtoX.json                                                Fail
- sstore_XtoXto0.json                                             Fail
- sstore_XtoXtoX.json                                             Fail
- sstore_XtoXtoY.json                                             Fail
- sstore_XtoY.json                                                Fail
- sstore_XtoYto0.json                                             Fail
- sstore_XtoYtoX.json                                             Fail
- sstore_XtoYtoY.json                                             Fail
- sstore_XtoYtoZ.json                                             Fail
- sstore_changeFromExternalCallInInitCode.json                    Fail
- sstore_gasLeft.json                                             Fail
```
OK: 0/29 Fail: 29/29 Skip: 0/29
## stSelfBalance
```diff
- diffPlaces.json                                                 Fail
- selfBalance.json                                                Fail
- selfBalanceCallTypes.json                                       Fail
- selfBalanceEqualsBalance.json                                   Fail
- selfBalanceGasCost.json                                         Fail
- selfBalanceUpdate.json                                          Fail
```
OK: 0/6 Fail: 6/6 Skip: 0/6
## stShift
```diff
- sar00.json                                                      Fail
- sar01.json                                                      Fail
- sar10.json                                                      Fail
- sar11.json                                                      Fail
- sar_0_256-1.json                                                Fail
- sar_2^254_254.json                                              Fail
- sar_2^255-1_248.json                                            Fail
- sar_2^255-1_254.json                                            Fail
- sar_2^255-1_255.json                                            Fail
- sar_2^255-1_256.json                                            Fail
- sar_2^255_1.json                                                Fail
- sar_2^255_255.json                                              Fail
- sar_2^255_256.json                                              Fail
- sar_2^255_257.json                                              Fail
- sar_2^256-1_0.json                                              Fail
- sar_2^256-1_1.json                                              Fail
- sar_2^256-1_255.json                                            Fail
- sar_2^256-1_256.json                                            Fail
- shiftCombinations.json                                          Fail
- shiftSignedCombinations.json                                    Fail
- shl01-0100.json                                                 Fail
- shl01-0101.json                                                 Fail
- shl01-ff.json                                                   Fail
- shl01.json                                                      Fail
- shl10.json                                                      Fail
- shl11.json                                                      Fail
- shl_-1_0.json                                                   Fail
- shl_-1_1.json                                                   Fail
- shl_-1_255.json                                                 Fail
- shl_-1_256.json                                                 Fail
- shl_2^255-1_1.json                                              Fail
- shr01.json                                                      Fail
- shr10.json                                                      Fail
- shr11.json                                                      Fail
- shr_-1_0.json                                                   Fail
- shr_-1_1.json                                                   Fail
- shr_-1_255.json                                                 Fail
- shr_-1_256.json                                                 Fail
- shr_2^255_1.json                                                Fail
- shr_2^255_255.json                                              Fail
- shr_2^255_256.json                                              Fail
- shr_2^255_257.json                                              Fail
```
OK: 0/42 Fail: 42/42 Skip: 0/42
## stSolidityTest
```diff
- AmbiguousMethod.json                                            Fail
- ByZero.json                                                     Fail
- CallInfiniteLoop.json                                           Fail
- CallLowLevelCreatesSolidity.json                                Fail
- CallRecursiveMethods.json                                       Fail
- ContractInheritance.json                                        Fail
- CreateContractFromMethod.json                                   Fail
- RecursiveCreateContracts.json                                   Fail
- RecursiveCreateContractsCreate4Contracts.json                   Fail
- SelfDestruct.json                                               Fail
- TestBlockAndTransactionProperties.json                          Fail
- TestContractInteraction.json                                    Fail
- TestContractSuicide.json                                        Fail
- TestCryptographicFunctions.json                                 Fail
- TestKeywords.json                                               Fail
- TestOverflow.json                                               Fail
- TestStoreGasPrices.json                                         Fail
- TestStructuresAndVariabless.json                                Fail
```
OK: 0/18 Fail: 18/18 Skip: 0/18
## stSpecialTest
```diff
- FailedCreateRevertsDeletion.json                                Fail
- FailedCreateRevertsDeletionParis.json                           Fail
  JUMPDEST_Attack.json                                            Skip
  JUMPDEST_AttackwithJump.json                                    Skip
- OverflowGasMakeMoney.json                                       Fail
- StackDepthLimitSEC.json                                         Fail
- block504980.json                                                Fail
- deploymentError.json                                            Fail
- eoaEmpty.json                                                   Fail
- eoaEmptyParis.json                                              Fail
- failed_tx_xcf416c53.json                                        Fail
- failed_tx_xcf416c53_Paris.json                                  Fail
- gasPrice0.json                                                  Fail
- makeMoney.json                                                  Fail
- push32withoutByte.json                                          Fail
- selfdestructEIP2929.json                                        Fail
- sha3_deja.json                                                  Fail
- tx_e1c174e2.json                                                Fail
```
OK: 0/18 Fail: 16/18 Skip: 2/18
## stStackTests
```diff
- shallowStack.json                                               Fail
- stackOverflow.json                                              Fail
- stackOverflowDUP.json                                           Fail
- stackOverflowM1.json                                            Fail
- stackOverflowM1DUP.json                                         Fail
- stackOverflowM1PUSH.json                                        Fail
- stackOverflowPUSH.json                                          Fail
- stackOverflowSWAP.json                                          Fail
- stacksanitySWAP.json                                            Fail
- underflowTest.json                                              Fail
```
OK: 0/10 Fail: 10/10 Skip: 0/10
## stStaticCall
```diff
- StaticcallToPrecompileFromCalledContract.json                   Fail
- StaticcallToPrecompileFromContractInitialization.json           Fail
- StaticcallToPrecompileFromTransaction.json                      Fail
- static_ABAcalls0.json                                           Fail
- static_ABAcalls1.json                                           Fail
- static_ABAcalls2.json                                           Fail
- static_ABAcalls3.json                                           Fail
- static_ABAcallsSuicide0.json                                    Fail
- static_ABAcallsSuicide1.json                                    Fail
- static_CALL_OneVCallSuicide.json                                Fail
- static_CALL_ZeroVCallSuicide.json                               Fail
- static_CREATE_ContractSuicideDuringInit.json                    Fail
- static_CREATE_ContractSuicideDuringInit_ThenStoreThenReturn.jso Fail
- static_CREATE_ContractSuicideDuringInit_WithValue.json          Fail
- static_CREATE_EmptyContractAndCallIt_0wei.json                  Fail
- static_CREATE_EmptyContractWithStorageAndCallIt_0wei.json       Fail
- static_Call10.json                                              Fail
  static_Call1024BalanceTooLow.json                               Skip
  static_Call1024BalanceTooLow2.json                              Skip
  static_Call1024OOG.json                                         Skip
  static_Call1024PreCalls.json                                    Skip
  static_Call1024PreCalls2.json                                   Skip
  static_Call1024PreCalls3.json                                   Skip
  static_Call1MB1024Calldepth.json                                Skip
  static_Call50000.json                                           Skip
  static_Call50000_ecrec.json                                     Skip
  static_Call50000_identity.json                                  Skip
  static_Call50000_identity2.json                                 Skip
  static_Call50000_rip160.json                                    Skip
- static_Call50000bytesContract50_1.json                          Fail
- static_Call50000bytesContract50_2.json                          Fail
- static_Call50000bytesContract50_3.json                          Fail
- static_CallAndCallcodeConsumeMoreGasThenTransactionHas.json     Fail
- static_CallAskMoreGasOnDepth2ThenTransactionHas.json            Fail
- static_CallContractToCreateContractAndCallItOOG.json            Fail
- static_CallContractToCreateContractOOG.json                     Fail
- static_CallContractToCreateContractOOGBonusGas.json             Fail
- static_CallContractToCreateContractWhichWouldCreateContractIfCa Fail
- static_CallEcrecover0.json                                      Fail
- static_CallEcrecover0_0input.json                               Fail
- static_CallEcrecover0_Gas2999.json                              Fail
- static_CallEcrecover0_NoGas.json                                Fail
- static_CallEcrecover0_completeReturnValue.json                  Fail
- static_CallEcrecover0_gas3000.json                              Fail
- static_CallEcrecover0_overlappingInputOutput.json               Fail
- static_CallEcrecover1.json                                      Fail
- static_CallEcrecover2.json                                      Fail
- static_CallEcrecover3.json                                      Fail
- static_CallEcrecover80.json                                     Fail
- static_CallEcrecoverCheckLength.json                            Fail
- static_CallEcrecoverCheckLengthWrongV.json                      Fail
- static_CallEcrecoverH_prefixed0.json                            Fail
- static_CallEcrecoverR_prefixed0.json                            Fail
- static_CallEcrecoverS_prefixed0.json                            Fail
- static_CallEcrecoverV_prefixed0.json                            Fail
- static_CallGoesOOGOnSecondLevel.json                            Fail
- static_CallGoesOOGOnSecondLevel2.json                           Fail
- static_CallIdentitiy_1.json                                     Fail
- static_CallIdentity_1_nonzeroValue.json                         Fail
- static_CallIdentity_2.json                                      Fail
- static_CallIdentity_3.json                                      Fail
- static_CallIdentity_4.json                                      Fail
- static_CallIdentity_4_gas17.json                                Fail
- static_CallIdentity_4_gas18.json                                Fail
- static_CallIdentity_5.json                                      Fail
- static_CallLoseGasOOG.json                                      Fail
- static_CallRecursiveBomb0.json                                  Fail
- static_CallRecursiveBomb0_OOG_atMaxCallDepth.json               Fail
- static_CallRecursiveBomb1.json                                  Fail
- static_CallRecursiveBomb2.json                                  Fail
- static_CallRecursiveBomb3.json                                  Fail
- static_CallRecursiveBombLog.json                                Fail
- static_CallRecursiveBombLog2.json                               Fail
- static_CallRecursiveBombPreCall.json                            Fail
- static_CallRecursiveBombPreCall2.json                           Fail
- static_CallRipemd160_1.json                                     Fail
- static_CallRipemd160_2.json                                     Fail
- static_CallRipemd160_3.json                                     Fail
- static_CallRipemd160_3_postfixed0.json                          Fail
- static_CallRipemd160_3_prefixed0.json                           Fail
- static_CallRipemd160_4.json                                     Fail
- static_CallRipemd160_4_gas719.json                              Fail
- static_CallRipemd160_5.json                                     Fail
- static_CallSha256_1.json                                        Fail
- static_CallSha256_1_nonzeroValue.json                           Fail
- static_CallSha256_2.json                                        Fail
- static_CallSha256_3.json                                        Fail
- static_CallSha256_3_postfix0.json                               Fail
- static_CallSha256_3_prefix0.json                                Fail
- static_CallSha256_4.json                                        Fail
- static_CallSha256_4_gas99.json                                  Fail
- static_CallSha256_5.json                                        Fail
- static_CallToNameRegistrator0.json                              Fail
- static_CallToReturn1.json                                       Fail
- static_CalltoReturn2.json                                       Fail
- static_CheckCallCostOOG.json                                    Fail
- static_CheckOpcodes.json                                        Fail
- static_CheckOpcodes2.json                                       Fail
- static_CheckOpcodes3.json                                       Fail
- static_CheckOpcodes4.json                                       Fail
- static_CheckOpcodes5.json                                       Fail
- static_ExecuteCallThatAskForeGasThenTrabsactionHas.json         Fail
- static_InternalCallHittingGasLimit.json                         Fail
- static_InternalCallHittingGasLimit2.json                        Fail
- static_InternlCallStoreClearsOOG.json                           Fail
- static_LoopCallsDepthThenRevert.json                            Fail
- static_LoopCallsDepthThenRevert2.json                           Fail
- static_LoopCallsDepthThenRevert3.json                           Fail
- static_LoopCallsThenRevert.json                                 Fail
- static_PostToReturn1.json                                       Fail
- static_RETURN_Bounds.json                                       Fail
- static_RETURN_BoundsOOG.json                                    Fail
- static_RawCallGasAsk.json                                       Fail
- static_Return50000_2.json                                       Fail
- static_ReturnTest.json                                          Fail
- static_ReturnTest2.json                                         Fail
- static_RevertDepth2.json                                        Fail
- static_RevertOpcodeCalls.json                                   Fail
- static_ZeroValue_CALL_OOGRevert.json                            Fail
- static_ZeroValue_SUICIDE_OOGRevert.json                         Fail
- static_callBasic.json                                           Fail
- static_callChangeRevert.json                                    Fail
- static_callCreate.json                                          Fail
- static_callCreate2.json                                         Fail
- static_callCreate3.json                                         Fail
- static_callOutput1.json                                         Fail
- static_callOutput2.json                                         Fail
- static_callOutput3.json                                         Fail
- static_callOutput3Fail.json                                     Fail
- static_callOutput3partial.json                                  Fail
- static_callOutput3partialFail.json                              Fail
- static_callToCallCodeOpCodeCheck.json                           Fail
- static_callToCallOpCodeCheck.json                               Fail
- static_callToDelCallOpCodeCheck.json                            Fail
- static_callToStaticOpCodeCheck.json                             Fail
- static_callWithHighValue.json                                   Fail
- static_callWithHighValueAndGasOOG.json                          Fail
- static_callWithHighValueAndOOGatTxLevel.json                    Fail
- static_callWithHighValueOOGinCall.json                          Fail
- static_call_OOG_additionalGasCosts1.json                        Fail
- static_call_OOG_additionalGasCosts2.json                        Fail
- static_call_OOG_additionalGasCosts2_Paris.json                  Fail
- static_call_value_inherit.json                                  Fail
- static_call_value_inherit_from_call.json                        Fail
- static_callcall_00.json                                         Fail
- static_callcall_00_OOGE.json                                    Fail
- static_callcall_00_OOGE_1.json                                  Fail
- static_callcall_00_OOGE_2.json                                  Fail
- static_callcall_00_SuicideEnd.json                              Fail
- static_callcallcall_000.json                                    Fail
- static_callcallcall_000_OOGE.json                               Fail
- static_callcallcall_000_OOGMAfter.json                          Fail
- static_callcallcall_000_OOGMAfter2.json                         Fail
- static_callcallcall_000_OOGMBefore.json                         Fail
- static_callcallcall_000_SuicideEnd.json                         Fail
- static_callcallcall_000_SuicideMiddle.json                      Fail
- static_callcallcall_ABCB_RECURSIVE.json                         Fail
- static_callcallcallcode_001.json                                Fail
- static_callcallcallcode_001_2.json                              Fail
- static_callcallcallcode_001_OOGE.json                           Fail
- static_callcallcallcode_001_OOGE_2.json                         Fail
- static_callcallcallcode_001_OOGMAfter.json                      Fail
- static_callcallcallcode_001_OOGMAfter2.json                     Fail
- static_callcallcallcode_001_OOGMAfter_2.json                    Fail
- static_callcallcallcode_001_OOGMAfter_3.json                    Fail
- static_callcallcallcode_001_OOGMBefore.json                     Fail
- static_callcallcallcode_001_OOGMBefore2.json                    Fail
- static_callcallcallcode_001_SuicideEnd.json                     Fail
- static_callcallcallcode_001_SuicideEnd2.json                    Fail
- static_callcallcallcode_001_SuicideMiddle.json                  Fail
- static_callcallcallcode_001_SuicideMiddle2.json                 Fail
- static_callcallcallcode_ABCB_RECURSIVE.json                     Fail
- static_callcallcallcode_ABCB_RECURSIVE2.json                    Fail
- static_callcallcode_01_2.json                                   Fail
- static_callcallcode_01_OOGE_2.json                              Fail
- static_callcallcode_01_SuicideEnd.json                          Fail
- static_callcallcode_01_SuicideEnd2.json                         Fail
- static_callcallcodecall_010.json                                Fail
- static_callcallcodecall_010_2.json                              Fail
- static_callcallcodecall_010_OOGE.json                           Fail
- static_callcallcodecall_010_OOGE_2.json                         Fail
- static_callcallcodecall_010_OOGMAfter.json                      Fail
- static_callcallcodecall_010_OOGMAfter2.json                     Fail
- static_callcallcodecall_010_OOGMAfter_2.json                    Fail
- static_callcallcodecall_010_OOGMAfter_3.json                    Fail
- static_callcallcodecall_010_OOGMBefore.json                     Fail
- static_callcallcodecall_010_OOGMBefore2.json                    Fail
- static_callcallcodecall_010_SuicideEnd.json                     Fail
- static_callcallcodecall_010_SuicideEnd2.json                    Fail
- static_callcallcodecall_010_SuicideMiddle.json                  Fail
- static_callcallcodecall_010_SuicideMiddle2.json                 Fail
- static_callcallcodecall_ABCB_RECURSIVE.json                     Fail
- static_callcallcodecall_ABCB_RECURSIVE2.json                    Fail
- static_callcallcodecallcode_011.json                            Fail
- static_callcallcodecallcode_011_2.json                          Fail
- static_callcallcodecallcode_011_OOGE.json                       Fail
- static_callcallcodecallcode_011_OOGE_2.json                     Fail
- static_callcallcodecallcode_011_OOGMAfter.json                  Fail
- static_callcallcodecallcode_011_OOGMAfter2.json                 Fail
- static_callcallcodecallcode_011_OOGMAfter_1.json                Fail
- static_callcallcodecallcode_011_OOGMAfter_2.json                Fail
- static_callcallcodecallcode_011_OOGMBefore.json                 Fail
- static_callcallcodecallcode_011_OOGMBefore2.json                Fail
- static_callcallcodecallcode_011_SuicideEnd.json                 Fail
- static_callcallcodecallcode_011_SuicideEnd2.json                Fail
- static_callcallcodecallcode_011_SuicideMiddle.json              Fail
- static_callcallcodecallcode_011_SuicideMiddle2.json             Fail
- static_callcallcodecallcode_ABCB_RECURSIVE.json                 Fail
- static_callcallcodecallcode_ABCB_RECURSIVE2.json                Fail
- static_callcode_checkPC.json                                    Fail
- static_callcodecall_10.json                                     Fail
- static_callcodecall_10_2.json                                   Fail
- static_callcodecall_10_OOGE.json                                Fail
- static_callcodecall_10_OOGE_2.json                              Fail
- static_callcodecall_10_SuicideEnd.json                          Fail
- static_callcodecall_10_SuicideEnd2.json                         Fail
- static_callcodecallcall_100.json                                Fail
- static_callcodecallcall_100_2.json                              Fail
- static_callcodecallcall_100_OOGE.json                           Fail
- static_callcodecallcall_100_OOGE2.json                          Fail
- static_callcodecallcall_100_OOGMAfter.json                      Fail
- static_callcodecallcall_100_OOGMAfter2.json                     Fail
- static_callcodecallcall_100_OOGMAfter_2.json                    Fail
- static_callcodecallcall_100_OOGMAfter_3.json                    Fail
- static_callcodecallcall_100_OOGMBefore.json                     Fail
- static_callcodecallcall_100_OOGMBefore2.json                    Fail
- static_callcodecallcall_100_SuicideEnd.json                     Fail
- static_callcodecallcall_100_SuicideEnd2.json                    Fail
- static_callcodecallcall_100_SuicideMiddle.json                  Fail
- static_callcodecallcall_100_SuicideMiddle2.json                 Fail
- static_callcodecallcall_ABCB_RECURSIVE.json                     Fail
- static_callcodecallcall_ABCB_RECURSIVE2.json                    Fail
- static_callcodecallcallcode_101.json                            Fail
- static_callcodecallcallcode_101_2.json                          Fail
- static_callcodecallcallcode_101_OOGE.json                       Fail
- static_callcodecallcallcode_101_OOGE_2.json                     Fail
- static_callcodecallcallcode_101_OOGMAfter.json                  Fail
- static_callcodecallcallcode_101_OOGMAfter2.json                 Fail
- static_callcodecallcallcode_101_OOGMAfter_1.json                Fail
- static_callcodecallcallcode_101_OOGMAfter_3.json                Fail
- static_callcodecallcallcode_101_OOGMBefore.json                 Fail
- static_callcodecallcallcode_101_OOGMBefore2.json                Fail
- static_callcodecallcallcode_101_SuicideEnd.json                 Fail
- static_callcodecallcallcode_101_SuicideEnd2.json                Fail
- static_callcodecallcallcode_101_SuicideMiddle.json              Fail
- static_callcodecallcallcode_101_SuicideMiddle2.json             Fail
- static_callcodecallcallcode_ABCB_RECURSIVE.json                 Fail
- static_callcodecallcallcode_ABCB_RECURSIVE2.json                Fail
- static_callcodecallcodecall_110.json                            Fail
- static_callcodecallcodecall_1102.json                           Fail
- static_callcodecallcodecall_110_2.json                          Fail
- static_callcodecallcodecall_110_OOGE.json                       Fail
- static_callcodecallcodecall_110_OOGE2.json                      Fail
- static_callcodecallcodecall_110_OOGMAfter.json                  Fail
- static_callcodecallcodecall_110_OOGMAfter2.json                 Fail
- static_callcodecallcodecall_110_OOGMAfter_2.json                Fail
- static_callcodecallcodecall_110_OOGMAfter_3.json                Fail
- static_callcodecallcodecall_110_OOGMBefore.json                 Fail
- static_callcodecallcodecall_110_OOGMBefore2.json                Fail
- static_callcodecallcodecall_110_SuicideEnd.json                 Fail
- static_callcodecallcodecall_110_SuicideEnd2.json                Fail
- static_callcodecallcodecall_110_SuicideMiddle.json              Fail
- static_callcodecallcodecall_110_SuicideMiddle2.json             Fail
- static_callcodecallcodecall_ABCB_RECURSIVE.json                 Fail
- static_callcodecallcodecall_ABCB_RECURSIVE2.json                Fail
- static_callcodecallcodecallcode_111_SuicideEnd.json             Fail
- static_calldelcode_01.json                                      Fail
- static_calldelcode_01_OOGE.json                                 Fail
- static_contractCreationMakeCallThatAskMoreGasThenTransactionPro Fail
- static_contractCreationOOGdontLeaveEmptyContractViaTransaction. Fail
- static_log0_emptyMem.json                                       Fail
- static_log0_logMemStartTooHigh.json                             Fail
- static_log0_logMemsizeTooHigh.json                              Fail
- static_log0_logMemsizeZero.json                                 Fail
- static_log0_nonEmptyMem.json                                    Fail
- static_log0_nonEmptyMem_logMemSize1.json                        Fail
- static_log0_nonEmptyMem_logMemSize1_logMemStart31.json          Fail
- static_log1_MaxTopic.json                                       Fail
- static_log1_emptyMem.json                                       Fail
- static_log1_logMemStartTooHigh.json                             Fail
- static_log1_logMemsizeTooHigh.json                              Fail
- static_log1_logMemsizeZero.json                                 Fail
- static_log_Caller.json                                          Fail
- static_makeMoney.json                                           Fail
- static_refund_CallA.json                                        Fail
- static_refund_CallToSuicideNoStorage.json                       Fail
- static_refund_CallToSuicideTwice.json                           Fail
```
OK: 0/287 Fail: 275/287 Skip: 12/287
## stStaticFlagEnabled
```diff
- CallWithNOTZeroValueToPrecompileFromCalledContract.json         Fail
- CallWithNOTZeroValueToPrecompileFromContractInitialization.json Fail
- CallWithNOTZeroValueToPrecompileFromTransaction.json            Fail
- CallWithZeroValueToPrecompileFromCalledContract.json            Fail
- CallWithZeroValueToPrecompileFromContractInitialization.json    Fail
- CallWithZeroValueToPrecompileFromTransaction.json               Fail
- CallcodeToPrecompileFromCalledContract.json                     Fail
- CallcodeToPrecompileFromContractInitialization.json             Fail
- CallcodeToPrecompileFromTransaction.json                        Fail
- DelegatecallToPrecompileFromCalledContract.json                 Fail
- DelegatecallToPrecompileFromContractInitialization.json         Fail
- DelegatecallToPrecompileFromTransaction.json                    Fail
- StaticcallForPrecompilesIssue683.json                           Fail
```
OK: 0/13 Fail: 13/13 Skip: 0/13
## stSystemOperationsTest
```diff
- ABAcalls0.json                                                  Fail
  ABAcalls1.json                                                  Skip
  ABAcalls2.json                                                  Skip
- ABAcalls3.json                                                  Fail
- ABAcallsSuicide0.json                                           Fail
- ABAcallsSuicide1.json                                           Fail
- Call10.json                                                     Fail
  CallRecursiveBomb0.json                                         Skip
  CallRecursiveBomb0_OOG_atMaxCallDepth.json                      Skip
  CallRecursiveBomb1.json                                         Skip
  CallRecursiveBomb2.json                                         Skip
- CallRecursiveBomb3.json                                         Fail
  CallRecursiveBombLog.json                                       Skip
  CallRecursiveBombLog2.json                                      Skip
- CallToNameRegistrator0.json                                     Fail
- CallToNameRegistratorAddressTooBigLeft.json                     Fail
- CallToNameRegistratorAddressTooBigRight.json                    Fail
  CallToNameRegistratorMemOOGAndInsufficientBalance.json          Skip
- CallToNameRegistratorNotMuchMemory0.json                        Fail
- CallToNameRegistratorNotMuchMemory1.json                        Fail
- CallToNameRegistratorOutOfGas.json                              Fail
  CallToNameRegistratorTooMuchMemory0.json                        Skip
- CallToNameRegistratorTooMuchMemory1.json                        Fail
- CallToNameRegistratorTooMuchMemory2.json                        Fail
- CallToNameRegistratorZeorSizeMemExpansion.json                  Fail
- CallToReturn1.json                                              Fail
- CallToReturn1ForDynamicJump0.json                               Fail
- CallToReturn1ForDynamicJump1.json                               Fail
- CalltoReturn2.json                                              Fail
- CreateHashCollision.json                                        Fail
- PostToReturn1.json                                              Fail
- TestNameRegistrator.json                                        Fail
- balanceInputAddressTooBig.json                                  Fail
- callValue.json                                                  Fail
- callcodeTo0.json                                                Fail
- callcodeToNameRegistrator0.json                                 Fail
- callcodeToNameRegistratorAddresTooBigLeft.json                  Fail
- callcodeToNameRegistratorAddresTooBigRight.json                 Fail
- callcodeToNameRegistratorZeroMemExpanion.json                   Fail
- callcodeToReturn1.json                                          Fail
- callerAccountBalance.json                                       Fail
- createNameRegistrator.json                                      Fail
- createNameRegistratorOOG_MemExpansionOOV.json                   Fail
- createNameRegistratorOutOfMemoryBonds0.json                     Fail
- createNameRegistratorOutOfMemoryBonds1.json                     Fail
- createNameRegistratorValueTooHigh.json                          Fail
- createNameRegistratorZeroMem.json                               Fail
- createNameRegistratorZeroMem2.json                              Fail
- createNameRegistratorZeroMemExpansion.json                      Fail
- createWithInvalidOpcode.json                                    Fail
- currentAccountBalance.json                                      Fail
- doubleSelfdestructTest.json                                     Fail
- doubleSelfdestructTouch.json                                    Fail
- doubleSelfdestructTouch_Paris.json                              Fail
- extcodecopy.json                                                Fail
- multiSelfdestruct.json                                          Fail
- return0.json                                                    Fail
- return1.json                                                    Fail
- return2.json                                                    Fail
- suicideAddress.json                                             Fail
- suicideCaller.json                                              Fail
- suicideCallerAddresTooBigLeft.json                              Fail
- suicideCallerAddresTooBigRight.json                             Fail
- suicideNotExistingAccount.json                                  Fail
- suicideOrigin.json                                              Fail
- suicideSendEtherPostDeath.json                                  Fail
- suicideSendEtherToMe.json                                       Fail
- testRandomTest.json                                             Fail
```
OK: 0/68 Fail: 58/68 Skip: 10/68
## stTimeConsuming
```diff
  CALLBlake2f_MaxRounds.json                                      Skip
- sstore_combinations_initial00.json                              Fail
- sstore_combinations_initial00_2.json                            Fail
- sstore_combinations_initial00_2_Paris.json                      Fail
- sstore_combinations_initial00_Paris.json                        Fail
- sstore_combinations_initial01.json                              Fail
- sstore_combinations_initial01_2.json                            Fail
- sstore_combinations_initial01_2_Paris.json                      Fail
- sstore_combinations_initial01_Paris.json                        Fail
- sstore_combinations_initial10.json                              Fail
- sstore_combinations_initial10_2.json                            Fail
- sstore_combinations_initial10_2_Paris.json                      Fail
- sstore_combinations_initial10_Paris.json                        Fail
- sstore_combinations_initial11.json                              Fail
- sstore_combinations_initial11_2.json                            Fail
- sstore_combinations_initial11_2_Paris.json                      Fail
- sstore_combinations_initial11_Paris.json                        Fail
- sstore_combinations_initial20.json                              Fail
- sstore_combinations_initial20_2.json                            Fail
- sstore_combinations_initial20_2_Paris.json                      Fail
- sstore_combinations_initial20_Paris.json                        Fail
- sstore_combinations_initial21.json                              Fail
- sstore_combinations_initial21_2.json                            Fail
- sstore_combinations_initial21_2_Paris.json                      Fail
- sstore_combinations_initial21_Paris.json                        Fail
  static_Call50000_sha256.json                                    Skip
```
OK: 0/26 Fail: 24/26 Skip: 2/26
## stTransactionTest
```diff
- ContractStoreClearsOOG.json                                     Fail
- ContractStoreClearsSuccess.json                                 Fail
- CreateMessageReverted.json                                      Fail
- CreateMessageSuccess.json                                       Fail
- CreateTransactionSuccess.json                                   Fail
- EmptyTransaction3.json                                          Fail
- HighGasLimit.json                                               Fail
+ HighGasPrice.json                                               OK
+ HighGasPriceParis.json                                          OK
- InternalCallHittingGasLimit.json                                Fail
- InternalCallHittingGasLimit2.json                               Fail
- InternalCallHittingGasLimitSuccess.json                         Fail
- InternlCallStoreClearsOOG.json                                  Fail
- InternlCallStoreClearsSucces.json                               Fail
+ NoSrcAccount.json                                               OK
+ NoSrcAccount1559.json                                           OK
+ NoSrcAccountCreate.json                                         OK
+ NoSrcAccountCreate1559.json                                     OK
- Opcodes_TransactionInit.json                                    Fail
- OverflowGasRequire2.json                                        Fail
- PointAtInfinityECRecover.json                                   Fail
- StoreClearsAndInternlCallStoreClearsOOG.json                    Fail
- StoreClearsAndInternlCallStoreClearsSuccess.json                Fail
- StoreGasOnCreate.json                                           Fail
- SuicidesAndInternlCallSuicidesBonusGasAtCall.json               Fail
- SuicidesAndInternlCallSuicidesBonusGasAtCallFailed.json         Fail
- SuicidesAndInternlCallSuicidesOOG.json                          Fail
- SuicidesAndInternlCallSuicidesSuccess.json                      Fail
- SuicidesAndSendMoneyToItselfEtherDestroyed.json                 Fail
- SuicidesStopAfterSuicide.json                                   Fail
- TransactionDataCosts652.json                                    Fail
- TransactionSendingToEmpty.json                                  Fail
- TransactionSendingToZero.json                                   Fail
- TransactionToAddressh160minusOne.json                           Fail
- TransactionToItself.json                                        Fail
+ ValueOverflow.json                                              OK
+ ValueOverflowParis.json                                         OK
```
OK: 8/37 Fail: 29/37 Skip: 0/37
## stTransitionTest
```diff
- createNameRegistratorPerTxsAfter.json                           Fail
- createNameRegistratorPerTxsAt.json                              Fail
- createNameRegistratorPerTxsBefore.json                          Fail
- delegatecallAfterTransition.json                                Fail
- delegatecallAtTransition.json                                   Fail
- delegatecallBeforeTransition.json                               Fail
```
OK: 0/6 Fail: 6/6 Skip: 0/6
## stWalletTest
```diff
- dayLimitConstruction.json                                       Fail
- dayLimitConstructionOOG.json                                    Fail
- dayLimitConstructionPartial.json                                Fail
- dayLimitResetSpentToday.json                                    Fail
- dayLimitSetDailyLimit.json                                      Fail
- dayLimitSetDailyLimitNoData.json                                Fail
- multiOwnedAddOwner.json                                         Fail
- multiOwnedAddOwnerAddMyself.json                                Fail
- multiOwnedChangeOwner.json                                      Fail
- multiOwnedChangeOwnerNoArgument.json                            Fail
- multiOwnedChangeOwner_fromNotOwner.json                         Fail
- multiOwnedChangeOwner_toIsOwner.json                            Fail
- multiOwnedChangeRequirementTo0.json                             Fail
- multiOwnedChangeRequirementTo1.json                             Fail
- multiOwnedChangeRequirementTo2.json                             Fail
- multiOwnedConstructionCorrect.json                              Fail
- multiOwnedConstructionNotEnoughGas.json                         Fail
- multiOwnedConstructionNotEnoughGasPartial.json                  Fail
- multiOwnedIsOwnerFalse.json                                     Fail
- multiOwnedIsOwnerTrue.json                                      Fail
- multiOwnedRemoveOwner.json                                      Fail
- multiOwnedRemoveOwnerByNonOwner.json                            Fail
- multiOwnedRemoveOwner_mySelf.json                               Fail
- multiOwnedRemoveOwner_ownerIsNotOwner.json                      Fail
- multiOwnedRevokeNothing.json                                    Fail
- walletAddOwnerRemovePendingTransaction.json                     Fail
- walletChangeOwnerRemovePendingTransaction.json                  Fail
- walletChangeRequirementRemovePendingTransaction.json            Fail
- walletConfirm.json                                              Fail
- walletConstruction.json                                         Fail
- walletConstructionOOG.json                                      Fail
- walletConstructionPartial.json                                  Fail
- walletDefault.json                                              Fail
- walletDefaultWithOutValue.json                                  Fail
- walletExecuteOverDailyLimitMultiOwner.json                      Fail
- walletExecuteOverDailyLimitOnlyOneOwner.json                    Fail
- walletExecuteOverDailyLimitOnlyOneOwnerNew.json                 Fail
- walletExecuteUnderDailyLimit.json                               Fail
- walletKill.json                                                 Fail
- walletKillNotByOwner.json                                       Fail
- walletKillToWallet.json                                         Fail
- walletRemoveOwnerRemovePendingTransaction.json                  Fail
```
OK: 0/42 Fail: 42/42 Skip: 0/42
## stZeroCallsRevert
```diff
- ZeroValue_CALLCODE_OOGRevert.json                               Fail
- ZeroValue_CALLCODE_ToEmpty_OOGRevert.json                       Fail
- ZeroValue_CALLCODE_ToEmpty_OOGRevert_Paris.json                 Fail
- ZeroValue_CALLCODE_ToNonZeroBalance_OOGRevert.json              Fail
- ZeroValue_CALLCODE_ToOneStorageKey_OOGRevert.json               Fail
- ZeroValue_CALLCODE_ToOneStorageKey_OOGRevert_Paris.json         Fail
- ZeroValue_CALL_OOGRevert.json                                   Fail
- ZeroValue_CALL_ToEmpty_OOGRevert.json                           Fail
- ZeroValue_CALL_ToEmpty_OOGRevert_Paris.json                     Fail
- ZeroValue_CALL_ToNonZeroBalance_OOGRevert.json                  Fail
- ZeroValue_CALL_ToOneStorageKey_OOGRevert.json                   Fail
- ZeroValue_CALL_ToOneStorageKey_OOGRevert_Paris.json             Fail
- ZeroValue_DELEGATECALL_OOGRevert.json                           Fail
- ZeroValue_DELEGATECALL_ToEmpty_OOGRevert.json                   Fail
- ZeroValue_DELEGATECALL_ToEmpty_OOGRevert_Paris.json             Fail
- ZeroValue_DELEGATECALL_ToNonZeroBalance_OOGRevert.json          Fail
- ZeroValue_DELEGATECALL_ToOneStorageKey_OOGRevert.json           Fail
- ZeroValue_DELEGATECALL_ToOneStorageKey_OOGRevert_Paris.json     Fail
- ZeroValue_SUICIDE_OOGRevert.json                                Fail
- ZeroValue_SUICIDE_ToEmpty_OOGRevert.json                        Fail
- ZeroValue_SUICIDE_ToEmpty_OOGRevert_Paris.json                  Fail
- ZeroValue_SUICIDE_ToNonZeroBalance_OOGRevert.json               Fail
- ZeroValue_SUICIDE_ToOneStorageKey_OOGRevert.json                Fail
- ZeroValue_SUICIDE_ToOneStorageKey_OOGRevert_Paris.json          Fail
```
OK: 0/24 Fail: 24/24 Skip: 0/24
## stZeroCallsTest
```diff
- ZeroValue_CALL.json                                             Fail
- ZeroValue_CALLCODE.json                                         Fail
- ZeroValue_CALLCODE_ToEmpty.json                                 Fail
- ZeroValue_CALLCODE_ToEmpty_Paris.json                           Fail
- ZeroValue_CALLCODE_ToNonZeroBalance.json                        Fail
- ZeroValue_CALLCODE_ToOneStorageKey.json                         Fail
- ZeroValue_CALLCODE_ToOneStorageKey_Paris.json                   Fail
- ZeroValue_CALL_ToEmpty.json                                     Fail
- ZeroValue_CALL_ToEmpty_Paris.json                               Fail
- ZeroValue_CALL_ToNonZeroBalance.json                            Fail
- ZeroValue_CALL_ToOneStorageKey.json                             Fail
- ZeroValue_CALL_ToOneStorageKey_Paris.json                       Fail
- ZeroValue_DELEGATECALL.json                                     Fail
- ZeroValue_DELEGATECALL_ToEmpty.json                             Fail
- ZeroValue_DELEGATECALL_ToEmpty_Paris.json                       Fail
- ZeroValue_DELEGATECALL_ToNonZeroBalance.json                    Fail
- ZeroValue_DELEGATECALL_ToOneStorageKey.json                     Fail
- ZeroValue_DELEGATECALL_ToOneStorageKey_Paris.json               Fail
- ZeroValue_SUICIDE.json                                          Fail
- ZeroValue_SUICIDE_ToEmpty.json                                  Fail
- ZeroValue_SUICIDE_ToEmpty_Paris.json                            Fail
- ZeroValue_SUICIDE_ToNonZeroBalance.json                         Fail
- ZeroValue_SUICIDE_ToOneStorageKey.json                          Fail
- ZeroValue_SUICIDE_ToOneStorageKey_Paris.json                    Fail
- ZeroValue_TransactionCALL.json                                  Fail
- ZeroValue_TransactionCALL_ToEmpty.json                          Fail
- ZeroValue_TransactionCALL_ToEmpty_Paris.json                    Fail
- ZeroValue_TransactionCALL_ToNonZeroBalance.json                 Fail
- ZeroValue_TransactionCALL_ToOneStorageKey.json                  Fail
- ZeroValue_TransactionCALL_ToOneStorageKey_Paris.json            Fail
- ZeroValue_TransactionCALLwithData.json                          Fail
- ZeroValue_TransactionCALLwithData_ToEmpty.json                  Fail
- ZeroValue_TransactionCALLwithData_ToEmpty_Paris.json            Fail
- ZeroValue_TransactionCALLwithData_ToNonZeroBalance.json         Fail
- ZeroValue_TransactionCALLwithData_ToOneStorageKey.json          Fail
- ZeroValue_TransactionCALLwithData_ToOneStorageKey_Paris.json    Fail
```
OK: 0/36 Fail: 36/36 Skip: 0/36
## stZeroKnowledge
```diff
- ecmul_1-2_2_28000_128.json                                      Fail
- ecmul_1-2_2_28000_96.json                                       Fail
- ecmul_1-2_340282366920938463463374607431768211456_21000_128.jso Fail
- ecmul_1-2_340282366920938463463374607431768211456_21000_80.json Fail
- ecmul_1-2_340282366920938463463374607431768211456_21000_96.json Fail
- ecmul_1-2_340282366920938463463374607431768211456_28000_128.jso Fail
- ecmul_1-2_340282366920938463463374607431768211456_28000_80.json Fail
- ecmul_1-2_340282366920938463463374607431768211456_28000_96.json Fail
- ecmul_1-2_5616_21000_128.json                                   Fail
- ecmul_1-2_5616_21000_96.json                                    Fail
- ecmul_1-2_5616_28000_128.json                                   Fail
- ecmul_1-2_5617_21000_128.json                                   Fail
- ecmul_1-2_5617_21000_96.json                                    Fail
- ecmul_1-2_5617_28000_128.json                                   Fail
- ecmul_1-2_5617_28000_96.json                                    Fail
- ecmul_1-2_616_28000_96.json                                     Fail
- ecmul_1-2_9935_21000_128.json                                   Fail
- ecmul_1-2_9935_21000_96.json                                    Fail
- ecmul_1-2_9935_28000_128.json                                   Fail
- ecmul_1-2_9935_28000_96.json                                    Fail
- ecmul_1-2_9_21000_128.json                                      Fail
- ecmul_1-2_9_21000_96.json                                       Fail
- ecmul_1-2_9_28000_128.json                                      Fail
- ecmul_1-2_9_28000_96.json                                       Fail
- ecmul_1-3_0_21000_128.json                                      Fail
- ecmul_1-3_0_21000_64.json                                       Fail
- ecmul_1-3_0_21000_80.json                                       Fail
- ecmul_1-3_0_21000_96.json                                       Fail
- ecmul_1-3_0_28000_128.json                                      Fail
- ecmul_1-3_0_28000_64.json                                       Fail
- ecmul_1-3_0_28000_80.json                                       Fail
- ecmul_1-3_0_28000_80_Paris.json                                 Fail
- ecmul_1-3_0_28000_96.json                                       Fail
- ecmul_1-3_1_21000_128.json                                      Fail
- ecmul_1-3_1_21000_96.json                                       Fail
- ecmul_1-3_1_28000_128.json                                      Fail
- ecmul_1-3_1_28000_96.json                                       Fail
- ecmul_1-3_2_21000_128.json                                      Fail
- ecmul_1-3_2_21000_96.json                                       Fail
- ecmul_1-3_2_28000_128.json                                      Fail
- ecmul_1-3_2_28000_96.json                                       Fail
- ecmul_1-3_340282366920938463463374607431768211456_21000_128.jso Fail
- ecmul_1-3_340282366920938463463374607431768211456_21000_80.json Fail
- ecmul_1-3_340282366920938463463374607431768211456_21000_96.json Fail
- ecmul_1-3_340282366920938463463374607431768211456_28000_128.jso Fail
- ecmul_1-3_340282366920938463463374607431768211456_28000_80.json Fail
- ecmul_1-3_340282366920938463463374607431768211456_28000_96.json Fail
- ecmul_1-3_5616_21000_128.json                                   Fail
- ecmul_1-3_5616_21000_96.json                                    Fail
- ecmul_1-3_5616_28000_128.json                                   Fail
- ecmul_1-3_5616_28000_96.json                                    Fail
- ecmul_1-3_5617_21000_128.json                                   Fail
- ecmul_1-3_5617_21000_96.json                                    Fail
- ecmul_1-3_5617_28000_128.json                                   Fail
- ecmul_1-3_5617_28000_96.json                                    Fail
- ecmul_1-3_9935_21000_128.json                                   Fail
- ecmul_1-3_9935_21000_96.json                                    Fail
- ecmul_1-3_9935_28000_128.json                                   Fail
- ecmul_1-3_9935_28000_96.json                                    Fail
- ecmul_1-3_9_21000_128.json                                      Fail
- ecmul_1-3_9_21000_96.json                                       Fail
- ecmul_1-3_9_28000_128.json                                      Fail
- ecmul_1-3_9_28000_96.json                                       Fail
- ecmul_7827-6598_0_21000_128.json                                Fail
- ecmul_7827-6598_0_21000_64.json                                 Fail
- ecmul_7827-6598_0_21000_80.json                                 Fail
- ecmul_7827-6598_0_21000_96.json                                 Fail
- ecmul_7827-6598_0_28000_128.json                                Fail
- ecmul_7827-6598_0_28000_64.json                                 Fail
- ecmul_7827-6598_0_28000_80.json                                 Fail
- ecmul_7827-6598_0_28000_96.json                                 Fail
- ecmul_7827-6598_1456_21000_128.json                             Fail
- ecmul_7827-6598_1456_21000_80.json                              Fail
- ecmul_7827-6598_1456_21000_96.json                              Fail
- ecmul_7827-6598_1456_28000_128.json                             Fail
- ecmul_7827-6598_1456_28000_80.json                              Fail
- ecmul_7827-6598_1456_28000_96.json                              Fail
- ecmul_7827-6598_1_21000_128.json                                Fail
- ecmul_7827-6598_1_21000_96.json                                 Fail
- ecmul_7827-6598_1_28000_128.json                                Fail
- ecmul_7827-6598_1_28000_96.json                                 Fail
- ecmul_7827-6598_2_21000_128.json                                Fail
- ecmul_7827-6598_2_21000_96.json                                 Fail
- ecmul_7827-6598_2_28000_128.json                                Fail
- ecmul_7827-6598_2_28000_96.json                                 Fail
- ecmul_7827-6598_5616_21000_128.json                             Fail
- ecmul_7827-6598_5616_21000_96.json                              Fail
- ecmul_7827-6598_5616_28000_128.json                             Fail
- ecmul_7827-6598_5616_28000_96.json                              Fail
- ecmul_7827-6598_5617_21000_128.json                             Fail
- ecmul_7827-6598_5617_21000_96.json                              Fail
- ecmul_7827-6598_5617_28000_128.json                             Fail
- ecmul_7827-6598_5617_28000_96.json                              Fail
- ecmul_7827-6598_9935_21000_128.json                             Fail
- ecmul_7827-6598_9935_21000_96.json                              Fail
- ecmul_7827-6598_9935_28000_128.json                             Fail
- ecmul_7827-6598_9935_28000_96.json                              Fail
- ecmul_7827-6598_9_21000_128.json                                Fail
- ecmul_7827-6598_9_21000_96.json                                 Fail
- ecmul_7827-6598_9_28000_128.json                                Fail
- ecmul_7827-6598_9_28000_96.json                                 Fail
- ecpairing_bad_length_191.json                                   Fail
- ecpairing_bad_length_193.json                                   Fail
- ecpairing_empty_data.json                                       Fail
- ecpairing_empty_data_insufficient_gas.json                      Fail
- ecpairing_inputs.json                                           Fail
- ecpairing_one_point_fail.json                                   Fail
- ecpairing_one_point_insufficient_gas.json                       Fail
- ecpairing_one_point_not_in_subgroup.json                        Fail
- ecpairing_one_point_with_g1_zero.json                           Fail
- ecpairing_one_point_with_g2_zero.json                           Fail
- ecpairing_one_point_with_g2_zero_and_g1_invalid.json            Fail
- ecpairing_perturb_g2_by_curve_order.json                        Fail
- ecpairing_perturb_g2_by_field_modulus.json                      Fail
- ecpairing_perturb_g2_by_field_modulus_again.json                Fail
- ecpairing_perturb_g2_by_one.json                                Fail
- ecpairing_perturb_zeropoint_by_curve_order.json                 Fail
- ecpairing_perturb_zeropoint_by_field_modulus.json               Fail
- ecpairing_perturb_zeropoint_by_one.json                         Fail
- ecpairing_three_point_fail_1.json                               Fail
- ecpairing_three_point_match_1.json                              Fail
- ecpairing_two_point_fail_1.json                                 Fail
- ecpairing_two_point_fail_2.json                                 Fail
- ecpairing_two_point_match_1.json                                Fail
- ecpairing_two_point_match_2.json                                Fail
- ecpairing_two_point_match_3.json                                Fail
- ecpairing_two_point_match_4.json                                Fail
- ecpairing_two_point_match_5.json                                Fail
- ecpairing_two_point_oog.json                                    Fail
- ecpairing_two_points_with_one_g2_zero.json                      Fail
- pairingTest.json                                                Fail
- pointAdd.json                                                   Fail
- pointAddTrunc.json                                              Fail
- pointMulAdd.json                                                Fail
- pointMulAdd2.json                                               Fail
```
OK: 0/135 Fail: 135/135 Skip: 0/135
## stZeroKnowledge2
```diff
- ecadd_0-0_0-0_21000_0.json                                      Fail
- ecadd_0-0_0-0_21000_128.json                                    Fail
- ecadd_0-0_0-0_21000_192.json                                    Fail
- ecadd_0-0_0-0_21000_64.json                                     Fail
- ecadd_0-0_0-0_21000_80.json                                     Fail
- ecadd_0-0_0-0_21000_80_Paris.json                               Fail
- ecadd_0-0_0-0_25000_0.json                                      Fail
- ecadd_0-0_0-0_25000_128.json                                    Fail
- ecadd_0-0_0-0_25000_192.json                                    Fail
- ecadd_0-0_0-0_25000_64.json                                     Fail
- ecadd_0-0_0-0_25000_80.json                                     Fail
- ecadd_0-0_1-2_21000_128.json                                    Fail
- ecadd_0-0_1-2_21000_192.json                                    Fail
- ecadd_0-0_1-2_25000_128.json                                    Fail
- ecadd_0-0_1-2_25000_192.json                                    Fail
- ecadd_0-0_1-3_21000_128.json                                    Fail
- ecadd_0-0_1-3_25000_128.json                                    Fail
- ecadd_0-3_1-2_21000_128.json                                    Fail
- ecadd_0-3_1-2_25000_128.json                                    Fail
- ecadd_1-2_0-0_21000_128.json                                    Fail
- ecadd_1-2_0-0_21000_192.json                                    Fail
- ecadd_1-2_0-0_21000_64.json                                     Fail
- ecadd_1-2_0-0_25000_128.json                                    Fail
- ecadd_1-2_0-0_25000_192.json                                    Fail
- ecadd_1-2_0-0_25000_64.json                                     Fail
- ecadd_1-2_1-2_21000_128.json                                    Fail
- ecadd_1-2_1-2_21000_192.json                                    Fail
- ecadd_1-2_1-2_25000_128.json                                    Fail
- ecadd_1-2_1-2_25000_192.json                                    Fail
- ecadd_1-3_0-0_21000_80.json                                     Fail
- ecadd_1-3_0-0_25000_80.json                                     Fail
- ecadd_1-3_0-0_25000_80_Paris.json                               Fail
- ecadd_1145-3932_1145-4651_21000_192.json                        Fail
- ecadd_1145-3932_1145-4651_25000_192.json                        Fail
- ecadd_1145-3932_2969-1336_21000_128.json                        Fail
- ecadd_1145-3932_2969-1336_25000_128.json                        Fail
- ecadd_6-9_19274124-124124_21000_128.json                        Fail
- ecadd_6-9_19274124-124124_25000_128.json                        Fail
- ecmul_0-0_0_21000_0.json                                        Fail
- ecmul_0-0_0_21000_128.json                                      Fail
- ecmul_0-0_0_21000_40.json                                       Fail
- ecmul_0-0_0_21000_64.json                                       Fail
- ecmul_0-0_0_21000_80.json                                       Fail
- ecmul_0-0_0_21000_96.json                                       Fail
- ecmul_0-0_0_28000_0.json                                        Fail
- ecmul_0-0_0_28000_128.json                                      Fail
- ecmul_0-0_0_28000_40.json                                       Fail
- ecmul_0-0_0_28000_64.json                                       Fail
- ecmul_0-0_0_28000_80.json                                       Fail
- ecmul_0-0_0_28000_96.json                                       Fail
- ecmul_0-0_1_21000_128.json                                      Fail
- ecmul_0-0_1_21000_96.json                                       Fail
- ecmul_0-0_1_28000_128.json                                      Fail
- ecmul_0-0_1_28000_96.json                                       Fail
- ecmul_0-0_2_21000_128.json                                      Fail
- ecmul_0-0_2_21000_96.json                                       Fail
- ecmul_0-0_2_28000_128.json                                      Fail
- ecmul_0-0_2_28000_96.json                                       Fail
- ecmul_0-0_340282366920938463463374607431768211456_21000_128.jso Fail
- ecmul_0-0_340282366920938463463374607431768211456_21000_80.json Fail
- ecmul_0-0_340282366920938463463374607431768211456_21000_96.json Fail
- ecmul_0-0_340282366920938463463374607431768211456_28000_128.jso Fail
- ecmul_0-0_340282366920938463463374607431768211456_28000_80.json Fail
- ecmul_0-0_340282366920938463463374607431768211456_28000_96.json Fail
- ecmul_0-0_5616_21000_128.json                                   Fail
- ecmul_0-0_5616_21000_96.json                                    Fail
- ecmul_0-0_5616_28000_128.json                                   Fail
- ecmul_0-0_5616_28000_96.json                                    Fail
- ecmul_0-0_5617_21000_128.json                                   Fail
- ecmul_0-0_5617_21000_96.json                                    Fail
- ecmul_0-0_5617_28000_128.json                                   Fail
- ecmul_0-0_5617_28000_96.json                                    Fail
- ecmul_0-0_9935_21000_128.json                                   Fail
- ecmul_0-0_9935_21000_96.json                                    Fail
- ecmul_0-0_9935_28000_128.json                                   Fail
- ecmul_0-0_9935_28000_96.json                                    Fail
- ecmul_0-0_9_21000_128.json                                      Fail
- ecmul_0-0_9_21000_96.json                                       Fail
- ecmul_0-0_9_28000_128.json                                      Fail
- ecmul_0-0_9_28000_96.json                                       Fail
- ecmul_0-3_0_21000_128.json                                      Fail
- ecmul_0-3_0_21000_64.json                                       Fail
- ecmul_0-3_0_21000_80.json                                       Fail
- ecmul_0-3_0_21000_96.json                                       Fail
- ecmul_0-3_0_28000_128.json                                      Fail
- ecmul_0-3_0_28000_64.json                                       Fail
- ecmul_0-3_0_28000_80.json                                       Fail
- ecmul_0-3_0_28000_96.json                                       Fail
- ecmul_0-3_1_21000_128.json                                      Fail
- ecmul_0-3_1_21000_96.json                                       Fail
- ecmul_0-3_1_28000_128.json                                      Fail
- ecmul_0-3_1_28000_96.json                                       Fail
- ecmul_0-3_2_21000_128.json                                      Fail
- ecmul_0-3_2_21000_96.json                                       Fail
- ecmul_0-3_2_28000_128.json                                      Fail
- ecmul_0-3_2_28000_96.json                                       Fail
- ecmul_0-3_340282366920938463463374607431768211456_21000_128.jso Fail
- ecmul_0-3_340282366920938463463374607431768211456_21000_80.json Fail
- ecmul_0-3_340282366920938463463374607431768211456_21000_96.json Fail
- ecmul_0-3_340282366920938463463374607431768211456_28000_128.jso Fail
- ecmul_0-3_340282366920938463463374607431768211456_28000_80.json Fail
- ecmul_0-3_340282366920938463463374607431768211456_28000_96.json Fail
- ecmul_0-3_5616_21000_128.json                                   Fail
- ecmul_0-3_5616_21000_96.json                                    Fail
- ecmul_0-3_5616_28000_128.json                                   Fail
- ecmul_0-3_5616_28000_96.json                                    Fail
- ecmul_0-3_5616_28000_96_Paris.json                              Fail
- ecmul_0-3_5617_21000_128.json                                   Fail
- ecmul_0-3_5617_21000_96.json                                    Fail
- ecmul_0-3_5617_28000_128.json                                   Fail
- ecmul_0-3_5617_28000_96.json                                    Fail
- ecmul_0-3_9935_21000_128.json                                   Fail
- ecmul_0-3_9935_21000_96.json                                    Fail
- ecmul_0-3_9935_28000_128.json                                   Fail
- ecmul_0-3_9935_28000_96.json                                    Fail
- ecmul_0-3_9_21000_128.json                                      Fail
- ecmul_0-3_9_21000_96.json                                       Fail
- ecmul_0-3_9_28000_128.json                                      Fail
- ecmul_0-3_9_28000_96.json                                       Fail
- ecmul_1-2_0_21000_128.json                                      Fail
- ecmul_1-2_0_21000_64.json                                       Fail
- ecmul_1-2_0_21000_80.json                                       Fail
- ecmul_1-2_0_21000_96.json                                       Fail
- ecmul_1-2_0_28000_128.json                                      Fail
- ecmul_1-2_0_28000_64.json                                       Fail
- ecmul_1-2_0_28000_80.json                                       Fail
- ecmul_1-2_0_28000_96.json                                       Fail
- ecmul_1-2_1_21000_128.json                                      Fail
- ecmul_1-2_1_21000_96.json                                       Fail
- ecmul_1-2_1_28000_128.json                                      Fail
- ecmul_1-2_1_28000_96.json                                       Fail
- ecmul_1-2_2_21000_128.json                                      Fail
- ecmul_1-2_2_21000_96.json                                       Fail
```
OK: 0/133 Fail: 133/133 Skip: 0/133
## vmArithmeticTest
```diff
- add.json                                                        Fail
- addmod.json                                                     Fail
- arith.json                                                      Fail
- div.json                                                        Fail
- divByZero.json                                                  Fail
- exp.json                                                        Fail
- expPower2.json                                                  Fail
- expPower256.json                                                Fail
- expPower256Of256.json                                           Fail
- fib.json                                                        Fail
- mod.json                                                        Fail
- mul.json                                                        Fail
- mulmod.json                                                     Fail
- not.json                                                        Fail
- sdiv.json                                                       Fail
- signextend.json                                                 Fail
- smod.json                                                       Fail
- sub.json                                                        Fail
- twoOps.json                                                     Fail
```
OK: 0/19 Fail: 19/19 Skip: 0/19
## vmBitwiseLogicOperation
```diff
- and.json                                                        Fail
- byte.json                                                       Fail
- eq.json                                                         Fail
- gt.json                                                         Fail
- iszero.json                                                     Fail
- lt.json                                                         Fail
- not.json                                                        Fail
- or.json                                                         Fail
- sgt.json                                                        Fail
- slt.json                                                        Fail
- xor.json                                                        Fail
```
OK: 0/11 Fail: 11/11 Skip: 0/11
## vmIOandFlowOperations
```diff
- codecopy.json                                                   Fail
- gas.json                                                        Fail
- jump.json                                                       Fail
- jumpToPush.json                                                 Fail
- jumpi.json                                                      Fail
- loop_stacklimit.json                                            Fail
- loopsConditionals.json                                          Fail
- mload.json                                                      Fail
- msize.json                                                      Fail
- mstore.json                                                     Fail
- mstore8.json                                                    Fail
- pc.json                                                         Fail
- pop.json                                                        Fail
- return.json                                                     Fail
- sstore_sload.json                                               Fail
```
OK: 0/15 Fail: 15/15 Skip: 0/15
## vmLogTest
```diff
- log0.json                                                       Fail
- log1.json                                                       Fail
- log2.json                                                       Fail
- log3.json                                                       Fail
- log4.json                                                       Fail
```
OK: 0/5 Fail: 5/5 Skip: 0/5
## vmPerformance
```diff
  loopExp.json                                                    Skip
  loopMul.json                                                    Skip
  performanceTester.json                                          Skip
```
OK: 0/3 Fail: 0/3 Skip: 3/3
## vmTests
```diff
- blockInfo.json                                                  Fail
- calldatacopy.json                                               Fail
- calldataload.json                                               Fail
- calldatasize.json                                               Fail
- dup.json                                                        Fail
- envInfo.json                                                    Fail
- push.json                                                       Fail
- random.json                                                     Fail
- sha3.json                                                       Fail
- suicide.json                                                    Fail
- swap.json                                                       Fail
```
OK: 0/11 Fail: 11/11 Skip: 0/11
## yul
```diff
- yul.json                                                        Fail
```
OK: 0/1 Fail: 1/1 Skip: 0/1

---TOTAL---
OK: 197/3272 Fail: 2970/3272 Skip: 105/3272
