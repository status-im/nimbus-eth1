GeneralStateTests
===
## stArgsZeroOneBalance
```diff
  addNonConst.json                                                Skip
  addmodNonConst.json                                             Skip
  andNonConst.json                                                Skip
  balanceNonConst.json                                            Skip
  byteNonConst.json                                               Skip
  callNonConst.json                                               Skip
  callcodeNonConst.json                                           Skip
  calldatacopyNonConst.json                                       Skip
  calldataloadNonConst.json                                       Skip
  codecopyNonConst.json                                           Skip
  createNonConst.json                                             Skip
  delegatecallNonConst.json                                       Skip
  divNonConst.json                                                Skip
  eqNonConst.json                                                 Skip
  expNonConst.json                                                Skip
  extcodecopyNonConst.json                                        Skip
  extcodesizeNonConst.json                                        Skip
  gtNonConst.json                                                 Skip
  iszeroNonConst.json                                             Skip
  jumpNonConst.json                                               Skip
  jumpiNonConst.json                                              Skip
  log0NonConst.json                                               Skip
  log1NonConst.json                                               Skip
  log2NonConst.json                                               Skip
  log3NonConst.json                                               Skip
  ltNonConst.json                                                 Skip
  mloadNonConst.json                                              Skip
  modNonConst.json                                                Skip
  mstore8NonConst.json                                            Skip
  mstoreNonConst.json                                             Skip
  mulNonConst.json                                                Skip
  mulmodNonConst.json                                             Skip
  notNonConst.json                                                Skip
  orNonConst.json                                                 Skip
  returnNonConst.json                                             Skip
  sdivNonConst.json                                               Skip
  sgtNonConst.json                                                Skip
  sha3NonConst.json                                               Skip
  signextNonConst.json                                            Skip
  sloadNonConst.json                                              Skip
  sltNonConst.json                                                Skip
  smodNonConst.json                                               Skip
  sstoreNonConst.json                                             Skip
  subNonConst.json                                                Skip
  suicideNonConst.json                                            Skip
  xorNonConst.json                                                Skip
```
OK: 0/46 Fail: 0/46 Skip: 46/46
## stAttackTest
```diff
  ContractCreationSpam.json                                       Skip
+ CrashingTransaction.json                                        OK
```
OK: 1/2 Fail: 0/2 Skip: 1/2
## stBadOpcode
```diff
+ badOpcodes.json                                                 OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## stBugs
```diff
+ evmBytecode.json                                                OK
+ returndatacopyPythonBug_Tue_03_48_41-1432.json                  OK
  staticcall_createfails.json                                     Skip
```
OK: 2/3 Fail: 0/3 Skip: 1/3
## stCallCodes
```diff
+ call_OOG_additionalGasCosts1.json                               OK
+ call_OOG_additionalGasCosts2.json                               OK
+ callcall_00.json                                                OK
  callcall_00_OOGE.json                                           Skip
  callcall_00_OOGE_valueTransfer.json                             Skip
  callcall_00_SuicideEnd.json                                     Skip
  callcallcall_000.json                                           Skip
  callcallcall_000_OOGE.json                                      Skip
  callcallcall_000_OOGMAfter.json                                 Skip
  callcallcall_000_OOGMBefore.json                                Skip
  callcallcall_000_SuicideEnd.json                                Skip
  callcallcall_000_SuicideMiddle.json                             Skip
  callcallcall_ABCB_RECURSIVE.json                                Skip
  callcallcallcode_001.json                                       Skip
  callcallcallcode_001_OOGE.json                                  Skip
  callcallcallcode_001_OOGMAfter.json                             Skip
  callcallcallcode_001_OOGMBefore.json                            Skip
  callcallcallcode_001_SuicideEnd.json                            Skip
  callcallcallcode_001_SuicideMiddle.json                         Skip
  callcallcallcode_ABCB_RECURSIVE.json                            Skip
  callcallcode_01.json                                            Skip
  callcallcode_01_OOGE.json                                       Skip
  callcallcode_01_SuicideEnd.json                                 Skip
  callcallcodecall_010.json                                       Skip
  callcallcodecall_010_OOGE.json                                  Skip
  callcallcodecall_010_OOGMAfter.json                             Skip
  callcallcodecall_010_OOGMBefore.json                            Skip
  callcallcodecall_010_SuicideEnd.json                            Skip
  callcallcodecall_010_SuicideMiddle.json                         Skip
  callcallcodecall_ABCB_RECURSIVE.json                            Skip
  callcallcodecallcode_011.json                                   Skip
  callcallcodecallcode_011_OOGE.json                              Skip
  callcallcodecallcode_011_OOGMAfter.json                         Skip
  callcallcodecallcode_011_OOGMBefore.json                        Skip
  callcallcodecallcode_011_SuicideEnd.json                        Skip
  callcallcodecallcode_011_SuicideMiddle.json                     Skip
  callcallcodecallcode_ABCB_RECURSIVE.json                        Skip
  callcodeDynamicCode.json                                        Skip
  callcodeDynamicCode2SelfCall.json                               Skip
  callcodeEmptycontract.json                                      Skip
  callcodeInInitcodeToEmptyContract.json                          Skip
  callcodeInInitcodeToExisContractWithVTransferNEMoney.json       Skip
  callcodeInInitcodeToExistingContract.json                       Skip
  callcodeInInitcodeToExistingContractWithValueTransfer.json      Skip
+ callcode_checkPC.json                                           OK
  callcodecall_10.json                                            Skip
  callcodecall_10_OOGE.json                                       Skip
  callcodecall_10_SuicideEnd.json                                 Skip
  callcodecallcall_100.json                                       Skip
  callcodecallcall_100_OOGE.json                                  Skip
  callcodecallcall_100_OOGMAfter.json                             Skip
  callcodecallcall_100_OOGMBefore.json                            Skip
  callcodecallcall_100_SuicideEnd.json                            Skip
  callcodecallcall_100_SuicideMiddle.json                         Skip
  callcodecallcall_ABCB_RECURSIVE.json                            Skip
  callcodecallcallcode_101.json                                   Skip
  callcodecallcallcode_101_OOGE.json                              Skip
  callcodecallcallcode_101_OOGMAfter.json                         Skip
  callcodecallcallcode_101_OOGMBefore.json                        Skip
  callcodecallcallcode_101_SuicideEnd.json                        Skip
  callcodecallcallcode_101_SuicideMiddle.json                     Skip
  callcodecallcallcode_ABCB_RECURSIVE.json                        Skip
  callcodecallcode_11.json                                        Skip
+ callcodecallcode_11_OOGE.json                                   OK
  callcodecallcode_11_SuicideEnd.json                             Skip
  callcodecallcodecall_110.json                                   Skip
  callcodecallcodecall_110_OOGE.json                              Skip
  callcodecallcodecall_110_OOGMAfter.json                         Skip
  callcodecallcodecall_110_OOGMBefore.json                        Skip
  callcodecallcodecall_110_SuicideEnd.json                        Skip
  callcodecallcodecall_110_SuicideMiddle.json                     Skip
  callcodecallcodecall_ABCB_RECURSIVE.json                        Skip
  callcodecallcodecallcode_111.json                               Skip
  callcodecallcodecallcode_111_OOGE.json                          Skip
  callcodecallcodecallcode_111_OOGMAfter.json                     Skip
  callcodecallcodecallcode_111_OOGMBefore.json                    Skip
  callcodecallcodecallcode_111_SuicideEnd.json                    Skip
  callcodecallcodecallcode_111_SuicideMiddle.json                 Skip
  callcodecallcodecallcode_ABCB_RECURSIVE.json                    Skip
```
OK: 5/79 Fail: 0/79 Skip: 74/79
## stCallCreateCallCodeTest
```diff
  Call1024BalanceTooLow.json                                      Skip
  Call1024OOG.json                                                Skip
  Call1024PreCalls.json                                           Skip
  CallLoseGasOOG.json                                             Skip
  CallRecursiveBombPreCall.json                                   Skip
  Callcode1024BalanceTooLow.json                                  Skip
  Callcode1024OOG.json                                            Skip
  CallcodeLoseGasOOG.json                                         Skip
  callOutput1.json                                                Skip
  callOutput2.json                                                Skip
  callOutput3.json                                                Skip
  callOutput3Fail.json                                            Skip
  callOutput3partial.json                                         Skip
  callOutput3partialFail.json                                     Skip
  callWithHighValue.json                                          Skip
  callWithHighValueAndGasOOG.json                                 Skip
  callWithHighValueAndOOGatTxLevel.json                           Skip
  callWithHighValueOOGinCall.json                                 Skip
  callcodeOutput1.json                                            Skip
  callcodeOutput2.json                                            Skip
  callcodeOutput3.json                                            Skip
  callcodeOutput3Fail.json                                        Skip
  callcodeOutput3partial.json                                     Skip
  callcodeOutput3partialFail.json                                 Skip
  callcodeWithHighValue.json                                      Skip
  callcodeWithHighValueAndGasOOG.json                             Skip
  createFailBalanceTooLow.json                                    Skip
  createInitFailBadJumpDestination.json                           Skip
  createInitFailStackSizeLargerThan1024.json                      Skip
  createInitFailStackUnderflow.json                               Skip
  createInitFailUndefinedInstruction.json                         Skip
  createInitFail_OOGduringInit.json                               Skip
  createInitOOGforCREATE.json                                     Skip
  createJS_ExampleContract.json                                   Skip
  createJS_NoCollision.json                                       Skip
  createNameRegistratorPerTxs.json                                Skip
  createNameRegistratorPerTxsNotEnoughGas.json                    Skip
  createNameRegistratorPreStore1NotEnoughGas.json                 Skip
  createNameRegistratorendowmentTooHigh.json                      Skip
```
OK: 0/39 Fail: 0/39 Skip: 39/39
## stCallDelegateCodesCallCodeHomestead
```diff
  callcallcallcode_001.json                                       Skip
+ callcallcallcode_001_OOGE.json                                  OK
+ callcallcallcode_001_OOGMAfter.json                             OK
  callcallcallcode_001_OOGMBefore.json                            Skip
  callcallcallcode_001_SuicideEnd.json                            Skip
  callcallcallcode_001_SuicideMiddle.json                         Skip
+ callcallcallcode_ABCB_RECURSIVE.json                            OK
  callcallcode_01.json                                            Skip
  callcallcode_01_OOGE.json                                       Skip
  callcallcode_01_SuicideEnd.json                                 Skip
  callcallcodecall_010.json                                       Skip
  callcallcodecall_010_OOGE.json                                  Skip
+ callcallcodecall_010_OOGMAfter.json                             OK
  callcallcodecall_010_OOGMBefore.json                            Skip
  callcallcodecall_010_SuicideEnd.json                            Skip
  callcallcodecall_010_SuicideMiddle.json                         Skip
+ callcallcodecall_ABCB_RECURSIVE.json                            OK
  callcallcodecallcode_011.json                                   Skip
  callcallcodecallcode_011_OOGE.json                              Skip
  callcallcodecallcode_011_OOGMAfter.json                         Skip
  callcallcodecallcode_011_OOGMBefore.json                        Skip
  callcallcodecallcode_011_SuicideEnd.json                        Skip
  callcallcodecallcode_011_SuicideMiddle.json                     Skip
+ callcallcodecallcode_ABCB_RECURSIVE.json                        OK
  callcodecall_10.json                                            Skip
  callcodecall_10_OOGE.json                                       Skip
  callcodecall_10_SuicideEnd.json                                 Skip
  callcodecallcall_100.json                                       Skip
  callcodecallcall_100_OOGE.json                                  Skip
+ callcodecallcall_100_OOGMAfter.json                             OK
  callcodecallcall_100_OOGMBefore.json                            Skip
  callcodecallcall_100_SuicideEnd.json                            Skip
  callcodecallcall_100_SuicideMiddle.json                         Skip
+ callcodecallcall_ABCB_RECURSIVE.json                            OK
  callcodecallcallcode_101.json                                   Skip
  callcodecallcallcode_101_OOGE.json                              Skip
+ callcodecallcallcode_101_OOGMAfter.json                         OK
  callcodecallcallcode_101_OOGMBefore.json                        Skip
  callcodecallcallcode_101_SuicideEnd.json                        Skip
  callcodecallcallcode_101_SuicideMiddle.json                     Skip
+ callcodecallcallcode_ABCB_RECURSIVE.json                        OK
  callcodecallcode_11.json                                        Skip
  callcodecallcode_11_OOGE.json                                   Skip
  callcodecallcode_11_SuicideEnd.json                             Skip
  callcodecallcodecall_110.json                                   Skip
  callcodecallcodecall_110_OOGE.json                              Skip
+ callcodecallcodecall_110_OOGMAfter.json                         OK
  callcodecallcodecall_110_OOGMBefore.json                        Skip
  callcodecallcodecall_110_SuicideEnd.json                        Skip
  callcodecallcodecall_110_SuicideMiddle.json                     Skip
+ callcodecallcodecall_ABCB_RECURSIVE.json                        OK
  callcodecallcodecallcode_111.json                               Skip
  callcodecallcodecallcode_111_OOGE.json                          Skip
+ callcodecallcodecallcode_111_OOGMAfter.json                     OK
  callcodecallcodecallcode_111_OOGMBefore.json                    Skip
  callcodecallcodecallcode_111_SuicideEnd.json                    Skip
  callcodecallcodecallcode_111_SuicideMiddle.json                 Skip
+ callcodecallcodecallcode_ABCB_RECURSIVE.json                    OK
```
OK: 14/58 Fail: 0/58 Skip: 44/58
## stCallDelegateCodesHomestead
```diff
  callcallcallcode_001.json                                       Skip
+ callcallcallcode_001_OOGE.json                                  OK
+ callcallcallcode_001_OOGMAfter.json                             OK
+ callcallcallcode_001_OOGMBefore.json                            OK
+ callcallcallcode_001_SuicideEnd.json                            OK
+ callcallcallcode_001_SuicideMiddle.json                         OK
+ callcallcallcode_ABCB_RECURSIVE.json                            OK
  callcallcode_01.json                                            Skip
+ callcallcode_01_OOGE.json                                       OK
+ callcallcode_01_SuicideEnd.json                                 OK
  callcallcodecall_010.json                                       Skip
+ callcallcodecall_010_OOGE.json                                  OK
+ callcallcodecall_010_OOGMAfter.json                             OK
+ callcallcodecall_010_OOGMBefore.json                            OK
+ callcallcodecall_010_SuicideEnd.json                            OK
+ callcallcodecall_010_SuicideMiddle.json                         OK
+ callcallcodecall_ABCB_RECURSIVE.json                            OK
  callcallcodecallcode_011.json                                   Skip
+ callcallcodecallcode_011_OOGE.json                              OK
+ callcallcodecallcode_011_OOGMAfter.json                         OK
+ callcallcodecallcode_011_OOGMBefore.json                        OK
+ callcallcodecallcode_011_SuicideEnd.json                        OK
+ callcallcodecallcode_011_SuicideMiddle.json                     OK
+ callcallcodecallcode_ABCB_RECURSIVE.json                        OK
+ callcodecall_10.json                                            OK
+ callcodecall_10_OOGE.json                                       OK
+ callcodecall_10_SuicideEnd.json                                 OK
  callcodecallcall_100.json                                       Skip
+ callcodecallcall_100_OOGE.json                                  OK
+ callcodecallcall_100_OOGMAfter.json                             OK
+ callcodecallcall_100_OOGMBefore.json                            OK
+ callcodecallcall_100_SuicideEnd.json                            OK
+ callcodecallcall_100_SuicideMiddle.json                         OK
+ callcodecallcall_ABCB_RECURSIVE.json                            OK
  callcodecallcallcode_101.json                                   Skip
+ callcodecallcallcode_101_OOGE.json                              OK
+ callcodecallcallcode_101_OOGMAfter.json                         OK
+ callcodecallcallcode_101_OOGMBefore.json                        OK
+ callcodecallcallcode_101_SuicideEnd.json                        OK
+ callcodecallcallcode_101_SuicideMiddle.json                     OK
+ callcodecallcallcode_ABCB_RECURSIVE.json                        OK
  callcodecallcode_11.json                                        Skip
+ callcodecallcode_11_OOGE.json                                   OK
+ callcodecallcode_11_SuicideEnd.json                             OK
  callcodecallcodecall_110.json                                   Skip
+ callcodecallcodecall_110_OOGE.json                              OK
+ callcodecallcodecall_110_OOGMAfter.json                         OK
+ callcodecallcodecall_110_OOGMBefore.json                        OK
+ callcodecallcodecall_110_SuicideEnd.json                        OK
+ callcodecallcodecall_110_SuicideMiddle.json                     OK
+ callcodecallcodecall_ABCB_RECURSIVE.json                        OK
  callcodecallcodecallcode_111.json                               Skip
+ callcodecallcodecallcode_111_OOGE.json                          OK
+ callcodecallcodecallcode_111_OOGMAfter.json                     OK
+ callcodecallcodecallcode_111_OOGMBefore.json                    OK
+ callcodecallcodecallcode_111_SuicideEnd.json                    OK
+ callcodecallcodecallcode_111_SuicideMiddle.json                 OK
+ callcodecallcodecallcode_ABCB_RECURSIVE.json                    OK
```
OK: 49/58 Fail: 0/58 Skip: 9/58
## stChangedEIP150
```diff
  Call1024BalanceTooLow.json                                      Skip
  Call1024PreCalls.json                                           Skip
+ Callcode1024BalanceTooLow.json                                  OK
+ callcall_00_OOGE_1.json                                         OK
+ callcall_00_OOGE_2.json                                         OK
+ callcall_00_OOGE_valueTransfer.json                             OK
+ callcallcall_000_OOGMAfter.json                                 OK
+ callcallcallcode_001_OOGMAfter_1.json                           OK
+ callcallcallcode_001_OOGMAfter_2.json                           OK
+ callcallcallcode_001_OOGMAfter_3.json                           OK
+ callcallcodecall_010_OOGMAfter_1.json                           OK
+ callcallcodecall_010_OOGMAfter_2.json                           OK
+ callcallcodecall_010_OOGMAfter_3.json                           OK
+ callcallcodecallcode_011_OOGMAfter_1.json                       OK
+ callcallcodecallcode_011_OOGMAfter_2.json                       OK
  callcodecallcall_100_OOGMAfter_1.json                           Skip
+ callcodecallcall_100_OOGMAfter_2.json                           OK
+ callcodecallcall_100_OOGMAfter_3.json                           OK
+ callcodecallcallcode_101_OOGMAfter_1.json                       OK
+ callcodecallcallcode_101_OOGMAfter_2.json                       OK
+ callcodecallcallcode_101_OOGMAfter_3.json                       OK
+ callcodecallcodecall_110_OOGMAfter_1.json                       OK
+ callcodecallcodecall_110_OOGMAfter_2.json                       OK
+ callcodecallcodecall_110_OOGMAfter_3.json                       OK
+ callcodecallcodecallcode_111_OOGMAfter.json                     OK
+ callcodecallcodecallcode_111_OOGMAfter_1.json                   OK
+ callcodecallcodecallcode_111_OOGMAfter_2.json                   OK
+ callcodecallcodecallcode_111_OOGMAfter_3.json                   OK
+ contractCreationMakeCallThatAskMoreGasThenTransactionProvided.jsonOK
+ createInitFail_OOGduringInit.json                               OK
```
OK: 27/30 Fail: 0/30 Skip: 3/30
## stCodeCopyTest
```diff
+ ExtCodeCopyTests.json                                           OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## stCodeSizeLimit
```diff
+ codesizeInit.json                                               OK
+ codesizeOOGInvalidSize.json                                     OK
+ codesizeValid.json                                              OK
```
OK: 3/3 Fail: 0/3 Skip: 0/3
## stCreateTest
```diff
+ CREATE_AcreateB_BSuicide_BStore.json                            OK
  CREATE_ContractRETURNBigOffset.json                             Skip
+ CREATE_ContractSSTOREDuringInit.json                            OK
+ CREATE_ContractSuicideDuringInit.json                           OK
+ CREATE_ContractSuicideDuringInit_ThenStoreThenReturn.json       OK
+ CREATE_ContractSuicideDuringInit_WithValue.json                 OK
+ CREATE_ContractSuicideDuringInit_WithValueToItself.json         OK
  CREATE_EContractCreateEContractInInit_Tr.json                   Skip
+ CREATE_EContractCreateNEContractInInitOOG_Tr.json               OK
+ CREATE_EContractCreateNEContractInInit_Tr.json                  OK
  CREATE_EContract_ThenCALLToNonExistentAcc.json                  Skip
  CREATE_EmptyContract.json                                       Skip
  CREATE_EmptyContractAndCallIt_0wei.json                         Skip
  CREATE_EmptyContractAndCallIt_1wei.json                         Skip
  CREATE_EmptyContractWithBalance.json                            Skip
+ CREATE_EmptyContractWithStorage.json                            OK
+ CREATE_EmptyContractWithStorageAndCallIt_0wei.json              OK
+ CREATE_EmptyContractWithStorageAndCallIt_1wei.json              OK
+ CREATE_empty000CreateinInitCode_Transaction.json                OK
+ CreateCollisionToEmpty.json                                     OK
  CreateOOGafterInitCode.json                                     Skip
  CreateOOGafterInitCodeReturndata.json                           Skip
  CreateOOGafterInitCodeReturndata2.json                          Skip
  CreateOOGafterInitCodeReturndata3.json                          Skip
  CreateOOGafterInitCodeReturndataSize.json                       Skip
  CreateOOGafterInitCodeRevert.json                               Skip
  CreateOOGafterInitCodeRevert2.json                              Skip
+ TransactionCollisionToEmpty.json                                OK
  TransactionCollisionToEmptyButCode.json                         Skip
  TransactionCollisionToEmptyButNonce.json                        Skip
```
OK: 14/30 Fail: 0/30 Skip: 16/30
## stDelegatecallTestHomestead
```diff
  Call1024BalanceTooLow.json                                      Skip
  Call1024OOG.json                                                Skip
  Call1024PreCalls.json                                           Skip
  CallLoseGasOOG.json                                             Skip
  CallRecursiveBombPreCall.json                                   Skip
  CallcodeLoseGasOOG.json                                         Skip
  Delegatecall1024.json                                           Skip
  Delegatecall1024OOG.json                                        Skip
  callOutput1.json                                                Skip
  callOutput2.json                                                Skip
  callOutput3.json                                                Skip
  callOutput3Fail.json                                            Skip
  callOutput3partial.json                                         Skip
  callOutput3partialFail.json                                     Skip
+ callWithHighValueAndGasOOG.json                                 OK
  callcodeOutput1.json                                            Skip
  callcodeOutput2.json                                            Skip
  callcodeOutput3.json                                            Skip
  callcodeOutput3Fail.json                                        Skip
  callcodeOutput3partial.json                                     Skip
  callcodeOutput3partialFail.json                                 Skip
+ callcodeWithHighValueAndGasOOG.json                             OK
  deleagateCallAfterValueTransfer.json                            Skip
+ delegatecallAndOOGatTxLevel.json                                OK
+ delegatecallBasic.json                                          OK
+ delegatecallEmptycontract.json                                  OK
  delegatecallInInitcodeToEmptyContract.json                      Skip
  delegatecallInInitcodeToExistingContract.json                   Skip
+ delegatecallInInitcodeToExistingContractOOG.json                OK
+ delegatecallOOGinCall.json                                      OK
  delegatecallSenderCheck.json                                    Skip
  delegatecallValueCheck.json                                     Skip
  delegatecodeDynamicCode.json                                    Skip
  delegatecodeDynamicCode2SelfCall.json                           Skip
```
OK: 7/34 Fail: 0/34 Skip: 27/34
## stEIP150Specific
```diff
  CallAndCallcodeConsumeMoreGasThenTransactionHas.json            Skip
  CallAskMoreGasOnDepth2ThenTransactionHas.json                   Skip
  CallGoesOOGOnSecondLevel.json                                   Skip
  CallGoesOOGOnSecondLevel2.json                                  Skip
  CreateAndGasInsideCreate.json                                   Skip
  DelegateCallOnEIP.json                                          Skip
  ExecuteCallThatAskForeGasThenTrabsactionHas.json                Skip
  NewGasPriceForCodes.json                                        Skip
  SuicideToExistingContract.json                                  Skip
  SuicideToNotExistingContract.json                               Skip
  Transaction64Rule_d64e0.json                                    Skip
  Transaction64Rule_d64m1.json                                    Skip
  Transaction64Rule_d64p1.json                                    Skip
```
OK: 0/13 Fail: 0/13 Skip: 13/13
## stEIP150singleCodeGasPrices
```diff
+ RawBalanceGas.json                                              OK
+ RawCallCodeGas.json                                             OK
+ RawCallCodeGasAsk.json                                          OK
+ RawCallCodeGasMemory.json                                       OK
+ RawCallCodeGasMemoryAsk.json                                    OK
+ RawCallCodeGasValueTransfer.json                                OK
+ RawCallCodeGasValueTransferAsk.json                             OK
+ RawCallCodeGasValueTransferMemory.json                          OK
+ RawCallCodeGasValueTransferMemoryAsk.json                       OK
+ RawCallGas.json                                                 OK
+ RawCallGasAsk.json                                              OK
+ RawCallGasValueTransfer.json                                    OK
+ RawCallGasValueTransferAsk.json                                 OK
+ RawCallGasValueTransferMemory.json                              OK
+ RawCallGasValueTransferMemoryAsk.json                           OK
+ RawCallMemoryGas.json                                           OK
+ RawCallMemoryGasAsk.json                                        OK
  RawCreateFailGasValueTransfer.json                              Skip
  RawCreateFailGasValueTransfer2.json                             Skip
+ RawCreateGas.json                                               OK
  RawCreateGasMemory.json                                         Skip
+ RawCreateGasValueTransfer.json                                  OK
  RawCreateGasValueTransferMemory.json                            Skip
+ RawDelegateCallGas.json                                         OK
+ RawDelegateCallGasAsk.json                                      OK
+ RawDelegateCallGasMemory.json                                   OK
+ RawDelegateCallGasMemoryAsk.json                                OK
+ RawExtCodeCopyGas.json                                          OK
+ RawExtCodeCopyMemoryGas.json                                    OK
+ RawExtCodeSizeGas.json                                          OK
```
OK: 26/30 Fail: 0/30 Skip: 4/30
## stEIP158Specific
```diff
  CALL_OneVCallSuicide.json                                       Skip
  CALL_ZeroVCallSuicide.json                                      Skip
  EXP_Empty.json                                                  Skip
  EXTCODESIZE_toEpmty.json                                        Skip
  EXTCODESIZE_toNonExistent.json                                  Skip
  vitalikTransactionTest.json                                     Skip
```
OK: 0/6 Fail: 0/6 Skip: 6/6
## stExample
```diff
+ add11.json                                                      OK
```
OK: 1/1 Fail: 0/1 Skip: 0/1
## stHomesteadSpecific
```diff
+ contractCreationOOGdontLeaveEmptyContract.json                  OK
+ contractCreationOOGdontLeaveEmptyContractViaTransaction.json    OK
+ createContractViaContract.json                                  OK
  createContractViaContractOOGInitCode.json                       Skip
+ createContractViaTransactionCost53000.json                      OK
```
OK: 4/5 Fail: 0/5 Skip: 1/5
## stInitCodeTest
```diff
+ CallContractToCreateContractAndCallItOOG.json                   OK
  CallContractToCreateContractNoCash.json                         Skip
  CallContractToCreateContractOOG.json                            Skip
+ CallContractToCreateContractOOGBonusGas.json                    OK
  CallContractToCreateContractWhichWouldCreateContractIfCalled.jsonSkip
  CallContractToCreateContractWhichWouldCreateContractInInitCode.jsonSkip
+ CallRecursiveContract.json                                      OK
  CallTheContractToCreateEmptyContract.json                       Skip
+ NotEnoughCashContractCreation.json                              OK
  OutOfGasContractCreation.json                                   Skip
  OutOfGasPrefundedContractCreation.json                          Skip
+ ReturnTest.json                                                 OK
+ ReturnTest2.json                                                OK
+ StackUnderFlowContractCreation.json                             OK
+ TransactionCreateAutoSuicideContract.json                       OK
+ TransactionCreateRandomInitCode.json                            OK
+ TransactionCreateStopInInitcode.json                            OK
+ TransactionCreateSuicideInInitcode.json                         OK
```
OK: 11/18 Fail: 0/18 Skip: 7/18
## stLogTests
```diff
+ log0_emptyMem.json                                              OK
+ log0_logMemStartTooHigh.json                                    OK
+ log0_logMemsizeTooHigh.json                                     OK
+ log0_logMemsizeZero.json                                        OK
+ log0_nonEmptyMem.json                                           OK
+ log0_nonEmptyMem_logMemSize1.json                               OK
+ log0_nonEmptyMem_logMemSize1_logMemStart31.json                 OK
+ log1_Caller.json                                                OK
+ log1_MaxTopic.json                                              OK
+ log1_emptyMem.json                                              OK
+ log1_logMemStartTooHigh.json                                    OK
+ log1_logMemsizeTooHigh.json                                     OK
+ log1_logMemsizeZero.json                                        OK
+ log1_nonEmptyMem.json                                           OK
+ log1_nonEmptyMem_logMemSize1.json                               OK
+ log1_nonEmptyMem_logMemSize1_logMemStart31.json                 OK
+ log2_Caller.json                                                OK
+ log2_MaxTopic.json                                              OK
+ log2_emptyMem.json                                              OK
+ log2_logMemStartTooHigh.json                                    OK
+ log2_logMemsizeTooHigh.json                                     OK
+ log2_logMemsizeZero.json                                        OK
+ log2_nonEmptyMem.json                                           OK
+ log2_nonEmptyMem_logMemSize1.json                               OK
+ log2_nonEmptyMem_logMemSize1_logMemStart31.json                 OK
+ log3_Caller.json                                                OK
+ log3_MaxTopic.json                                              OK
+ log3_PC.json                                                    OK
+ log3_emptyMem.json                                              OK
+ log3_logMemStartTooHigh.json                                    OK
+ log3_logMemsizeTooHigh.json                                     OK
+ log3_logMemsizeZero.json                                        OK
+ log3_nonEmptyMem.json                                           OK
+ log3_nonEmptyMem_logMemSize1.json                               OK
+ log3_nonEmptyMem_logMemSize1_logMemStart31.json                 OK
+ log4_Caller.json                                                OK
+ log4_MaxTopic.json                                              OK
+ log4_PC.json                                                    OK
+ log4_emptyMem.json                                              OK
+ log4_logMemStartTooHigh.json                                    OK
+ log4_logMemsizeTooHigh.json                                     OK
+ log4_logMemsizeZero.json                                        OK
+ log4_nonEmptyMem.json                                           OK
+ log4_nonEmptyMem_logMemSize1.json                               OK
+ log4_nonEmptyMem_logMemSize1_logMemStart31.json                 OK
+ logInOOG_Call.json                                              OK
```
OK: 46/46 Fail: 0/46 Skip: 0/46
## stMemExpandingEIP150Calls
```diff
+ CallAndCallcodeConsumeMoreGasThenTransactionHasWithMemExpandingCalls.jsonOK
+ CallAskMoreGasOnDepth2ThenTransactionHasWithMemExpandingCalls.jsonOK
+ CallGoesOOGOnSecondLevel2WithMemExpandingCalls.json             OK
+ CallGoesOOGOnSecondLevelWithMemExpandingCalls.json              OK
+ CreateAndGasInsideCreateWithMemExpandingCalls.json              OK
+ DelegateCallOnEIPWithMemExpandingCalls.json                     OK
+ ExecuteCallThatAskMoreGasThenTransactionHasWithMemExpandingCalls.jsonOK
  NewGasPriceForCodesWithMemExpandingCalls.json                   Skip
```
OK: 7/8 Fail: 0/8 Skip: 1/8
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
  CREATE_Bounds.json                                              Skip
  CREATE_Bounds2.json                                             Skip
  CREATE_Bounds3.json                                             Skip
  DELEGATECALL_Bounds.json                                        Skip
  DELEGATECALL_Bounds2.json                                       Skip
  DELEGATECALL_Bounds3.json                                       Skip
  DUP_Bounds.json                                                 Skip
+ FillStack.json                                                  OK
  JUMPI_Bounds.json                                               Skip
  JUMP_Bounds.json                                                Skip
  JUMP_Bounds2.json                                               Skip
  MLOAD_Bounds.json                                               Skip
  MLOAD_Bounds2.json                                              Skip
  MLOAD_Bounds3.json                                              Skip
  MSTORE_Bounds.json                                              Skip
  MSTORE_Bounds2.json                                             Skip
  MSTORE_Bounds2a.json                                            Skip
  POP_Bounds.json                                                 Skip
+ RETURN_Bounds.json                                              OK
  SLOAD_Bounds.json                                               Skip
  SSTORE_Bounds.json                                              Skip
  mload32bitBound.json                                            Skip
+ mload32bitBound2.json                                           OK
  mload32bitBound_Msize.json                                      Skip
+ mload32bitBound_return.json                                     OK
+ mload32bitBound_return2.json                                    OK
  static_CALL_Bounds.json                                         Skip
  static_CALL_Bounds2.json                                        Skip
  static_CALL_Bounds2a.json                                       Skip
  static_CALL_Bounds3.json                                        Skip
```
OK: 5/38 Fail: 0/38 Skip: 33/38
## stMemoryTest
```diff
  callDataCopyOffset.json                                         Skip
+ calldatacopy_dejavu.json                                        OK
+ calldatacopy_dejavu2.json                                       OK
  codeCopyOffset.json                                             Skip
+ codecopy_dejavu.json                                            OK
+ codecopy_dejavu2.json                                           OK
+ extcodecopy_dejavu.json                                         OK
+ log1_dejavu.json                                                OK
+ log2_dejavu.json                                                OK
+ log3_dejavu.json                                                OK
+ log4_dejavu.json                                                OK
+ mem0b_singleByte.json                                           OK
+ mem31b_singleByte.json                                          OK
+ mem32b_singleByte.json                                          OK
+ mem32kb+1.json                                                  OK
+ mem32kb+31.json                                                 OK
+ mem32kb+32.json                                                 OK
+ mem32kb+33.json                                                 OK
+ mem32kb-1.json                                                  OK
+ mem32kb-31.json                                                 OK
+ mem32kb-32.json                                                 OK
+ mem32kb-33.json                                                 OK
+ mem32kb.json                                                    OK
+ mem32kb_singleByte+1.json                                       OK
+ mem32kb_singleByte+31.json                                      OK
+ mem32kb_singleByte+32.json                                      OK
+ mem32kb_singleByte+33.json                                      OK
+ mem32kb_singleByte-1.json                                       OK
+ mem32kb_singleByte-31.json                                      OK
+ mem32kb_singleByte-32.json                                      OK
+ mem32kb_singleByte-33.json                                      OK
+ mem32kb_singleByte.json                                         OK
+ mem33b_singleByte.json                                          OK
+ mem64kb+1.json                                                  OK
+ mem64kb+31.json                                                 OK
+ mem64kb+32.json                                                 OK
+ mem64kb+33.json                                                 OK
+ mem64kb-1.json                                                  OK
+ mem64kb-31.json                                                 OK
+ mem64kb-32.json                                                 OK
+ mem64kb-33.json                                                 OK
+ mem64kb.json                                                    OK
+ mem64kb_singleByte+1.json                                       OK
+ mem64kb_singleByte+31.json                                      OK
+ mem64kb_singleByte+32.json                                      OK
+ mem64kb_singleByte+33.json                                      OK
+ mem64kb_singleByte-1.json                                       OK
+ mem64kb_singleByte-31.json                                      OK
+ mem64kb_singleByte-32.json                                      OK
+ mem64kb_singleByte-33.json                                      OK
+ mem64kb_singleByte.json                                         OK
+ memReturn.json                                                  OK
+ mload16bitBound.json                                            OK
+ mload8bitBound.json                                             OK
+ mload_dejavu.json                                               OK
+ mstore_dejavu.json                                              OK
+ mstroe8_dejavu.json                                             OK
+ sha3_dejavu.json                                                OK
+ stackLimitGas_1023.json                                         OK
+ stackLimitGas_1024.json                                         OK
+ stackLimitGas_1025.json                                         OK
+ stackLimitPush31_1023.json                                      OK
+ stackLimitPush31_1024.json                                      OK
+ stackLimitPush31_1025.json                                      OK
+ stackLimitPush32_1023.json                                      OK
+ stackLimitPush32_1024.json                                      OK
+ stackLimitPush32_1025.json                                      OK
```
OK: 65/67 Fail: 0/67 Skip: 2/67
## stNonZeroCallsTest
```diff
+ NonZeroValue_CALL.json                                          OK
+ NonZeroValue_CALLCODE.json                                      OK
+ NonZeroValue_CALLCODE_ToEmpty.json                              OK
  NonZeroValue_CALLCODE_ToNonNonZeroBalance.json                  Skip
+ NonZeroValue_CALLCODE_ToOneStorageKey.json                      OK
+ NonZeroValue_CALL_ToEmpty.json                                  OK
+ NonZeroValue_CALL_ToNonNonZeroBalance.json                      OK
+ NonZeroValue_CALL_ToOneStorageKey.json                          OK
+ NonZeroValue_DELEGATECALL.json                                  OK
+ NonZeroValue_DELEGATECALL_ToEmpty.json                          OK
+ NonZeroValue_DELEGATECALL_ToNonNonZeroBalance.json              OK
+ NonZeroValue_DELEGATECALL_ToOneStorageKey.json                  OK
+ NonZeroValue_SUICIDE.json                                       OK
+ NonZeroValue_SUICIDE_ToEmpty.json                               OK
+ NonZeroValue_SUICIDE_ToNonNonZeroBalance.json                   OK
+ NonZeroValue_SUICIDE_ToOneStorageKey.json                       OK
+ NonZeroValue_TransactionCALL.json                               OK
+ NonZeroValue_TransactionCALL_ToEmpty.json                       OK
+ NonZeroValue_TransactionCALL_ToNonNonZeroBalance.json           OK
+ NonZeroValue_TransactionCALL_ToOneStorageKey.json               OK
+ NonZeroValue_TransactionCALLwithData.json                       OK
+ NonZeroValue_TransactionCALLwithData_ToEmpty.json               OK
+ NonZeroValue_TransactionCALLwithData_ToNonNonZeroBalance.json   OK
+ NonZeroValue_TransactionCALLwithData_ToOneStorageKey.json       OK
```
OK: 23/24 Fail: 0/24 Skip: 1/24
## stPreCompiledContracts
```diff
  identity_to_bigger.json                                         Skip
  identity_to_smaller.json                                        Skip
  modexp.json                                                     Skip
  modexp_0_0_0_1000000.json                                       Skip
  modexp_0_0_0_155000.json                                        Skip
  modexp_0_1_0_1000000.json                                       Skip
  modexp_0_1_0_155000.json                                        Skip
  modexp_0_1_0_20500.json                                         Skip
  modexp_0_1_0_22000.json                                         Skip
  modexp_0_1_0_25000.json                                         Skip
  modexp_0_1_0_35000.json                                         Skip
  modexp_0_3_100_1000000.json                                     Skip
  modexp_0_3_100_155000.json                                      Skip
  modexp_0_3_100_20500.json                                       Skip
  modexp_0_3_100_22000.json                                       Skip
  modexp_0_3_100_25000.json                                       Skip
  modexp_0_3_100_35000.json                                       Skip
  modexp_1_0_0_1000000.json                                       Skip
  modexp_1_0_0_155000.json                                        Skip
  modexp_1_0_0_20500.json                                         Skip
  modexp_1_0_0_22000.json                                         Skip
  modexp_1_0_0_25000.json                                         Skip
  modexp_1_0_0_35000.json                                         Skip
  modexp_1_0_1_1000000.json                                       Skip
  modexp_1_0_1_155000.json                                        Skip
  modexp_1_0_1_20500.json                                         Skip
  modexp_1_0_1_22000.json                                         Skip
  modexp_1_0_1_25000.json                                         Skip
  modexp_1_0_1_35000.json                                         Skip
  modexp_1_1_1_1000000.json                                       Skip
  modexp_1_1_1_155000.json                                        Skip
  modexp_1_1_1_20500.json                                         Skip
  modexp_1_1_1_22000.json                                         Skip
  modexp_1_1_1_25000.json                                         Skip
  modexp_1_1_1_35000.json                                         Skip
  modexp_37120_22411_22000.json                                   Skip
  modexp_37120_37111_0_1000000.json                               Skip
  modexp_37120_37111_0_155000.json                                Skip
  modexp_37120_37111_0_20500.json                                 Skip
  modexp_37120_37111_0_22000.json                                 Skip
  modexp_37120_37111_0_25000.json                                 Skip
  modexp_37120_37111_0_35000.json                                 Skip
  modexp_37120_37111_1_1000000.json                               Skip
  modexp_37120_37111_1_155000.json                                Skip
  modexp_37120_37111_1_20500.json                                 Skip
  modexp_37120_37111_1_25000.json                                 Skip
  modexp_37120_37111_1_35000.json                                 Skip
  modexp_37120_37111_37111_1000000.json                           Skip
  modexp_37120_37111_37111_155000.json                            Skip
  modexp_37120_37111_37111_20500.json                             Skip
  modexp_37120_37111_37111_22000.json                             Skip
  modexp_37120_37111_37111_25000.json                             Skip
  modexp_37120_37111_37111_35000.json                             Skip
  modexp_37120_37111_97_1000000.json                              Skip
  modexp_37120_37111_97_155000.json                               Skip
  modexp_37120_37111_97_20500.json                                Skip
  modexp_37120_37111_97_22000.json                                Skip
  modexp_37120_37111_97_25000.json                                Skip
  modexp_37120_37111_97_35000.json                                Skip
  modexp_39936_1_55201_1000000.json                               Skip
  modexp_39936_1_55201_155000.json                                Skip
  modexp_39936_1_55201_20500.json                                 Skip
  modexp_39936_1_55201_22000.json                                 Skip
  modexp_39936_1_55201_25000.json                                 Skip
  modexp_39936_1_55201_35000.json                                 Skip
  modexp_3_09984_39936_1000000.json                               Skip
  modexp_3_09984_39936_155000.json                                Skip
  modexp_3_09984_39936_22000.json                                 Skip
  modexp_3_09984_39936_25000.json                                 Skip
  modexp_3_09984_39936_35000.json                                 Skip
  modexp_3_28948_11579_20500.json                                 Skip
  modexp_3_5_100_1000000.json                                     Skip
  modexp_3_5_100_155000.json                                      Skip
  modexp_3_5_100_20500.json                                       Skip
  modexp_3_5_100_22000.json                                       Skip
  modexp_3_5_100_25000.json                                       Skip
  modexp_3_5_100_35000.json                                       Skip
  modexp_49_2401_2401_1000000.json                                Skip
  modexp_49_2401_2401_155000.json                                 Skip
  modexp_49_2401_2401_20500.json                                  Skip
  modexp_49_2401_2401_22000.json                                  Skip
  modexp_49_2401_2401_25000.json                                  Skip
  modexp_49_2401_2401_35000.json                                  Skip
  modexp_55190_55190_42965_1000000.json                           Skip
  modexp_55190_55190_42965_155000.json                            Skip
  modexp_55190_55190_42965_20500.json                             Skip
  modexp_55190_55190_42965_22000.json                             Skip
  modexp_55190_55190_42965_25000.json                             Skip
  modexp_55190_55190_42965_35000.json                             Skip
  modexp_9_37111_37111_1000000.json                               Skip
  modexp_9_37111_37111_155000.json                                Skip
  modexp_9_37111_37111_20500.json                                 Skip
  modexp_9_37111_37111_22000.json                                 Skip
  modexp_9_37111_37111_35000.json                                 Skip
  modexp_9_3711_37111_25000.json                                  Skip
  sec80.json                                                      Skip
```
OK: 0/96 Fail: 0/96 Skip: 96/96
## stPreCompiledContracts2
```diff
+ CALLCODEEcrecover0.json                                         OK
  CALLCODEEcrecover0_0input.json                                  Skip
+ CALLCODEEcrecover0_Gas2999.json                                 OK
+ CALLCODEEcrecover0_NoGas.json                                   OK
+ CALLCODEEcrecover0_completeReturnValue.json                     OK
+ CALLCODEEcrecover0_gas3000.json                                 OK
+ CALLCODEEcrecover0_overlappingInputOutput.json                  OK
  CALLCODEEcrecover1.json                                         Skip
  CALLCODEEcrecover2.json                                         Skip
+ CALLCODEEcrecover3.json                                         OK
  CALLCODEEcrecover80.json                                        Skip
+ CALLCODEEcrecoverH_prefixed0.json                               OK
  CALLCODEEcrecoverR_prefixed0.json                               Skip
+ CALLCODEEcrecoverS_prefixed0.json                               OK
+ CALLCODEEcrecoverV_prefixed0.json                               OK
  CALLCODEEcrecoverV_prefixedf0.json                              Skip
+ CALLCODEIdentitiy_0.json                                        OK
+ CALLCODEIdentitiy_1.json                                        OK
+ CALLCODEIdentity_1_nonzeroValue.json                            OK
+ CALLCODEIdentity_2.json                                         OK
+ CALLCODEIdentity_3.json                                         OK
+ CALLCODEIdentity_4.json                                         OK
+ CALLCODEIdentity_4_gas17.json                                   OK
+ CALLCODEIdentity_4_gas18.json                                   OK
+ CALLCODEIdentity_5.json                                         OK
+ CALLCODERipemd160_0.json                                        OK
+ CALLCODERipemd160_1.json                                        OK
  CALLCODERipemd160_2.json                                        Skip
  CALLCODERipemd160_3.json                                        Skip
  CALLCODERipemd160_3_postfixed0.json                             Skip
  CALLCODERipemd160_3_prefixed0.json                              Skip
+ CALLCODERipemd160_4.json                                        OK
+ CALLCODERipemd160_4_gas719.json                                 OK
+ CALLCODERipemd160_5.json                                        OK
+ CALLCODESha256_0.json                                           OK
+ CALLCODESha256_1.json                                           OK
+ CALLCODESha256_1_nonzeroValue.json                              OK
  CALLCODESha256_2.json                                           Skip
  CALLCODESha256_3.json                                           Skip
  CALLCODESha256_3_postfix0.json                                  Skip
  CALLCODESha256_3_prefix0.json                                   Skip
+ CALLCODESha256_4.json                                           OK
+ CALLCODESha256_4_gas99.json                                     OK
+ CALLCODESha256_5.json                                           OK
+ CallEcrecover0.json                                             OK
  CallEcrecover0_0input.json                                      Skip
+ CallEcrecover0_Gas2999.json                                     OK
+ CallEcrecover0_NoGas.json                                       OK
+ CallEcrecover0_completeReturnValue.json                         OK
+ CallEcrecover0_gas3000.json                                     OK
+ CallEcrecover0_overlappingInputOutput.json                      OK
  CallEcrecover1.json                                             Skip
  CallEcrecover2.json                                             Skip
+ CallEcrecover3.json                                             OK
  CallEcrecover80.json                                            Skip
+ CallEcrecoverCheckLength.json                                   OK
  CallEcrecoverCheckLengthWrongV.json                             Skip
+ CallEcrecoverH_prefixed0.json                                   OK
  CallEcrecoverR_prefixed0.json                                   Skip
+ CallEcrecoverS_prefixed0.json                                   OK
+ CallEcrecoverV_prefixed0.json                                   OK
+ CallIdentitiy_0.json                                            OK
+ CallIdentitiy_1.json                                            OK
+ CallIdentity_1_nonzeroValue.json                                OK
+ CallIdentity_2.json                                             OK
+ CallIdentity_3.json                                             OK
+ CallIdentity_4.json                                             OK
+ CallIdentity_4_gas17.json                                       OK
+ CallIdentity_4_gas18.json                                       OK
+ CallIdentity_5.json                                             OK
+ CallRipemd160_0.json                                            OK
+ CallRipemd160_1.json                                            OK
  CallRipemd160_2.json                                            Skip
  CallRipemd160_3.json                                            Skip
  CallRipemd160_3_postfixed0.json                                 Skip
  CallRipemd160_3_prefixed0.json                                  Skip
+ CallRipemd160_4.json                                            OK
+ CallRipemd160_4_gas719.json                                     OK
+ CallRipemd160_5.json                                            OK
+ CallSha256_0.json                                               OK
+ CallSha256_1.json                                               OK
+ CallSha256_1_nonzeroValue.json                                  OK
  CallSha256_2.json                                               Skip
  CallSha256_3.json                                               Skip
  CallSha256_3_postfix0.json                                      Skip
  CallSha256_3_prefix0.json                                       Skip
+ CallSha256_4.json                                               OK
+ CallSha256_4_gas99.json                                         OK
+ CallSha256_5.json                                               OK
  modexpRandomInput.json                                          Skip
  modexp_0_0_0_20500.json                                         Skip
  modexp_0_0_0_22000.json                                         Skip
  modexp_0_0_0_25000.json                                         Skip
  modexp_0_0_0_35000.json                                         Skip
```
OK: 61/94 Fail: 0/94 Skip: 33/94
## stQuadraticComplexityTest
```diff
  Call1MB1024Calldepth.json                                       Skip
  Call50000.json                                                  Skip
  Call50000_ecrec.json                                            Skip
  Call50000_identity.json                                         Skip
  Call50000_identity2.json                                        Skip
  Call50000_rip160.json                                           Skip
  Call50000_sha256.json                                           Skip
  Call50000bytesContract50_1.json                                 Skip
  Call50000bytesContract50_2.json                                 Skip
  Call50000bytesContract50_3.json                                 Skip
  Callcode50000.json                                              Skip
  Create1000.json                                                 Skip
  Create1000Byzantium.json                                        Skip
  QuadraticComplexitySolidity_CallDataCopy.json                   Skip
  Return50000.json                                                Skip
  Return50000_2.json                                              Skip
```
OK: 0/16 Fail: 0/16 Skip: 16/16
## stRandom
```diff
+ randomStatetest0.json                                           OK
  randomStatetest1.json                                           Skip
+ randomStatetest10.json                                          OK
+ randomStatetest100.json                                         OK
  randomStatetest101.json                                         Skip
+ randomStatetest102.json                                         OK
+ randomStatetest103.json                                         OK
+ randomStatetest104.json                                         OK
+ randomStatetest105.json                                         OK
+ randomStatetest106.json                                         OK
+ randomStatetest107.json                                         OK
+ randomStatetest108.json                                         OK
+ randomStatetest11.json                                          OK
+ randomStatetest110.json                                         OK
+ randomStatetest111.json                                         OK
+ randomStatetest112.json                                         OK
+ randomStatetest114.json                                         OK
+ randomStatetest115.json                                         OK
  randomStatetest116.json                                         Skip
+ randomStatetest117.json                                         OK
+ randomStatetest118.json                                         OK
+ randomStatetest119.json                                         OK
+ randomStatetest12.json                                          OK
+ randomStatetest120.json                                         OK
+ randomStatetest121.json                                         OK
+ randomStatetest122.json                                         OK
+ randomStatetest123.json                                         OK
+ randomStatetest124.json                                         OK
+ randomStatetest125.json                                         OK
+ randomStatetest126.json                                         OK
+ randomStatetest129.json                                         OK
+ randomStatetest13.json                                          OK
+ randomStatetest130.json                                         OK
+ randomStatetest131.json                                         OK
+ randomStatetest133.json                                         OK
+ randomStatetest134.json                                         OK
+ randomStatetest135.json                                         OK
+ randomStatetest136.json                                         OK
+ randomStatetest137.json                                         OK
+ randomStatetest138.json                                         OK
+ randomStatetest139.json                                         OK
  randomStatetest14.json                                          Skip
+ randomStatetest142.json                                         OK
+ randomStatetest143.json                                         OK
+ randomStatetest144.json                                         OK
+ randomStatetest145.json                                         OK
+ randomStatetest146.json                                         OK
+ randomStatetest147.json                                         OK
+ randomStatetest148.json                                         OK
+ randomStatetest149.json                                         OK
+ randomStatetest15.json                                          OK
+ randomStatetest150.json                                         OK
+ randomStatetest151.json                                         OK
+ randomStatetest153.json                                         OK
+ randomStatetest154.json                                         OK
+ randomStatetest155.json                                         OK
+ randomStatetest156.json                                         OK
+ randomStatetest157.json                                         OK
+ randomStatetest158.json                                         OK
+ randomStatetest159.json                                         OK
+ randomStatetest16.json                                          OK
+ randomStatetest160.json                                         OK
+ randomStatetest161.json                                         OK
+ randomStatetest162.json                                         OK
+ randomStatetest163.json                                         OK
+ randomStatetest164.json                                         OK
+ randomStatetest166.json                                         OK
+ randomStatetest167.json                                         OK
+ randomStatetest169.json                                         OK
+ randomStatetest17.json                                          OK
+ randomStatetest170.json                                         OK
+ randomStatetest171.json                                         OK
+ randomStatetest172.json                                         OK
+ randomStatetest173.json                                         OK
+ randomStatetest174.json                                         OK
+ randomStatetest175.json                                         OK
+ randomStatetest176.json                                         OK
+ randomStatetest177.json                                         OK
+ randomStatetest178.json                                         OK
+ randomStatetest179.json                                         OK
+ randomStatetest18.json                                          OK
+ randomStatetest180.json                                         OK
+ randomStatetest183.json                                         OK
  randomStatetest184.json                                         Skip
+ randomStatetest185.json                                         OK
+ randomStatetest187.json                                         OK
+ randomStatetest188.json                                         OK
+ randomStatetest189.json                                         OK
+ randomStatetest19.json                                          OK
+ randomStatetest190.json                                         OK
+ randomStatetest191.json                                         OK
+ randomStatetest192.json                                         OK
+ randomStatetest194.json                                         OK
+ randomStatetest195.json                                         OK
+ randomStatetest196.json                                         OK
+ randomStatetest197.json                                         OK
+ randomStatetest198.json                                         OK
+ randomStatetest199.json                                         OK
+ randomStatetest2.json                                           OK
+ randomStatetest20.json                                          OK
+ randomStatetest200.json                                         OK
+ randomStatetest201.json                                         OK
+ randomStatetest202.json                                         OK
+ randomStatetest204.json                                         OK
+ randomStatetest205.json                                         OK
+ randomStatetest206.json                                         OK
+ randomStatetest207.json                                         OK
+ randomStatetest208.json                                         OK
+ randomStatetest209.json                                         OK
+ randomStatetest210.json                                         OK
+ randomStatetest211.json                                         OK
+ randomStatetest212.json                                         OK
+ randomStatetest214.json                                         OK
+ randomStatetest215.json                                         OK
+ randomStatetest216.json                                         OK
+ randomStatetest217.json                                         OK
+ randomStatetest219.json                                         OK
+ randomStatetest22.json                                          OK
+ randomStatetest220.json                                         OK
+ randomStatetest221.json                                         OK
+ randomStatetest222.json                                         OK
+ randomStatetest223.json                                         OK
+ randomStatetest225.json                                         OK
+ randomStatetest226.json                                         OK
+ randomStatetest227.json                                         OK
+ randomStatetest228.json                                         OK
+ randomStatetest229.json                                         OK
+ randomStatetest23.json                                          OK
+ randomStatetest230.json                                         OK
+ randomStatetest231.json                                         OK
+ randomStatetest232.json                                         OK
+ randomStatetest233.json                                         OK
+ randomStatetest236.json                                         OK
  randomStatetest237.json                                         Skip
+ randomStatetest238.json                                         OK
+ randomStatetest24.json                                          OK
+ randomStatetest241.json                                         OK
+ randomStatetest242.json                                         OK
+ randomStatetest243.json                                         OK
+ randomStatetest244.json                                         OK
+ randomStatetest245.json                                         OK
+ randomStatetest246.json                                         OK
+ randomStatetest247.json                                         OK
  randomStatetest248.json                                         Skip
+ randomStatetest249.json                                         OK
+ randomStatetest25.json                                          OK
+ randomStatetest250.json                                         OK
+ randomStatetest251.json                                         OK
+ randomStatetest252.json                                         OK
+ randomStatetest254.json                                         OK
+ randomStatetest257.json                                         OK
+ randomStatetest259.json                                         OK
+ randomStatetest26.json                                          OK
+ randomStatetest260.json                                         OK
+ randomStatetest261.json                                         OK
+ randomStatetest263.json                                         OK
+ randomStatetest264.json                                         OK
+ randomStatetest265.json                                         OK
+ randomStatetest266.json                                         OK
+ randomStatetest267.json                                         OK
+ randomStatetest268.json                                         OK
+ randomStatetest269.json                                         OK
+ randomStatetest27.json                                          OK
+ randomStatetest270.json                                         OK
+ randomStatetest271.json                                         OK
+ randomStatetest273.json                                         OK
+ randomStatetest274.json                                         OK
+ randomStatetest275.json                                         OK
+ randomStatetest276.json                                         OK
+ randomStatetest278.json                                         OK
+ randomStatetest279.json                                         OK
+ randomStatetest28.json                                          OK
+ randomStatetest280.json                                         OK
+ randomStatetest281.json                                         OK
+ randomStatetest282.json                                         OK
+ randomStatetest283.json                                         OK
+ randomStatetest285.json                                         OK
+ randomStatetest286.json                                         OK
+ randomStatetest287.json                                         OK
+ randomStatetest288.json                                         OK
+ randomStatetest29.json                                          OK
+ randomStatetest290.json                                         OK
+ randomStatetest291.json                                         OK
+ randomStatetest292.json                                         OK
+ randomStatetest293.json                                         OK
+ randomStatetest294.json                                         OK
+ randomStatetest295.json                                         OK
+ randomStatetest296.json                                         OK
+ randomStatetest297.json                                         OK
+ randomStatetest298.json                                         OK
+ randomStatetest299.json                                         OK
+ randomStatetest3.json                                           OK
+ randomStatetest30.json                                          OK
+ randomStatetest300.json                                         OK
+ randomStatetest301.json                                         OK
+ randomStatetest302.json                                         OK
+ randomStatetest303.json                                         OK
+ randomStatetest304.json                                         OK
+ randomStatetest305.json                                         OK
+ randomStatetest306.json                                         OK
+ randomStatetest307.json                                         OK
+ randomStatetest308.json                                         OK
+ randomStatetest309.json                                         OK
+ randomStatetest31.json                                          OK
+ randomStatetest310.json                                         OK
+ randomStatetest311.json                                         OK
+ randomStatetest312.json                                         OK
+ randomStatetest313.json                                         OK
+ randomStatetest315.json                                         OK
+ randomStatetest316.json                                         OK
+ randomStatetest318.json                                         OK
  randomStatetest32.json                                          Skip
+ randomStatetest320.json                                         OK
+ randomStatetest321.json                                         OK
+ randomStatetest322.json                                         OK
+ randomStatetest323.json                                         OK
+ randomStatetest324.json                                         OK
+ randomStatetest325.json                                         OK
+ randomStatetest326.json                                         OK
+ randomStatetest327.json                                         OK
+ randomStatetest328.json                                         OK
+ randomStatetest329.json                                         OK
+ randomStatetest33.json                                          OK
+ randomStatetest332.json                                         OK
+ randomStatetest333.json                                         OK
+ randomStatetest334.json                                         OK
+ randomStatetest335.json                                         OK
+ randomStatetest336.json                                         OK
+ randomStatetest337.json                                         OK
+ randomStatetest338.json                                         OK
+ randomStatetest339.json                                         OK
+ randomStatetest340.json                                         OK
+ randomStatetest341.json                                         OK
+ randomStatetest342.json                                         OK
+ randomStatetest343.json                                         OK
+ randomStatetest345.json                                         OK
+ randomStatetest346.json                                         OK
  randomStatetest347.json                                         Skip
+ randomStatetest348.json                                         OK
+ randomStatetest349.json                                         OK
+ randomStatetest350.json                                         OK
+ randomStatetest351.json                                         OK
  randomStatetest352.json                                         Skip
+ randomStatetest353.json                                         OK
+ randomStatetest354.json                                         OK
+ randomStatetest355.json                                         OK
+ randomStatetest356.json                                         OK
+ randomStatetest357.json                                         OK
+ randomStatetest358.json                                         OK
+ randomStatetest359.json                                         OK
+ randomStatetest36.json                                          OK
+ randomStatetest360.json                                         OK
+ randomStatetest361.json                                         OK
+ randomStatetest362.json                                         OK
+ randomStatetest363.json                                         OK
+ randomStatetest364.json                                         OK
+ randomStatetest365.json                                         OK
+ randomStatetest366.json                                         OK
+ randomStatetest367.json                                         OK
+ randomStatetest368.json                                         OK
+ randomStatetest369.json                                         OK
+ randomStatetest37.json                                          OK
+ randomStatetest370.json                                         OK
+ randomStatetest371.json                                         OK
+ randomStatetest372.json                                         OK
+ randomStatetest375.json                                         OK
+ randomStatetest376.json                                         OK
+ randomStatetest377.json                                         OK
+ randomStatetest378.json                                         OK
+ randomStatetest379.json                                         OK
+ randomStatetest38.json                                          OK
+ randomStatetest380.json                                         OK
+ randomStatetest381.json                                         OK
+ randomStatetest382.json                                         OK
+ randomStatetest383.json                                         OK
+ randomStatetest39.json                                          OK
+ randomStatetest4.json                                           OK
+ randomStatetest41.json                                          OK
+ randomStatetest42.json                                          OK
+ randomStatetest43.json                                          OK
+ randomStatetest45.json                                          OK
+ randomStatetest46.json                                          OK
+ randomStatetest47.json                                          OK
+ randomStatetest48.json                                          OK
+ randomStatetest49.json                                          OK
+ randomStatetest5.json                                           OK
+ randomStatetest50.json                                          OK
+ randomStatetest51.json                                          OK
+ randomStatetest52.json                                          OK
+ randomStatetest53.json                                          OK
+ randomStatetest54.json                                          OK
+ randomStatetest55.json                                          OK
+ randomStatetest57.json                                          OK
+ randomStatetest58.json                                          OK
+ randomStatetest59.json                                          OK
+ randomStatetest6.json                                           OK
+ randomStatetest60.json                                          OK
+ randomStatetest62.json                                          OK
+ randomStatetest63.json                                          OK
+ randomStatetest64.json                                          OK
+ randomStatetest66.json                                          OK
+ randomStatetest67.json                                          OK
+ randomStatetest69.json                                          OK
  randomStatetest7.json                                           Skip
+ randomStatetest72.json                                          OK
+ randomStatetest73.json                                          OK
+ randomStatetest74.json                                          OK
+ randomStatetest75.json                                          OK
+ randomStatetest77.json                                          OK
+ randomStatetest78.json                                          OK
+ randomStatetest80.json                                          OK
+ randomStatetest81.json                                          OK
+ randomStatetest82.json                                          OK
+ randomStatetest83.json                                          OK
+ randomStatetest84.json                                          OK
  randomStatetest85.json                                          Skip
+ randomStatetest87.json                                          OK
+ randomStatetest88.json                                          OK
+ randomStatetest89.json                                          OK
+ randomStatetest9.json                                           OK
+ randomStatetest90.json                                          OK
+ randomStatetest92.json                                          OK
+ randomStatetest94.json                                          OK
+ randomStatetest95.json                                          OK
+ randomStatetest96.json                                          OK
+ randomStatetest97.json                                          OK
+ randomStatetest98.json                                          OK
```
OK: 315/327 Fail: 0/327 Skip: 12/327
## stRandom2
```diff
+ 201503110226PYTHON_DUP6.json                                    OK
+ randomStatetest.json                                            OK
+ randomStatetest384.json                                         OK
+ randomStatetest385.json                                         OK
  randomStatetest386.json                                         Skip
+ randomStatetest387.json                                         OK
+ randomStatetest388.json                                         OK
+ randomStatetest389.json                                         OK
+ randomStatetest391.json                                         OK
  randomStatetest393.json                                         Skip
+ randomStatetest395.json                                         OK
+ randomStatetest396.json                                         OK
+ randomStatetest397.json                                         OK
+ randomStatetest398.json                                         OK
+ randomStatetest399.json                                         OK
+ randomStatetest401.json                                         OK
+ randomStatetest402.json                                         OK
+ randomStatetest404.json                                         OK
+ randomStatetest405.json                                         OK
+ randomStatetest406.json                                         OK
+ randomStatetest407.json                                         OK
+ randomStatetest408.json                                         OK
+ randomStatetest409.json                                         OK
+ randomStatetest410.json                                         OK
+ randomStatetest411.json                                         OK
+ randomStatetest412.json                                         OK
+ randomStatetest413.json                                         OK
+ randomStatetest414.json                                         OK
+ randomStatetest415.json                                         OK
+ randomStatetest416.json                                         OK
+ randomStatetest417.json                                         OK
+ randomStatetest418.json                                         OK
+ randomStatetest419.json                                         OK
+ randomStatetest420.json                                         OK
+ randomStatetest421.json                                         OK
+ randomStatetest422.json                                         OK
+ randomStatetest423.json                                         OK
+ randomStatetest424.json                                         OK
+ randomStatetest425.json                                         OK
+ randomStatetest426.json                                         OK
+ randomStatetest428.json                                         OK
+ randomStatetest429.json                                         OK
+ randomStatetest430.json                                         OK
+ randomStatetest433.json                                         OK
+ randomStatetest435.json                                         OK
+ randomStatetest436.json                                         OK
+ randomStatetest437.json                                         OK
+ randomStatetest438.json                                         OK
+ randomStatetest439.json                                         OK
+ randomStatetest440.json                                         OK
+ randomStatetest441.json                                         OK
+ randomStatetest442.json                                         OK
+ randomStatetest443.json                                         OK
+ randomStatetest444.json                                         OK
+ randomStatetest445.json                                         OK
+ randomStatetest446.json                                         OK
+ randomStatetest447.json                                         OK
+ randomStatetest448.json                                         OK
+ randomStatetest449.json                                         OK
+ randomStatetest450.json                                         OK
+ randomStatetest451.json                                         OK
+ randomStatetest452.json                                         OK
+ randomStatetest454.json                                         OK
+ randomStatetest455.json                                         OK
+ randomStatetest456.json                                         OK
+ randomStatetest457.json                                         OK
+ randomStatetest458.json                                         OK
+ randomStatetest460.json                                         OK
+ randomStatetest461.json                                         OK
+ randomStatetest462.json                                         OK
+ randomStatetest464.json                                         OK
+ randomStatetest465.json                                         OK
+ randomStatetest466.json                                         OK
+ randomStatetest467.json                                         OK
+ randomStatetest468.json                                         OK
+ randomStatetest469.json                                         OK
+ randomStatetest470.json                                         OK
+ randomStatetest471.json                                         OK
+ randomStatetest472.json                                         OK
+ randomStatetest473.json                                         OK
+ randomStatetest474.json                                         OK
+ randomStatetest475.json                                         OK
+ randomStatetest476.json                                         OK
+ randomStatetest477.json                                         OK
+ randomStatetest478.json                                         OK
+ randomStatetest480.json                                         OK
+ randomStatetest481.json                                         OK
+ randomStatetest482.json                                         OK
+ randomStatetest483.json                                         OK
+ randomStatetest484.json                                         OK
+ randomStatetest485.json                                         OK
+ randomStatetest487.json                                         OK
+ randomStatetest488.json                                         OK
+ randomStatetest489.json                                         OK
+ randomStatetest491.json                                         OK
+ randomStatetest493.json                                         OK
+ randomStatetest494.json                                         OK
+ randomStatetest495.json                                         OK
+ randomStatetest496.json                                         OK
+ randomStatetest497.json                                         OK
+ randomStatetest498.json                                         OK
+ randomStatetest499.json                                         OK
+ randomStatetest500.json                                         OK
+ randomStatetest501.json                                         OK
+ randomStatetest502.json                                         OK
+ randomStatetest503.json                                         OK
+ randomStatetest504.json                                         OK
+ randomStatetest505.json                                         OK
+ randomStatetest506.json                                         OK
+ randomStatetest507.json                                         OK
+ randomStatetest508.json                                         OK
+ randomStatetest509.json                                         OK
+ randomStatetest510.json                                         OK
+ randomStatetest511.json                                         OK
+ randomStatetest512.json                                         OK
+ randomStatetest513.json                                         OK
+ randomStatetest514.json                                         OK
+ randomStatetest516.json                                         OK
+ randomStatetest517.json                                         OK
+ randomStatetest518.json                                         OK
+ randomStatetest519.json                                         OK
+ randomStatetest520.json                                         OK
+ randomStatetest521.json                                         OK
+ randomStatetest523.json                                         OK
+ randomStatetest524.json                                         OK
+ randomStatetest525.json                                         OK
+ randomStatetest526.json                                         OK
+ randomStatetest527.json                                         OK
+ randomStatetest528.json                                         OK
+ randomStatetest531.json                                         OK
+ randomStatetest532.json                                         OK
+ randomStatetest533.json                                         OK
+ randomStatetest534.json                                         OK
+ randomStatetest535.json                                         OK
+ randomStatetest536.json                                         OK
+ randomStatetest537.json                                         OK
+ randomStatetest538.json                                         OK
+ randomStatetest539.json                                         OK
+ randomStatetest541.json                                         OK
+ randomStatetest542.json                                         OK
+ randomStatetest543.json                                         OK
+ randomStatetest544.json                                         OK
+ randomStatetest545.json                                         OK
+ randomStatetest546.json                                         OK
+ randomStatetest547.json                                         OK
+ randomStatetest548.json                                         OK
+ randomStatetest549.json                                         OK
+ randomStatetest550.json                                         OK
+ randomStatetest552.json                                         OK
+ randomStatetest553.json                                         OK
+ randomStatetest554.json                                         OK
+ randomStatetest555.json                                         OK
+ randomStatetest556.json                                         OK
+ randomStatetest558.json                                         OK
+ randomStatetest559.json                                         OK
+ randomStatetest560.json                                         OK
+ randomStatetest562.json                                         OK
+ randomStatetest563.json                                         OK
+ randomStatetest564.json                                         OK
+ randomStatetest565.json                                         OK
+ randomStatetest566.json                                         OK
+ randomStatetest567.json                                         OK
+ randomStatetest569.json                                         OK
+ randomStatetest571.json                                         OK
+ randomStatetest572.json                                         OK
+ randomStatetest573.json                                         OK
+ randomStatetest574.json                                         OK
+ randomStatetest575.json                                         OK
+ randomStatetest576.json                                         OK
+ randomStatetest577.json                                         OK
+ randomStatetest578.json                                         OK
+ randomStatetest579.json                                         OK
+ randomStatetest580.json                                         OK
+ randomStatetest581.json                                         OK
+ randomStatetest582.json                                         OK
+ randomStatetest583.json                                         OK
+ randomStatetest584.json                                         OK
+ randomStatetest585.json                                         OK
+ randomStatetest586.json                                         OK
+ randomStatetest587.json                                         OK
+ randomStatetest588.json                                         OK
+ randomStatetest589.json                                         OK
+ randomStatetest592.json                                         OK
+ randomStatetest594.json                                         OK
+ randomStatetest596.json                                         OK
+ randomStatetest597.json                                         OK
+ randomStatetest599.json                                         OK
+ randomStatetest600.json                                         OK
+ randomStatetest601.json                                         OK
+ randomStatetest602.json                                         OK
+ randomStatetest603.json                                         OK
+ randomStatetest604.json                                         OK
+ randomStatetest605.json                                         OK
+ randomStatetest607.json                                         OK
+ randomStatetest608.json                                         OK
+ randomStatetest609.json                                         OK
+ randomStatetest610.json                                         OK
+ randomStatetest611.json                                         OK
+ randomStatetest612.json                                         OK
+ randomStatetest615.json                                         OK
+ randomStatetest616.json                                         OK
+ randomStatetest618.json                                         OK
+ randomStatetest619.json                                         OK
+ randomStatetest620.json                                         OK
+ randomStatetest621.json                                         OK
+ randomStatetest624.json                                         OK
+ randomStatetest625.json                                         OK
  randomStatetest626.json                                         Skip
+ randomStatetest627.json                                         OK
+ randomStatetest628.json                                         OK
+ randomStatetest629.json                                         OK
+ randomStatetest630.json                                         OK
+ randomStatetest632.json                                         OK
+ randomStatetest633.json                                         OK
+ randomStatetest635.json                                         OK
+ randomStatetest636.json                                         OK
+ randomStatetest637.json                                         OK
+ randomStatetest638.json                                         OK
+ randomStatetest639.json                                         OK
+ randomStatetest640.json                                         OK
+ randomStatetest641.json                                         OK
+ randomStatetest642.json                                         OK
  randomStatetest643.json                                         Skip
+ randomStatetest644.json                                         OK
+ randomStatetest645.json                                         OK
  randomStatetest646.json                                         Skip
  randomStatetest647.json                                         Skip
```
OK: 221/227 Fail: 0/227 Skip: 6/227
## stRecursiveCreate
```diff
  recursiveCreate.json                                            Skip
  recursiveCreateReturnValue.json                                 Skip
```
OK: 0/2 Fail: 0/2 Skip: 2/2
## stRefundTest
```diff
+ refund50_1.json                                                 OK
+ refund50_2.json                                                 OK
+ refund50percentCap.json                                         OK
+ refund600.json                                                  OK
+ refundSuicide50procentCap.json                                  OK
+ refund_CallA.json                                               OK
+ refund_CallA_OOG.json                                           OK
+ refund_CallA_notEnoughGasInCall.json                            OK
+ refund_CallToSuicideNoStorage.json                              OK
+ refund_CallToSuicideStorage.json                                OK
+ refund_CallToSuicideTwice.json                                  OK
+ refund_NoOOG_1.json                                             OK
+ refund_OOG.json                                                 OK
+ refund_TxToSuicide.json                                         OK
+ refund_TxToSuicideOOG.json                                      OK
+ refund_changeNonZeroStorage.json                                OK
+ refund_getEtherBack.json                                        OK
+ refund_multimpleSuicide.json                                    OK
+ refund_singleSuicide.json                                       OK
```
OK: 19/19 Fail: 0/19 Skip: 0/19
## stReturnDataTest
```diff
+ call_ecrec_success_empty_then_returndatasize.json               OK
+ call_outsize_then_create_successful_then_returndatasize.json    OK
+ call_then_call_value_fail_then_returndatasize.json              OK
+ call_then_create_successful_then_returndatasize.json            OK
+ create_callprecompile_returndatasize.json                       OK
  modexp_modsize0_returndatasize.json                             Skip
+ returndatacopy_0_0_following_successful_create.json             OK
  returndatacopy_afterFailing_create.json                         Skip
+ returndatacopy_after_failing_callcode.json                      OK
+ returndatacopy_after_failing_delegatecall.json                  OK
+ returndatacopy_after_failing_staticcall.json                    OK
+ returndatacopy_after_revert_in_staticcall.json                  OK
+ returndatacopy_after_successful_callcode.json                   OK
+ returndatacopy_after_successful_delegatecall.json               OK
+ returndatacopy_after_successful_staticcall.json                 OK
+ returndatacopy_following_call.json                              OK
+ returndatacopy_following_create.json                            OK
+ returndatacopy_following_failing_call.json                      OK
+ returndatacopy_following_revert.json                            OK
+ returndatacopy_following_revert_in_create.json                  OK
+ returndatacopy_following_successful_create.json                 OK
+ returndatacopy_following_too_big_transfer.json                  OK
+ returndatacopy_initial.json                                     OK
+ returndatacopy_initial_256.json                                 OK
+ returndatacopy_initial_big_sum.json                             OK
+ returndatacopy_overrun.json                                     OK
+ returndatasize_after_failing_callcode.json                      OK
  returndatasize_after_failing_delegatecall.json                  Skip
+ returndatasize_after_failing_staticcall.json                    OK
+ returndatasize_after_oog_after_deeper.json                      OK
+ returndatasize_after_successful_callcode.json                   OK
+ returndatasize_after_successful_delegatecall.json               OK
+ returndatasize_after_successful_staticcall.json                 OK
+ returndatasize_bug.json                                         OK
+ returndatasize_following_successful_create.json                 OK
+ returndatasize_initial.json                                     OK
+ returndatasize_initial_zero_read.json                           OK
```
OK: 34/37 Fail: 0/37 Skip: 3/37
## stRevertTest
```diff
+ LoopCallsDepthThenRevert.json                                   OK
  LoopCallsDepthThenRevert2.json                                  Skip
  LoopCallsDepthThenRevert3.json                                  Skip
+ LoopCallsThenRevert.json                                        OK
+ LoopDelegateCallsDepthThenRevert.json                           OK
+ NashatyrevSuicideRevert.json                                    OK
+ PythonRevertTestTue201814-1430.json                             OK
+ RevertDepth2.json                                               OK
+ RevertDepthCreateAddressCollision.json                          OK
+ RevertDepthCreateOOG.json                                       OK
+ RevertInCallCode.json                                           OK
+ RevertInCreateInInit.json                                       OK
+ RevertInDelegateCall.json                                       OK
+ RevertInStaticCall.json                                         OK
+ RevertOnEmptyStack.json                                         OK
+ RevertOpcode.json                                               OK
  RevertOpcodeCalls.json                                          Skip
+ RevertOpcodeCreate.json                                         OK
  RevertOpcodeDirectCall.json                                     Skip
  RevertOpcodeInCallsOnNonEmptyReturnData.json                    Skip
+ RevertOpcodeInCreateReturns.json                                OK
  RevertOpcodeInInit.json                                         Skip
  RevertOpcodeMultipleSubCalls.json                               Skip
  RevertOpcodeReturn.json                                         Skip
  RevertOpcodeWithBigOutputInInit.json                            Skip
  RevertPrecompiledTouch.json                                     Skip
  RevertPrecompiledTouchCC.json                                   Skip
  RevertPrecompiledTouchDC.json                                   Skip
  RevertPrefound.json                                             Skip
+ RevertPrefoundCall.json                                         OK
+ RevertPrefoundCallOOG.json                                      OK
  RevertPrefoundEmpty.json                                        Skip
+ RevertPrefoundEmptyCall.json                                    OK
+ RevertPrefoundEmptyCallOOG.json                                 OK
+ RevertPrefoundEmptyOOG.json                                     OK
+ RevertPrefoundOOG.json                                          OK
+ RevertRemoteSubCallStorageOOG.json                              OK
+ RevertRemoteSubCallStorageOOG2.json                             OK
+ RevertSubCallStorageOOG.json                                    OK
+ RevertSubCallStorageOOG2.json                                   OK
+ TouchToEmptyAccountRevert.json                                  OK
+ TouchToEmptyAccountRevert2.json                                 OK
+ TouchToEmptyAccountRevert3.json                                 OK
```
OK: 29/43 Fail: 0/43 Skip: 14/43
## stShift
```diff
  sar00.json                                                      Skip
+ sar01.json                                                      OK
+ sar10.json                                                      OK
+ sar11.json                                                      OK
  sar_0_256-1.json                                                Skip
+ sar_2^254_254.json                                              OK
+ sar_2^255-1_248.json                                            OK
+ sar_2^255-1_254.json                                            OK
+ sar_2^255-1_255.json                                            OK
+ sar_2^255-1_256.json                                            OK
+ sar_2^255_1.json                                                OK
+ sar_2^255_255.json                                              OK
+ sar_2^255_256.json                                              OK
+ sar_2^255_257.json                                              OK
+ sar_2^256-1_0.json                                              OK
+ sar_2^256-1_1.json                                              OK
+ sar_2^256-1_255.json                                            OK
+ sar_2^256-1_256.json                                            OK
+ shl01-0100.json                                                 OK
+ shl01-0101.json                                                 OK
+ shl01-ff.json                                                   OK
+ shl01.json                                                      OK
+ shl10.json                                                      OK
+ shl11.json                                                      OK
+ shl_-1_0.json                                                   OK
+ shl_-1_1.json                                                   OK
+ shl_-1_255.json                                                 OK
+ shl_-1_256.json                                                 OK
+ shl_2^255-1_1.json                                              OK
+ shr01.json                                                      OK
+ shr10.json                                                      OK
+ shr11.json                                                      OK
+ shr_-1_0.json                                                   OK
+ shr_-1_1.json                                                   OK
+ shr_-1_255.json                                                 OK
+ shr_-1_256.json                                                 OK
+ shr_2^255_1.json                                                OK
+ shr_2^255_255.json                                              OK
+ shr_2^255_256.json                                              OK
+ shr_2^255_257.json                                              OK
```
OK: 38/40 Fail: 0/40 Skip: 2/40
## stSolidityTest
```diff
+ AmbiguousMethod.json                                            OK
+ CallInfiniteLoop.json                                           OK
+ CallLowLevelCreatesSolidity.json                                OK
+ CallRecursiveMethods.json                                       OK
+ ContractInheritance.json                                        OK
+ CreateContractFromMethod.json                                   OK
+ RecursiveCreateContracts.json                                   OK
+ RecursiveCreateContractsCreate4Contracts.json                   OK
+ TestBlockAndTransactionProperties.json                          OK
+ TestContractInteraction.json                                    OK
+ TestContractSuicide.json                                        OK
  TestCryptographicFunctions.json                                 Skip
+ TestKeywords.json                                               OK
+ TestOverflow.json                                               OK
+ TestStoreGasPrices.json                                         OK
+ TestStructuresAndVariabless.json                                OK
```
OK: 15/16 Fail: 0/16 Skip: 1/16
## stSpecialTest
```diff
+ FailedCreateRevertsDeletion.json                                OK
  JUMPDEST_Attack.json                                            Skip
  JUMPDEST_AttackwithJump.json                                    Skip
  OverflowGasMakeMoney.json                                       Skip
+ StackDepthLimitSEC.json                                         OK
  block504980.json                                                Skip
+ deploymentError.json                                            OK
  failed_tx_xcf416c53.json                                        Skip
  gasPrice0.json                                                  Skip
+ makeMoney.json                                                  OK
  sha3_deja.json                                                  Skip
  txCost-sec73.json                                               Skip
  tx_e1c174e2.json                                                Skip
```
OK: 4/13 Fail: 0/13 Skip: 9/13
## stStackTests
```diff
  shallowStack.json                                               Skip
  stackOverflow.json                                              Skip
  stackOverflowDUP.json                                           Skip
  stackOverflowM1.json                                            Skip
+ stackOverflowM1DUP.json                                         OK
  stackOverflowM1PUSH.json                                        Skip
  stackOverflowPUSH.json                                          Skip
```
OK: 1/7 Fail: 0/7 Skip: 6/7
## stStaticCall
```diff
  static_ABAcalls0.json                                           Skip
  static_ABAcalls1.json                                           Skip
  static_ABAcalls2.json                                           Skip
  static_ABAcalls3.json                                           Skip
  static_ABAcallsSuicide0.json                                    Skip
  static_ABAcallsSuicide1.json                                    Skip
  static_CALL_OneVCallSuicide.json                                Skip
  static_CALL_ZeroVCallSuicide.json                               Skip
  static_CREATE_ContractSuicideDuringInit.json                    Skip
  static_CREATE_ContractSuicideDuringInit_ThenStoreThenReturn.jsonSkip
  static_CREATE_ContractSuicideDuringInit_WithValue.json          Skip
  static_CREATE_EmptyContractAndCallIt_0wei.json                  Skip
  static_CREATE_EmptyContractWithStorageAndCallIt_0wei.json       Skip
  static_Call10.json                                              Skip
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
  static_Call50000_sha256.json                                    Skip
  static_Call50000bytesContract50_1.json                          Skip
  static_Call50000bytesContract50_2.json                          Skip
  static_Call50000bytesContract50_3.json                          Skip
  static_CallAndCallcodeConsumeMoreGasThenTransactionHas.json     Skip
  static_CallAskMoreGasOnDepth2ThenTransactionHas.json            Skip
  static_CallContractToCreateContractAndCallItOOG.json            Skip
  static_CallContractToCreateContractOOG.json                     Skip
  static_CallContractToCreateContractOOGBonusGas.json             Skip
  static_CallContractToCreateContractWhichWouldCreateContractIfCalled.jsonSkip
  static_CallEcrecover0.json                                      Skip
  static_CallEcrecover0_0input.json                               Skip
  static_CallEcrecover0_Gas2999.json                              Skip
  static_CallEcrecover0_NoGas.json                                Skip
  static_CallEcrecover0_completeReturnValue.json                  Skip
  static_CallEcrecover0_gas3000.json                              Skip
  static_CallEcrecover0_overlappingInputOutput.json               Skip
  static_CallEcrecover1.json                                      Skip
  static_CallEcrecover2.json                                      Skip
  static_CallEcrecover3.json                                      Skip
  static_CallEcrecover80.json                                     Skip
  static_CallEcrecoverCheckLength.json                            Skip
  static_CallEcrecoverCheckLengthWrongV.json                      Skip
  static_CallEcrecoverH_prefixed0.json                            Skip
  static_CallEcrecoverR_prefixed0.json                            Skip
  static_CallEcrecoverS_prefixed0.json                            Skip
  static_CallEcrecoverV_prefixed0.json                            Skip
  static_CallGoesOOGOnSecondLevel.json                            Skip
  static_CallGoesOOGOnSecondLevel2.json                           Skip
  static_CallIdentitiy_1.json                                     Skip
  static_CallIdentity_1_nonzeroValue.json                         Skip
  static_CallIdentity_2.json                                      Skip
  static_CallIdentity_3.json                                      Skip
  static_CallIdentity_4.json                                      Skip
  static_CallIdentity_4_gas17.json                                Skip
  static_CallIdentity_4_gas18.json                                Skip
  static_CallIdentity_5.json                                      Skip
  static_CallLoseGasOOG.json                                      Skip
  static_CallRecursiveBomb0.json                                  Skip
  static_CallRecursiveBomb0_OOG_atMaxCallDepth.json               Skip
  static_CallRecursiveBomb1.json                                  Skip
  static_CallRecursiveBomb2.json                                  Skip
  static_CallRecursiveBomb3.json                                  Skip
  static_CallRecursiveBombLog.json                                Skip
  static_CallRecursiveBombLog2.json                               Skip
  static_CallRecursiveBombPreCall.json                            Skip
  static_CallRecursiveBombPreCall2.json                           Skip
  static_CallRipemd160_1.json                                     Skip
  static_CallRipemd160_2.json                                     Skip
  static_CallRipemd160_3.json                                     Skip
  static_CallRipemd160_3_postfixed0.json                          Skip
  static_CallRipemd160_3_prefixed0.json                           Skip
  static_CallRipemd160_4.json                                     Skip
  static_CallRipemd160_4_gas719.json                              Skip
  static_CallRipemd160_5.json                                     Skip
  static_CallSha256_1.json                                        Skip
  static_CallSha256_1_nonzeroValue.json                           Skip
  static_CallSha256_2.json                                        Skip
  static_CallSha256_3.json                                        Skip
  static_CallSha256_3_postfix0.json                               Skip
  static_CallSha256_3_prefix0.json                                Skip
  static_CallSha256_4.json                                        Skip
  static_CallSha256_4_gas99.json                                  Skip
  static_CallSha256_5.json                                        Skip
  static_CallToNameRegistrator0.json                              Skip
  static_CallToReturn1.json                                       Skip
  static_CalltoReturn2.json                                       Skip
  static_CheckCallCostOOG.json                                    Skip
  static_CheckOpcodes.json                                        Skip
  static_CheckOpcodes2.json                                       Skip
  static_CheckOpcodes3.json                                       Skip
  static_CheckOpcodes4.json                                       Skip
  static_CheckOpcodes5.json                                       Skip
  static_ExecuteCallThatAskForeGasThenTrabsactionHas.json         Skip
  static_InternalCallHittingGasLimit.json                         Skip
  static_InternalCallHittingGasLimit2.json                        Skip
  static_InternlCallStoreClearsOOG.json                           Skip
  static_LoopCallsDepthThenRevert.json                            Skip
  static_LoopCallsDepthThenRevert2.json                           Skip
  static_LoopCallsDepthThenRevert3.json                           Skip
  static_LoopCallsThenRevert.json                                 Skip
  static_PostToReturn1.json                                       Skip
  static_RETURN_Bounds.json                                       Skip
  static_RETURN_BoundsOOG.json                                    Skip
  static_RawCallGasAsk.json                                       Skip
  static_Return50000_2.json                                       Skip
  static_ReturnTest.json                                          Skip
  static_ReturnTest2.json                                         Skip
  static_RevertDepth2.json                                        Skip
  static_RevertOpcodeCalls.json                                   Skip
  static_ZeroValue_CALL_OOGRevert.json                            Skip
  static_ZeroValue_SUICIDE_OOGRevert.json                         Skip
  static_callBasic.json                                           Skip
  static_callChangeRevert.json                                    Skip
  static_callCreate.json                                          Skip
  static_callCreate2.json                                         Skip
  static_callCreate3.json                                         Skip
  static_callOutput1.json                                         Skip
  static_callOutput2.json                                         Skip
  static_callOutput3.json                                         Skip
  static_callOutput3Fail.json                                     Skip
  static_callOutput3partial.json                                  Skip
  static_callOutput3partialFail.json                              Skip
  static_callToCallCodeOpCodeCheck.json                           Skip
  static_callToCallOpCodeCheck.json                               Skip
  static_callToDelCallOpCodeCheck.json                            Skip
  static_callToStaticOpCodeCheck.json                             Skip
  static_callWithHighValue.json                                   Skip
  static_callWithHighValueAndGasOOG.json                          Skip
  static_callWithHighValueAndOOGatTxLevel.json                    Skip
  static_callWithHighValueOOGinCall.json                          Skip
  static_call_OOG_additionalGasCosts1.json                        Skip
  static_call_OOG_additionalGasCosts2.json                        Skip
  static_call_value_inherit.json                                  Skip
  static_call_value_inherit_from_call.json                        Skip
  static_callcall_00.json                                         Skip
  static_callcall_00_OOGE.json                                    Skip
  static_callcall_00_OOGE_1.json                                  Skip
  static_callcall_00_OOGE_2.json                                  Skip
  static_callcall_00_SuicideEnd.json                              Skip
  static_callcallcall_000.json                                    Skip
  static_callcallcall_000_OOGE.json                               Skip
  static_callcallcall_000_OOGMAfter.json                          Skip
  static_callcallcall_000_OOGMAfter2.json                         Skip
  static_callcallcall_000_OOGMBefore.json                         Skip
  static_callcallcall_000_SuicideEnd.json                         Skip
  static_callcallcall_000_SuicideMiddle.json                      Skip
  static_callcallcall_ABCB_RECURSIVE.json                         Skip
  static_callcallcallcode_001.json                                Skip
  static_callcallcallcode_001_2.json                              Skip
  static_callcallcallcode_001_OOGE.json                           Skip
  static_callcallcallcode_001_OOGE_2.json                         Skip
  static_callcallcallcode_001_OOGMAfter.json                      Skip
  static_callcallcallcode_001_OOGMAfter2.json                     Skip
  static_callcallcallcode_001_OOGMAfter_2.json                    Skip
  static_callcallcallcode_001_OOGMAfter_3.json                    Skip
  static_callcallcallcode_001_OOGMBefore.json                     Skip
  static_callcallcallcode_001_OOGMBefore2.json                    Skip
  static_callcallcallcode_001_SuicideEnd.json                     Skip
  static_callcallcallcode_001_SuicideEnd2.json                    Skip
  static_callcallcallcode_001_SuicideMiddle.json                  Skip
  static_callcallcallcode_001_SuicideMiddle2.json                 Skip
  static_callcallcallcode_ABCB_RECURSIVE.json                     Skip
  static_callcallcallcode_ABCB_RECURSIVE2.json                    Skip
  static_callcallcode_01_2.json                                   Skip
  static_callcallcode_01_OOGE_2.json                              Skip
  static_callcallcode_01_SuicideEnd.json                          Skip
  static_callcallcode_01_SuicideEnd2.json                         Skip
  static_callcallcodecall_010.json                                Skip
  static_callcallcodecall_010_2.json                              Skip
  static_callcallcodecall_010_OOGE.json                           Skip
  static_callcallcodecall_010_OOGE_2.json                         Skip
  static_callcallcodecall_010_OOGMAfter.json                      Skip
  static_callcallcodecall_010_OOGMAfter2.json                     Skip
  static_callcallcodecall_010_OOGMAfter_2.json                    Skip
  static_callcallcodecall_010_OOGMAfter_3.json                    Skip
  static_callcallcodecall_010_OOGMBefore.json                     Skip
  static_callcallcodecall_010_OOGMBefore2.json                    Skip
  static_callcallcodecall_010_SuicideEnd.json                     Skip
  static_callcallcodecall_010_SuicideEnd2.json                    Skip
  static_callcallcodecall_010_SuicideMiddle.json                  Skip
  static_callcallcodecall_010_SuicideMiddle2.json                 Skip
  static_callcallcodecall_ABCB_RECURSIVE.json                     Skip
  static_callcallcodecall_ABCB_RECURSIVE2.json                    Skip
  static_callcallcodecallcode_011.json                            Skip
  static_callcallcodecallcode_011_2.json                          Skip
  static_callcallcodecallcode_011_OOGE.json                       Skip
  static_callcallcodecallcode_011_OOGE_2.json                     Skip
  static_callcallcodecallcode_011_OOGMAfter.json                  Skip
  static_callcallcodecallcode_011_OOGMAfter2.json                 Skip
  static_callcallcodecallcode_011_OOGMAfter_1.json                Skip
  static_callcallcodecallcode_011_OOGMAfter_2.json                Skip
  static_callcallcodecallcode_011_OOGMBefore.json                 Skip
  static_callcallcodecallcode_011_OOGMBefore2.json                Skip
  static_callcallcodecallcode_011_SuicideEnd.json                 Skip
  static_callcallcodecallcode_011_SuicideEnd2.json                Skip
  static_callcallcodecallcode_011_SuicideMiddle.json              Skip
  static_callcallcodecallcode_011_SuicideMiddle2.json             Skip
  static_callcallcodecallcode_ABCB_RECURSIVE.json                 Skip
  static_callcallcodecallcode_ABCB_RECURSIVE2.json                Skip
  static_callcode_checkPC.json                                    Skip
  static_callcodecall_10.json                                     Skip
  static_callcodecall_10_2.json                                   Skip
  static_callcodecall_10_OOGE.json                                Skip
  static_callcodecall_10_OOGE_2.json                              Skip
  static_callcodecall_10_SuicideEnd.json                          Skip
  static_callcodecall_10_SuicideEnd2.json                         Skip
  static_callcodecallcall_100.json                                Skip
  static_callcodecallcall_100_2.json                              Skip
  static_callcodecallcall_100_OOGE.json                           Skip
  static_callcodecallcall_100_OOGE2.json                          Skip
  static_callcodecallcall_100_OOGMAfter.json                      Skip
  static_callcodecallcall_100_OOGMAfter2.json                     Skip
  static_callcodecallcall_100_OOGMAfter_2.json                    Skip
  static_callcodecallcall_100_OOGMAfter_3.json                    Skip
  static_callcodecallcall_100_OOGMBefore.json                     Skip
  static_callcodecallcall_100_OOGMBefore2.json                    Skip
  static_callcodecallcall_100_SuicideEnd.json                     Skip
  static_callcodecallcall_100_SuicideEnd2.json                    Skip
  static_callcodecallcall_100_SuicideMiddle.json                  Skip
  static_callcodecallcall_100_SuicideMiddle2.json                 Skip
  static_callcodecallcall_ABCB_RECURSIVE.json                     Skip
  static_callcodecallcall_ABCB_RECURSIVE2.json                    Skip
  static_callcodecallcallcode_101.json                            Skip
  static_callcodecallcallcode_101_2.json                          Skip
  static_callcodecallcallcode_101_OOGE.json                       Skip
  static_callcodecallcallcode_101_OOGE_2.json                     Skip
  static_callcodecallcallcode_101_OOGMAfter.json                  Skip
  static_callcodecallcallcode_101_OOGMAfter2.json                 Skip
  static_callcodecallcallcode_101_OOGMAfter_1.json                Skip
  static_callcodecallcallcode_101_OOGMAfter_3.json                Skip
  static_callcodecallcallcode_101_OOGMBefore.json                 Skip
  static_callcodecallcallcode_101_OOGMBefore2.json                Skip
  static_callcodecallcallcode_101_SuicideEnd.json                 Skip
  static_callcodecallcallcode_101_SuicideEnd2.json                Skip
  static_callcodecallcallcode_101_SuicideMiddle.json              Skip
  static_callcodecallcallcode_101_SuicideMiddle2.json             Skip
  static_callcodecallcallcode_ABCB_RECURSIVE.json                 Skip
  static_callcodecallcallcode_ABCB_RECURSIVE2.json                Skip
  static_callcodecallcodecall_110.json                            Skip
  static_callcodecallcodecall_1102.json                           Skip
  static_callcodecallcodecall_110_2.json                          Skip
  static_callcodecallcodecall_110_OOGE.json                       Skip
  static_callcodecallcodecall_110_OOGE2.json                      Skip
  static_callcodecallcodecall_110_OOGMAfter.json                  Skip
  static_callcodecallcodecall_110_OOGMAfter2.json                 Skip
  static_callcodecallcodecall_110_OOGMAfter_2.json                Skip
  static_callcodecallcodecall_110_OOGMAfter_3.json                Skip
  static_callcodecallcodecall_110_OOGMBefore.json                 Skip
  static_callcodecallcodecall_110_OOGMBefore2.json                Skip
  static_callcodecallcodecall_110_SuicideEnd.json                 Skip
  static_callcodecallcodecall_110_SuicideEnd2.json                Skip
  static_callcodecallcodecall_110_SuicideMiddle.json              Skip
  static_callcodecallcodecall_110_SuicideMiddle2.json             Skip
  static_callcodecallcodecall_ABCB_RECURSIVE.json                 Skip
  static_callcodecallcodecall_ABCB_RECURSIVE2.json                Skip
  static_callcodecallcodecallcode_111_SuicideEnd.json             Skip
  static_calldelcode_01.json                                      Skip
  static_calldelcode_01_OOGE.json                                 Skip
  static_contractCreationMakeCallThatAskMoreGasThenTransactionProvided.jsonSkip
  static_contractCreationOOGdontLeaveEmptyContractViaTransaction.jsonSkip
  static_log0_emptyMem.json                                       Skip
  static_log0_logMemStartTooHigh.json                             Skip
  static_log0_logMemsizeTooHigh.json                              Skip
  static_log0_logMemsizeZero.json                                 Skip
  static_log0_nonEmptyMem.json                                    Skip
  static_log0_nonEmptyMem_logMemSize1.json                        Skip
  static_log0_nonEmptyMem_logMemSize1_logMemStart31.json          Skip
  static_log1_MaxTopic.json                                       Skip
  static_log1_emptyMem.json                                       Skip
  static_log1_logMemStartTooHigh.json                             Skip
  static_log1_logMemsizeTooHigh.json                              Skip
  static_log1_logMemsizeZero.json                                 Skip
  static_log_Caller.json                                          Skip
  static_makeMoney.json                                           Skip
  static_refund_CallA.json                                        Skip
  static_refund_CallToSuicideNoStorage.json                       Skip
  static_refund_CallToSuicideTwice.json                           Skip
```
OK: 0/284 Fail: 0/284 Skip: 284/284
## stSystemOperationsTest
```diff
+ ABAcalls0.json                                                  OK
  ABAcalls1.json                                                  Skip
  ABAcalls2.json                                                  Skip
+ ABAcalls3.json                                                  OK
+ ABAcallsSuicide0.json                                           OK
+ ABAcallsSuicide1.json                                           OK
+ Call10.json                                                     OK
  CallRecursiveBomb0.json                                         Skip
  CallRecursiveBomb0_OOG_atMaxCallDepth.json                      Skip
  CallRecursiveBomb1.json                                         Skip
  CallRecursiveBomb2.json                                         Skip
+ CallRecursiveBomb3.json                                         OK
  CallRecursiveBombLog.json                                       Skip
  CallRecursiveBombLog2.json                                      Skip
+ CallToNameRegistrator0.json                                     OK
+ CallToNameRegistratorAddressTooBigLeft.json                     OK
+ CallToNameRegistratorAddressTooBigRight.json                    OK
  CallToNameRegistratorMemOOGAndInsufficientBalance.json          Skip
+ CallToNameRegistratorNotMuchMemory0.json                        OK
+ CallToNameRegistratorNotMuchMemory1.json                        OK
+ CallToNameRegistratorOutOfGas.json                              OK
  CallToNameRegistratorTooMuchMemory0.json                        Skip
+ CallToNameRegistratorTooMuchMemory1.json                        OK
+ CallToNameRegistratorTooMuchMemory2.json                        OK
+ CallToNameRegistratorZeorSizeMemExpansion.json                  OK
+ CallToReturn1.json                                              OK
+ CallToReturn1ForDynamicJump0.json                               OK
+ CallToReturn1ForDynamicJump1.json                               OK
+ CalltoReturn2.json                                              OK
  CreateHashCollision.json                                        Skip
+ PostToReturn1.json                                              OK
+ TestNameRegistrator.json                                        OK
+ balanceInputAddressTooBig.json                                  OK
+ callValue.json                                                  OK
+ callcodeTo0.json                                                OK
+ callcodeToNameRegistrator0.json                                 OK
+ callcodeToNameRegistratorAddresTooBigLeft.json                  OK
+ callcodeToNameRegistratorAddresTooBigRight.json                 OK
+ callcodeToNameRegistratorZeroMemExpanion.json                   OK
+ callcodeToReturn1.json                                          OK
+ callerAccountBalance.json                                       OK
+ createNameRegistrator.json                                      OK
  createNameRegistratorOOG_MemExpansionOOV.json                   Skip
  createNameRegistratorOutOfMemoryBonds0.json                     Skip
  createNameRegistratorOutOfMemoryBonds1.json                     Skip
+ createNameRegistratorValueTooHigh.json                          OK
+ createNameRegistratorZeroMem.json                               OK
+ createNameRegistratorZeroMem2.json                              OK
+ createNameRegistratorZeroMemExpansion.json                      OK
+ createWithInvalidOpcode.json                                    OK
+ currentAccountBalance.json                                      OK
+ doubleSelfdestructTest.json                                     OK
+ doubleSelfdestructTest2.json                                    OK
+ extcodecopy.json                                                OK
+ return0.json                                                    OK
+ return1.json                                                    OK
+ return2.json                                                    OK
+ suicideAddress.json                                             OK
+ suicideCaller.json                                              OK
+ suicideCallerAddresTooBigLeft.json                              OK
+ suicideCallerAddresTooBigRight.json                             OK
  suicideCoinbase.json                                            Skip
+ suicideNotExistingAccount.json                                  OK
+ suicideOrigin.json                                              OK
+ suicideSendEtherPostDeath.json                                  OK
+ suicideSendEtherToMe.json                                       OK
  testRandomTest.json                                             Skip
```
OK: 51/67 Fail: 0/67 Skip: 16/67
## stTransactionTest
```diff
+ ContractStoreClearsOOG.json                                     OK
+ ContractStoreClearsSuccess.json                                 OK
+ CreateMessageReverted.json                                      OK
+ CreateMessageSuccess.json                                       OK
+ CreateTransactionReverted.json                                  OK
+ CreateTransactionSuccess.json                                   OK
+ EmptyTransaction.json                                           OK
+ EmptyTransaction2.json                                          OK
+ EmptyTransaction3.json                                          OK
+ HighGasLimit.json                                               OK
+ InternalCallHittingGasLimit.json                                OK
+ InternalCallHittingGasLimit2.json                               OK
+ InternalCallHittingGasLimitSuccess.json                         OK
+ InternlCallStoreClearsOOG.json                                  OK
+ InternlCallStoreClearsSucces.json                               OK
  Opcodes_TransactionInit.json                                    Skip
+ OverflowGasRequire.json                                         OK
+ OverflowGasRequire2.json                                        OK
+ RefundOverflow.json                                             OK
+ RefundOverflow2.json                                            OK
+ StoreClearsAndInternlCallStoreClearsOOG.json                    OK
+ StoreClearsAndInternlCallStoreClearsSuccess.json                OK
+ StoreGasOnCreate.json                                           OK
+ SuicidesAndInternlCallSuicidesBonusGasAtCall.json               OK
+ SuicidesAndInternlCallSuicidesBonusGasAtCallFailed.json         OK
+ SuicidesAndInternlCallSuicidesOOG.json                          OK
+ SuicidesAndInternlCallSuicidesSuccess.json                      OK
+ SuicidesAndSendMoneyToItselfEtherDestroyed.json                 OK
  SuicidesMixingCoinbase.json                                     Skip
+ SuicidesStopAfterSuicide.json                                   OK
+ TransactionDataCosts652.json                                    OK
+ TransactionFromCoinbaseHittingBlockGasLimit.json                OK
  TransactionFromCoinbaseHittingBlockGasLimit1.json               Skip
+ TransactionFromCoinbaseNotEnoughFounds.json                     OK
+ TransactionNonceCheck.json                                      OK
+ TransactionNonceCheck2.json                                     OK
+ TransactionSendingToEmpty.json                                  OK
+ TransactionSendingToZero.json                                   OK
+ TransactionToAddressh160minusOne.json                           OK
+ TransactionToItself.json                                        OK
+ TransactionToItselfNotEnoughFounds.json                         OK
+ UserTransactionGasLimitIsTooLowWhenZeroCost.json                OK
+ UserTransactionZeroCost.json                                    OK
+ UserTransactionZeroCostWithData.json                            OK
```
OK: 41/44 Fail: 0/44 Skip: 3/44
## stTransitionTest
```diff
+ createNameRegistratorPerTxsAfter.json                           OK
+ createNameRegistratorPerTxsAt.json                              OK
+ createNameRegistratorPerTxsBefore.json                          OK
  createNameRegistratorPerTxsNotEnoughGasAfter.json               Skip
  createNameRegistratorPerTxsNotEnoughGasAt.json                  Skip
  createNameRegistratorPerTxsNotEnoughGasBefore.json              Skip
  delegatecallAfterTransition.json                                Skip
  delegatecallAtTransition.json                                   Skip
  delegatecallBeforeTransition.json                               Skip
```
OK: 3/9 Fail: 0/9 Skip: 6/9
## stWalletTest
```diff
+ dayLimitConstruction.json                                       OK
  dayLimitConstructionOOG.json                                    Skip
+ dayLimitConstructionPartial.json                                OK
  dayLimitResetSpentToday.json                                    Skip
  dayLimitSetDailyLimit.json                                      Skip
  dayLimitSetDailyLimitNoData.json                                Skip
  multiOwnedAddOwner.json                                         Skip
  multiOwnedAddOwnerAddMyself.json                                Skip
  multiOwnedChangeOwner.json                                      Skip
  multiOwnedChangeOwnerNoArgument.json                            Skip
  multiOwnedChangeOwner_fromNotOwner.json                         Skip
  multiOwnedChangeOwner_toIsOwner.json                            Skip
  multiOwnedChangeRequirementTo0.json                             Skip
  multiOwnedChangeRequirementTo1.json                             Skip
  multiOwnedChangeRequirementTo2.json                             Skip
+ multiOwnedConstructionCorrect.json                              OK
  multiOwnedConstructionNotEnoughGas.json                         Skip
  multiOwnedConstructionNotEnoughGasPartial.json                  Skip
  multiOwnedIsOwnerFalse.json                                     Skip
  multiOwnedIsOwnerTrue.json                                      Skip
  multiOwnedRemoveOwner.json                                      Skip
+ multiOwnedRemoveOwnerByNonOwner.json                            OK
  multiOwnedRemoveOwner_mySelf.json                               Skip
  multiOwnedRemoveOwner_ownerIsNotOwner.json                      Skip
  multiOwnedRevokeNothing.json                                    Skip
+ walletAddOwnerRemovePendingTransaction.json                     OK
+ walletChangeOwnerRemovePendingTransaction.json                  OK
+ walletChangeRequirementRemovePendingTransaction.json            OK
+ walletConfirm.json                                              OK
+ walletConstruction.json                                         OK
  walletConstructionOOG.json                                      Skip
+ walletConstructionPartial.json                                  OK
  walletDefault.json                                              Skip
  walletDefaultWithOutValue.json                                  Skip
  walletExecuteOverDailyLimitMultiOwner.json                      Skip
  walletExecuteOverDailyLimitOnlyOneOwner.json                    Skip
  walletExecuteOverDailyLimitOnlyOneOwnerNew.json                 Skip
  walletExecuteUnderDailyLimit.json                               Skip
  walletKill.json                                                 Skip
+ walletKillNotByOwner.json                                       OK
  walletKillToWallet.json                                         Skip
+ walletRemoveOwnerRemovePendingTransaction.json                  OK
```
OK: 12/42 Fail: 0/42 Skip: 30/42
## stZeroCallsRevert
```diff
  ZeroValue_CALLCODE_OOGRevert.json                               Skip
  ZeroValue_CALLCODE_ToEmpty_OOGRevert.json                       Skip
  ZeroValue_CALLCODE_ToNonZeroBalance_OOGRevert.json              Skip
  ZeroValue_CALLCODE_ToOneStorageKey_OOGRevert.json               Skip
  ZeroValue_CALL_OOGRevert.json                                   Skip
  ZeroValue_CALL_ToEmpty_OOGRevert.json                           Skip
  ZeroValue_CALL_ToNonZeroBalance_OOGRevert.json                  Skip
  ZeroValue_CALL_ToOneStorageKey_OOGRevert.json                   Skip
  ZeroValue_DELEGATECALL_OOGRevert.json                           Skip
  ZeroValue_DELEGATECALL_ToEmpty_OOGRevert.json                   Skip
  ZeroValue_DELEGATECALL_ToNonZeroBalance_OOGRevert.json          Skip
  ZeroValue_DELEGATECALL_ToOneStorageKey_OOGRevert.json           Skip
  ZeroValue_SUICIDE_OOGRevert.json                                Skip
  ZeroValue_SUICIDE_ToEmpty_OOGRevert.json                        Skip
  ZeroValue_SUICIDE_ToNonZeroBalance_OOGRevert.json               Skip
  ZeroValue_SUICIDE_ToOneStorageKey_OOGRevert.json                Skip
  ZeroValue_TransactionCALL_OOGRevert.json                        Skip
  ZeroValue_TransactionCALL_ToEmpty_OOGRevert.json                Skip
  ZeroValue_TransactionCALL_ToNonZeroBalance_OOGRevert.json       Skip
  ZeroValue_TransactionCALL_ToOneStorageKey_OOGRevert.json        Skip
  ZeroValue_TransactionCALLwithData_OOGRevert.json                Skip
  ZeroValue_TransactionCALLwithData_ToEmpty_OOGRevert.json        Skip
  ZeroValue_TransactionCALLwithData_ToNonZeroBalance_OOGRevert.jsonSkip
  ZeroValue_TransactionCALLwithData_ToOneStorageKey_OOGRevert.jsonSkip
```
OK: 0/24 Fail: 0/24 Skip: 24/24
## stZeroCallsTest
```diff
+ ZeroValue_CALL.json                                             OK
+ ZeroValue_CALLCODE.json                                         OK
+ ZeroValue_CALLCODE_ToEmpty.json                                 OK
+ ZeroValue_CALLCODE_ToNonZeroBalance.json                        OK
+ ZeroValue_CALLCODE_ToOneStorageKey.json                         OK
+ ZeroValue_CALL_ToEmpty.json                                     OK
+ ZeroValue_CALL_ToNonZeroBalance.json                            OK
+ ZeroValue_CALL_ToOneStorageKey.json                             OK
+ ZeroValue_DELEGATECALL.json                                     OK
+ ZeroValue_DELEGATECALL_ToEmpty.json                             OK
+ ZeroValue_DELEGATECALL_ToNonZeroBalance.json                    OK
+ ZeroValue_DELEGATECALL_ToOneStorageKey.json                     OK
+ ZeroValue_SUICIDE.json                                          OK
+ ZeroValue_SUICIDE_ToEmpty.json                                  OK
+ ZeroValue_SUICIDE_ToNonZeroBalance.json                         OK
+ ZeroValue_SUICIDE_ToOneStorageKey.json                          OK
+ ZeroValue_TransactionCALL.json                                  OK
+ ZeroValue_TransactionCALL_ToEmpty.json                          OK
+ ZeroValue_TransactionCALL_ToNonZeroBalance.json                 OK
+ ZeroValue_TransactionCALL_ToOneStorageKey.json                  OK
+ ZeroValue_TransactionCALLwithData.json                          OK
+ ZeroValue_TransactionCALLwithData_ToEmpty.json                  OK
+ ZeroValue_TransactionCALLwithData_ToNonZeroBalance.json         OK
+ ZeroValue_TransactionCALLwithData_ToOneStorageKey.json          OK
```
OK: 24/24 Fail: 0/24 Skip: 0/24
## stZeroKnowledge
```diff
  ecmul_1-2_2_28000_128.json                                      Skip
  ecmul_1-2_2_28000_96.json                                       Skip
  ecmul_1-2_340282366920938463463374607431768211456_21000_128.jsonSkip
  ecmul_1-2_340282366920938463463374607431768211456_21000_80.json Skip
  ecmul_1-2_340282366920938463463374607431768211456_21000_96.json Skip
  ecmul_1-2_340282366920938463463374607431768211456_28000_128.jsonSkip
  ecmul_1-2_340282366920938463463374607431768211456_28000_80.json Skip
  ecmul_1-2_340282366920938463463374607431768211456_28000_96.json Skip
  ecmul_1-2_5616_21000_128.json                                   Skip
  ecmul_1-2_5616_21000_96.json                                    Skip
  ecmul_1-2_5616_28000_128.json                                   Skip
  ecmul_1-2_5617_21000_128.json                                   Skip
  ecmul_1-2_5617_21000_96.json                                    Skip
  ecmul_1-2_5617_28000_128.json                                   Skip
  ecmul_1-2_5617_28000_96.json                                    Skip
  ecmul_1-2_616_28000_96.json                                     Skip
  ecmul_1-2_9935_21000_128.json                                   Skip
  ecmul_1-2_9935_21000_96.json                                    Skip
  ecmul_1-2_9935_28000_128.json                                   Skip
  ecmul_1-2_9935_28000_96.json                                    Skip
  ecmul_1-2_9_21000_128.json                                      Skip
  ecmul_1-2_9_21000_96.json                                       Skip
  ecmul_1-2_9_28000_128.json                                      Skip
  ecmul_1-2_9_28000_96.json                                       Skip
  ecmul_1-3_0_21000_128.json                                      Skip
  ecmul_1-3_0_21000_64.json                                       Skip
  ecmul_1-3_0_21000_80.json                                       Skip
  ecmul_1-3_0_21000_96.json                                       Skip
  ecmul_1-3_0_28000_128.json                                      Skip
  ecmul_1-3_0_28000_64.json                                       Skip
  ecmul_1-3_0_28000_80.json                                       Skip
  ecmul_1-3_0_28000_96.json                                       Skip
  ecmul_1-3_1_21000_128.json                                      Skip
  ecmul_1-3_1_21000_96.json                                       Skip
  ecmul_1-3_1_28000_128.json                                      Skip
  ecmul_1-3_1_28000_96.json                                       Skip
  ecmul_1-3_2_21000_128.json                                      Skip
  ecmul_1-3_2_21000_96.json                                       Skip
  ecmul_1-3_2_28000_128.json                                      Skip
  ecmul_1-3_2_28000_96.json                                       Skip
  ecmul_1-3_340282366920938463463374607431768211456_21000_128.jsonSkip
  ecmul_1-3_340282366920938463463374607431768211456_21000_80.json Skip
  ecmul_1-3_340282366920938463463374607431768211456_21000_96.json Skip
  ecmul_1-3_340282366920938463463374607431768211456_28000_128.jsonSkip
  ecmul_1-3_340282366920938463463374607431768211456_28000_80.json Skip
  ecmul_1-3_340282366920938463463374607431768211456_28000_96.json Skip
  ecmul_1-3_5616_21000_128.json                                   Skip
  ecmul_1-3_5616_21000_96.json                                    Skip
  ecmul_1-3_5616_28000_128.json                                   Skip
  ecmul_1-3_5616_28000_96.json                                    Skip
  ecmul_1-3_5617_21000_128.json                                   Skip
  ecmul_1-3_5617_21000_96.json                                    Skip
  ecmul_1-3_5617_28000_128.json                                   Skip
  ecmul_1-3_5617_28000_96.json                                    Skip
  ecmul_1-3_9935_21000_128.json                                   Skip
  ecmul_1-3_9935_21000_96.json                                    Skip
  ecmul_1-3_9935_28000_128.json                                   Skip
  ecmul_1-3_9935_28000_96.json                                    Skip
  ecmul_1-3_9_21000_128.json                                      Skip
  ecmul_1-3_9_21000_96.json                                       Skip
  ecmul_1-3_9_28000_128.json                                      Skip
  ecmul_1-3_9_28000_96.json                                       Skip
  ecmul_7827-6598_0_21000_128.json                                Skip
  ecmul_7827-6598_0_21000_64.json                                 Skip
  ecmul_7827-6598_0_21000_80.json                                 Skip
  ecmul_7827-6598_0_21000_96.json                                 Skip
  ecmul_7827-6598_0_28000_128.json                                Skip
  ecmul_7827-6598_0_28000_64.json                                 Skip
  ecmul_7827-6598_0_28000_80.json                                 Skip
  ecmul_7827-6598_0_28000_96.json                                 Skip
  ecmul_7827-6598_1456_21000_128.json                             Skip
  ecmul_7827-6598_1456_21000_80.json                              Skip
  ecmul_7827-6598_1456_21000_96.json                              Skip
  ecmul_7827-6598_1456_28000_128.json                             Skip
  ecmul_7827-6598_1456_28000_80.json                              Skip
  ecmul_7827-6598_1456_28000_96.json                              Skip
  ecmul_7827-6598_1_21000_128.json                                Skip
  ecmul_7827-6598_1_21000_96.json                                 Skip
  ecmul_7827-6598_1_28000_128.json                                Skip
  ecmul_7827-6598_1_28000_96.json                                 Skip
  ecmul_7827-6598_2_21000_128.json                                Skip
  ecmul_7827-6598_2_21000_96.json                                 Skip
  ecmul_7827-6598_2_28000_128.json                                Skip
  ecmul_7827-6598_2_28000_96.json                                 Skip
  ecmul_7827-6598_5616_21000_128.json                             Skip
  ecmul_7827-6598_5616_21000_96.json                              Skip
  ecmul_7827-6598_5616_28000_128.json                             Skip
  ecmul_7827-6598_5616_28000_96.json                              Skip
  ecmul_7827-6598_5617_21000_128.json                             Skip
  ecmul_7827-6598_5617_21000_96.json                              Skip
  ecmul_7827-6598_5617_28000_128.json                             Skip
  ecmul_7827-6598_5617_28000_96.json                              Skip
  ecmul_7827-6598_9935_21000_128.json                             Skip
  ecmul_7827-6598_9935_21000_96.json                              Skip
  ecmul_7827-6598_9935_28000_128.json                             Skip
  ecmul_7827-6598_9935_28000_96.json                              Skip
  ecmul_7827-6598_9_21000_128.json                                Skip
  ecmul_7827-6598_9_21000_96.json                                 Skip
  ecmul_7827-6598_9_28000_128.json                                Skip
  ecmul_7827-6598_9_28000_96.json                                 Skip
  ecpairing_bad_length_191.json                                   Skip
  ecpairing_bad_length_193.json                                   Skip
  ecpairing_empty_data.json                                       Skip
  ecpairing_empty_data_insufficient_gas.json                      Skip
  ecpairing_one_point_fail.json                                   Skip
  ecpairing_one_point_insufficient_gas.json                       Skip
  ecpairing_one_point_not_in_subgroup.json                        Skip
  ecpairing_one_point_with_g1_zero.json                           Skip
  ecpairing_one_point_with_g2_zero.json                           Skip
  ecpairing_one_point_with_g2_zero_and_g1_invalid.json            Skip
  ecpairing_perturb_g2_by_curve_order.json                        Skip
  ecpairing_perturb_g2_by_field_modulus.json                      Skip
  ecpairing_perturb_g2_by_field_modulus_again.json                Skip
  ecpairing_perturb_g2_by_one.json                                Skip
  ecpairing_perturb_zeropoint_by_curve_order.json                 Skip
  ecpairing_perturb_zeropoint_by_field_modulus.json               Skip
  ecpairing_perturb_zeropoint_by_one.json                         Skip
  ecpairing_three_point_fail_1.json                               Skip
  ecpairing_three_point_match_1.json                              Skip
  ecpairing_two_point_fail_1.json                                 Skip
  ecpairing_two_point_fail_2.json                                 Skip
  ecpairing_two_point_match_1.json                                Skip
  ecpairing_two_point_match_2.json                                Skip
  ecpairing_two_point_match_3.json                                Skip
  ecpairing_two_point_match_4.json                                Skip
  ecpairing_two_point_match_5.json                                Skip
  ecpairing_two_point_oog.json                                    Skip
  ecpairing_two_points_with_one_g2_zero.json                      Skip
  pairingTest.json                                                Skip
  pointAdd.json                                                   Skip
  pointAddTrunc.json                                              Skip
  pointMulAdd.json                                                Skip
  pointMulAdd2.json                                               Skip
```
OK: 0/133 Fail: 0/133 Skip: 133/133
## stZeroKnowledge2
```diff
  ecadd_0-0_0-0_21000_0.json                                      Skip
  ecadd_0-0_0-0_21000_128.json                                    Skip
  ecadd_0-0_0-0_21000_192.json                                    Skip
  ecadd_0-0_0-0_21000_64.json                                     Skip
  ecadd_0-0_0-0_21000_80.json                                     Skip
  ecadd_0-0_0-0_25000_0.json                                      Skip
  ecadd_0-0_0-0_25000_128.json                                    Skip
  ecadd_0-0_0-0_25000_192.json                                    Skip
  ecadd_0-0_0-0_25000_64.json                                     Skip
  ecadd_0-0_0-0_25000_80.json                                     Skip
  ecadd_0-0_1-2_21000_128.json                                    Skip
  ecadd_0-0_1-2_21000_192.json                                    Skip
  ecadd_0-0_1-2_25000_128.json                                    Skip
  ecadd_0-0_1-2_25000_192.json                                    Skip
  ecadd_0-0_1-3_21000_128.json                                    Skip
  ecadd_0-0_1-3_25000_128.json                                    Skip
  ecadd_0-3_1-2_21000_128.json                                    Skip
  ecadd_0-3_1-2_25000_128.json                                    Skip
  ecadd_1-2_0-0_21000_128.json                                    Skip
  ecadd_1-2_0-0_21000_192.json                                    Skip
  ecadd_1-2_0-0_21000_64.json                                     Skip
  ecadd_1-2_0-0_25000_128.json                                    Skip
  ecadd_1-2_0-0_25000_192.json                                    Skip
  ecadd_1-2_0-0_25000_64.json                                     Skip
  ecadd_1-2_1-2_21000_128.json                                    Skip
  ecadd_1-2_1-2_21000_192.json                                    Skip
  ecadd_1-2_1-2_25000_128.json                                    Skip
  ecadd_1-2_1-2_25000_192.json                                    Skip
  ecadd_1-3_0-0_21000_80.json                                     Skip
  ecadd_1-3_0-0_25000_80.json                                     Skip
  ecadd_1145-3932_1145-4651_21000_192.json                        Skip
  ecadd_1145-3932_1145-4651_25000_192.json                        Skip
  ecadd_1145-3932_2969-1336_21000_128.json                        Skip
  ecadd_1145-3932_2969-1336_25000_128.json                        Skip
  ecadd_6-9_19274124-124124_21000_128.json                        Skip
  ecadd_6-9_19274124-124124_25000_128.json                        Skip
  ecmul_0-0_0_21000_0.json                                        Skip
  ecmul_0-0_0_21000_128.json                                      Skip
  ecmul_0-0_0_21000_40.json                                       Skip
  ecmul_0-0_0_21000_64.json                                       Skip
  ecmul_0-0_0_21000_80.json                                       Skip
  ecmul_0-0_0_21000_96.json                                       Skip
  ecmul_0-0_0_28000_0.json                                        Skip
  ecmul_0-0_0_28000_128.json                                      Skip
  ecmul_0-0_0_28000_40.json                                       Skip
  ecmul_0-0_0_28000_64.json                                       Skip
  ecmul_0-0_0_28000_80.json                                       Skip
  ecmul_0-0_0_28000_96.json                                       Skip
  ecmul_0-0_1_21000_128.json                                      Skip
  ecmul_0-0_1_21000_96.json                                       Skip
  ecmul_0-0_1_28000_128.json                                      Skip
  ecmul_0-0_1_28000_96.json                                       Skip
  ecmul_0-0_2_21000_128.json                                      Skip
  ecmul_0-0_2_21000_96.json                                       Skip
  ecmul_0-0_2_28000_128.json                                      Skip
  ecmul_0-0_2_28000_96.json                                       Skip
  ecmul_0-0_340282366920938463463374607431768211456_21000_128.jsonSkip
  ecmul_0-0_340282366920938463463374607431768211456_21000_80.json Skip
  ecmul_0-0_340282366920938463463374607431768211456_21000_96.json Skip
  ecmul_0-0_340282366920938463463374607431768211456_28000_128.jsonSkip
  ecmul_0-0_340282366920938463463374607431768211456_28000_80.json Skip
  ecmul_0-0_340282366920938463463374607431768211456_28000_96.json Skip
  ecmul_0-0_5616_21000_128.json                                   Skip
  ecmul_0-0_5616_21000_96.json                                    Skip
  ecmul_0-0_5616_28000_128.json                                   Skip
  ecmul_0-0_5616_28000_96.json                                    Skip
  ecmul_0-0_5617_21000_128.json                                   Skip
  ecmul_0-0_5617_21000_96.json                                    Skip
  ecmul_0-0_5617_28000_128.json                                   Skip
  ecmul_0-0_5617_28000_96.json                                    Skip
  ecmul_0-0_9935_21000_128.json                                   Skip
  ecmul_0-0_9935_21000_96.json                                    Skip
  ecmul_0-0_9935_28000_128.json                                   Skip
  ecmul_0-0_9935_28000_96.json                                    Skip
  ecmul_0-0_9_21000_128.json                                      Skip
  ecmul_0-0_9_21000_96.json                                       Skip
  ecmul_0-0_9_28000_128.json                                      Skip
  ecmul_0-0_9_28000_96.json                                       Skip
  ecmul_0-3_0_21000_128.json                                      Skip
  ecmul_0-3_0_21000_64.json                                       Skip
  ecmul_0-3_0_21000_80.json                                       Skip
  ecmul_0-3_0_21000_96.json                                       Skip
  ecmul_0-3_0_28000_128.json                                      Skip
  ecmul_0-3_0_28000_64.json                                       Skip
  ecmul_0-3_0_28000_80.json                                       Skip
  ecmul_0-3_0_28000_96.json                                       Skip
  ecmul_0-3_1_21000_128.json                                      Skip
  ecmul_0-3_1_21000_96.json                                       Skip
  ecmul_0-3_1_28000_128.json                                      Skip
  ecmul_0-3_1_28000_96.json                                       Skip
  ecmul_0-3_2_21000_128.json                                      Skip
  ecmul_0-3_2_21000_96.json                                       Skip
  ecmul_0-3_2_28000_128.json                                      Skip
  ecmul_0-3_2_28000_96.json                                       Skip
  ecmul_0-3_340282366920938463463374607431768211456_21000_128.jsonSkip
  ecmul_0-3_340282366920938463463374607431768211456_21000_80.json Skip
  ecmul_0-3_340282366920938463463374607431768211456_21000_96.json Skip
  ecmul_0-3_340282366920938463463374607431768211456_28000_128.jsonSkip
  ecmul_0-3_340282366920938463463374607431768211456_28000_80.json Skip
  ecmul_0-3_340282366920938463463374607431768211456_28000_96.json Skip
  ecmul_0-3_5616_21000_128.json                                   Skip
  ecmul_0-3_5616_21000_96.json                                    Skip
  ecmul_0-3_5616_28000_128.json                                   Skip
  ecmul_0-3_5616_28000_96.json                                    Skip
  ecmul_0-3_5617_21000_128.json                                   Skip
  ecmul_0-3_5617_21000_96.json                                    Skip
  ecmul_0-3_5617_28000_128.json                                   Skip
  ecmul_0-3_5617_28000_96.json                                    Skip
  ecmul_0-3_9935_21000_128.json                                   Skip
  ecmul_0-3_9935_21000_96.json                                    Skip
  ecmul_0-3_9935_28000_128.json                                   Skip
  ecmul_0-3_9935_28000_96.json                                    Skip
  ecmul_0-3_9_21000_128.json                                      Skip
  ecmul_0-3_9_21000_96.json                                       Skip
  ecmul_0-3_9_28000_128.json                                      Skip
  ecmul_0-3_9_28000_96.json                                       Skip
  ecmul_1-2_0_21000_128.json                                      Skip
  ecmul_1-2_0_21000_64.json                                       Skip
  ecmul_1-2_0_21000_80.json                                       Skip
  ecmul_1-2_0_21000_96.json                                       Skip
  ecmul_1-2_0_28000_128.json                                      Skip
  ecmul_1-2_0_28000_64.json                                       Skip
  ecmul_1-2_0_28000_80.json                                       Skip
  ecmul_1-2_0_28000_96.json                                       Skip
  ecmul_1-2_1_21000_128.json                                      Skip
  ecmul_1-2_1_21000_96.json                                       Skip
  ecmul_1-2_1_28000_128.json                                      Skip
  ecmul_1-2_1_28000_96.json                                       Skip
  ecmul_1-2_2_21000_128.json                                      Skip
  ecmul_1-2_2_21000_96.json                                       Skip
```
OK: 0/130 Fail: 0/130 Skip: 130/130

---TOTAL---
OK: 1180/2334 Fail: 0/2334 Skip: 1154/2334
