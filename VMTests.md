VMTests
===
## vmArithmeticTest
```diff
- add0.json                                                       Fail
- add1.json                                                       Fail
+ add2.json                                                       OK
+ add3.json                                                       OK
+ add4.json                                                       OK
- addmod0.json                                                    Fail
- addmod1.json                                                    Fail
+ addmod1_overflow2.json                                          OK
+ addmod1_overflow3.json                                          OK
- addmod1_overflow4.json                                          Fail
- addmod1_overflowDiff.json                                       Fail
- addmod2.json                                                    Fail
+ addmod2_0.json                                                  OK
- addmod2_1.json                                                  Fail
- addmod3.json                                                    Fail
+ addmod3_0.json                                                  OK
+ addmodBigIntCast.json                                           OK
+ addmodDivByZero.json                                            OK
+ addmodDivByZero1.json                                           OK
+ addmodDivByZero2.json                                           OK
- addmodDivByZero3.json                                           Fail
  arith1.json                                                     Skip
+ div1.json                                                       OK
- divBoostBug.json                                                Fail
- divByNonZero0.json                                              Fail
+ divByNonZero1.json                                              OK
+ divByNonZero2.json                                              OK
- divByNonZero3.json                                              Fail
+ divByZero.json                                                  OK
- divByZero_2.json                                                Fail
- exp0.json                                                       Fail
- exp1.json                                                       Fail
- exp2.json                                                       Fail
- exp3.json                                                       Fail
- exp4.json                                                       Fail
- exp5.json                                                       Fail
- exp6.json                                                       Fail
- exp7.json                                                       Fail
- expPowerOf256Of256_0.json                                       Fail
- expPowerOf256Of256_1.json                                       Fail
- expPowerOf256Of256_10.json                                      Fail
- expPowerOf256Of256_11.json                                      Fail
- expPowerOf256Of256_12.json                                      Fail
- expPowerOf256Of256_13.json                                      Fail
- expPowerOf256Of256_14.json                                      Fail
- expPowerOf256Of256_15.json                                      Fail
- expPowerOf256Of256_16.json                                      Fail
- expPowerOf256Of256_17.json                                      Fail
- expPowerOf256Of256_18.json                                      Fail
- expPowerOf256Of256_19.json                                      Fail
- expPowerOf256Of256_2.json                                       Fail
- expPowerOf256Of256_20.json                                      Fail
- expPowerOf256Of256_21.json                                      Fail
- expPowerOf256Of256_22.json                                      Fail
- expPowerOf256Of256_23.json                                      Fail
- expPowerOf256Of256_24.json                                      Fail
- expPowerOf256Of256_25.json                                      Fail
- expPowerOf256Of256_26.json                                      Fail
- expPowerOf256Of256_27.json                                      Fail
- expPowerOf256Of256_28.json                                      Fail
- expPowerOf256Of256_29.json                                      Fail
- expPowerOf256Of256_3.json                                       Fail
- expPowerOf256Of256_30.json                                      Fail
- expPowerOf256Of256_31.json                                      Fail
- expPowerOf256Of256_32.json                                      Fail
- expPowerOf256Of256_33.json                                      Fail
- expPowerOf256Of256_4.json                                       Fail
- expPowerOf256Of256_5.json                                       Fail
- expPowerOf256Of256_6.json                                       Fail
- expPowerOf256Of256_7.json                                       Fail
- expPowerOf256Of256_8.json                                       Fail
- expPowerOf256Of256_9.json                                       Fail
- expPowerOf256_1.json                                            Fail
- expPowerOf256_10.json                                           Fail
- expPowerOf256_11.json                                           Fail
- expPowerOf256_12.json                                           Fail
- expPowerOf256_13.json                                           Fail
- expPowerOf256_14.json                                           Fail
- expPowerOf256_15.json                                           Fail
- expPowerOf256_16.json                                           Fail
- expPowerOf256_17.json                                           Fail
- expPowerOf256_18.json                                           Fail
- expPowerOf256_19.json                                           Fail
- expPowerOf256_2.json                                            Fail
- expPowerOf256_20.json                                           Fail
- expPowerOf256_21.json                                           Fail
- expPowerOf256_22.json                                           Fail
- expPowerOf256_23.json                                           Fail
- expPowerOf256_24.json                                           Fail
- expPowerOf256_25.json                                           Fail
- expPowerOf256_26.json                                           Fail
- expPowerOf256_27.json                                           Fail
- expPowerOf256_28.json                                           Fail
- expPowerOf256_29.json                                           Fail
- expPowerOf256_3.json                                            Fail
- expPowerOf256_30.json                                           Fail
- expPowerOf256_31.json                                           Fail
- expPowerOf256_32.json                                           Fail
- expPowerOf256_33.json                                           Fail
- expPowerOf256_4.json                                            Fail
- expPowerOf256_5.json                                            Fail
- expPowerOf256_6.json                                            Fail
- expPowerOf256_7.json                                            Fail
- expPowerOf256_8.json                                            Fail
- expPowerOf256_9.json                                            Fail
- expPowerOf2_128.json                                            Fail
- expPowerOf2_16.json                                             Fail
- expPowerOf2_2.json                                              Fail
- expPowerOf2_256.json                                            Fail
- expPowerOf2_32.json                                             Fail
- expPowerOf2_4.json                                              Fail
- expPowerOf2_64.json                                             Fail
- expPowerOf2_8.json                                              Fail
- expXY.json                                                      Fail
- expXY_success.json                                              Fail
+ fibbonacci_unrolled.json                                        OK
- mod0.json                                                       Fail
- mod1.json                                                       Fail
+ mod2.json                                                       OK
+ mod3.json                                                       OK
- mod4.json                                                       Fail
- modByZero.json                                                  Fail
- mul0.json                                                       Fail
- mul1.json                                                       Fail
+ mul2.json                                                       OK
- mul3.json                                                       Fail
- mul4.json                                                       Fail
+ mul5.json                                                       OK
- mul6.json                                                       Fail
+ mul7.json                                                       OK
- mulUnderFlow.json                                               Fail
+ mulmod0.json                                                    OK
- mulmod1.json                                                    Fail
- mulmod1_overflow.json                                           Fail
+ mulmod1_overflow2.json                                          OK
- mulmod1_overflow3.json                                          Fail
- mulmod1_overflow4.json                                          Fail
- mulmod2.json                                                    Fail
+ mulmod2_0.json                                                  OK
- mulmod2_1.json                                                  Fail
- mulmod3.json                                                    Fail
+ mulmod3_0.json                                                  OK
- mulmod4.json                                                    Fail
+ mulmoddivByZero.json                                            OK
+ mulmoddivByZero1.json                                           OK
+ mulmoddivByZero2.json                                           OK
- mulmoddivByZero3.json                                           Fail
+ not1.json                                                       OK
+ sdiv0.json                                                      OK
+ sdiv1.json                                                      OK
+ sdiv2.json                                                      OK
+ sdiv3.json                                                      OK
+ sdiv4.json                                                      OK
+ sdiv5.json                                                      OK
+ sdiv6.json                                                      OK
+ sdiv7.json                                                      OK
+ sdiv8.json                                                      OK
+ sdiv9.json                                                      OK
+ sdivByZero0.json                                                OK
+ sdivByZero1.json                                                OK
- sdivByZero2.json                                                Fail
- sdiv_dejavu.json                                                Fail
+ sdiv_i256min.json                                               OK
+ sdiv_i256min2.json                                              OK
+ sdiv_i256min3.json                                              OK
- signextendInvalidByteNumber.json                                Fail
+ signextend_00.json                                              OK
- signextend_0_BigByte.json                                       Fail
- signextend_AlmostBiggestByte.json                               Fail
- signextend_BigByteBigByte.json                                  Fail
- signextend_BigBytePlus1_2.json                                  Fail
+ signextend_BigByte_0.json                                       OK
- signextend_BitIsNotSet.json                                     Fail
- signextend_BitIsNotSetInHigherByte.json                         Fail
- signextend_BitIsSetInHigherByte.json                            Fail
- signextend_Overflow_dj42.json                                   Fail
- signextend_bigBytePlus1.json                                    Fail
- signextend_bitIsSet.json                                        Fail
+ smod0.json                                                      OK
+ smod1.json                                                      OK
+ smod2.json                                                      OK
+ smod3.json                                                      OK
+ smod4.json                                                      OK
+ smod5.json                                                      OK
+ smod6.json                                                      OK
+ smod7.json                                                      OK
- smod8_byZero.json                                               Fail
+ smod_i256min1.json                                              OK
- smod_i256min2.json                                              Fail
+ stop.json                                                       OK
- sub0.json                                                       Fail
- sub1.json                                                       Fail
- sub2.json                                                       Fail
- sub3.json                                                       Fail
- sub4.json                                                       Fail
```
OK: 56/195 Fail: 138/195 Skip: 1/195
## vmBitwiseLogicOperation
```diff
- and0.json                                                       Fail
+ and1.json                                                       OK
- and2.json                                                       Fail
- and3.json                                                       Fail
- and4.json                                                       Fail
- and5.json                                                       Fail
- byte0.json                                                      Fail
- byte1.json                                                      Fail
- byte10.json                                                     Fail
- byte11.json                                                     Fail
- byte2.json                                                      Fail
- byte3.json                                                      Fail
- byte4.json                                                      Fail
- byte5.json                                                      Fail
- byte6.json                                                      Fail
- byte7.json                                                      Fail
- byte8.json                                                      Fail
- byte9.json                                                      Fail
+ eq0.json                                                        OK
- eq1.json                                                        Fail
- eq2.json                                                        Fail
- gt0.json                                                        Fail
+ gt1.json                                                        OK
- gt2.json                                                        Fail
+ gt3.json                                                        OK
+ iszeo2.json                                                     OK
+ iszero0.json                                                    OK
- iszero1.json                                                    Fail
+ lt0.json                                                        OK
- lt1.json                                                        Fail
+ lt2.json                                                        OK
- lt3.json                                                        Fail
- not0.json                                                       Fail
- not1.json                                                       Fail
+ not2.json                                                       OK
- not3.json                                                       Fail
- not4.json                                                       Fail
- not5.json                                                       Fail
- or0.json                                                        Fail
- or1.json                                                        Fail
- or2.json                                                        Fail
- or3.json                                                        Fail
- or4.json                                                        Fail
- or5.json                                                        Fail
+ sgt0.json                                                       OK
+ sgt1.json                                                       OK
+ sgt2.json                                                       OK
+ sgt3.json                                                       OK
+ sgt4.json                                                       OK
+ slt0.json                                                       OK
+ slt1.json                                                       OK
+ slt2.json                                                       OK
+ slt3.json                                                       OK
+ slt4.json                                                       OK
+ xor0.json                                                       OK
- xor1.json                                                       Fail
- xor2.json                                                       Fail
- xor3.json                                                       Fail
- xor4.json                                                       Fail
- xor5.json                                                       Fail
```
OK: 20/60 Fail: 40/60 Skip: 0/60
## vmBlockInfoTest
```diff
- blockhash257Block.json                                          Fail
- blockhash258Block.json                                          Fail
- blockhashInRange.json                                           Fail
- blockhashMyBlock.json                                           Fail
- blockhashNotExistingBlock.json                                  Fail
- blockhashOutOfRange.json                                        Fail
+ blockhashUnderFlow.json                                         OK
- coinbase.json                                                   Fail
+ difficulty.json                                                 OK
+ gaslimit.json                                                   OK
+ number.json                                                     OK
+ timestamp.json                                                  OK
```
OK: 5/12 Fail: 7/12 Skip: 0/12
## vmEnvironmentalInfo
```diff
  ExtCodeSizeAddressInputTooBigLeftMyAddress.json                 Skip
  ExtCodeSizeAddressInputTooBigRightMyAddress.json                Skip
  address0.json                                                   Skip
  address1.json                                                   Skip
  balance0.json                                                   Skip
  balance01.json                                                  Skip
  balance1.json                                                   Skip
  balanceAddress2.json                                            Skip
  balanceAddressInputTooBig.json                                  Skip
  balanceAddressInputTooBigLeftMyAddress.json                     Skip
  balanceAddressInputTooBigRightMyAddress.json                    Skip
  balanceCaller3.json                                             Skip
  calldatacopy0.json                                              Skip
  calldatacopy0_return.json                                       Skip
  calldatacopy1.json                                              Skip
  calldatacopy1_return.json                                       Skip
  calldatacopy2.json                                              Skip
  calldatacopy2_return.json                                       Skip
  calldatacopyUnderFlow.json                                      Skip
  calldatacopyZeroMemExpansion.json                               Skip
  calldatacopyZeroMemExpansion_return.json                        Skip
  calldatacopy_DataIndexTooHigh.json                              Skip
  calldatacopy_DataIndexTooHigh2.json                             Skip
  calldatacopy_DataIndexTooHigh2_return.json                      Skip
  calldatacopy_DataIndexTooHigh_return.json                       Skip
  calldatacopy_sec.json                                           Skip
  calldataload0.json                                              Skip
  calldataload1.json                                              Skip
  calldataload2.json                                              Skip
  calldataloadSizeTooHigh.json                                    Skip
  calldataloadSizeTooHighPartial.json                             Skip
  calldataload_BigOffset.json                                     Skip
  calldatasize0.json                                              Skip
  calldatasize1.json                                              Skip
  calldatasize2.json                                              Skip
  caller.json                                                     Skip
  callvalue.json                                                  Skip
  codecopy0.json                                                  Skip
  codecopyZeroMemExpansion.json                                   Skip
  codecopy_DataIndexTooHigh.json                                  Skip
  codesize.json                                                   Skip
  env1.json                                                       Skip
  extcodecopy0.json                                               Skip
  extcodecopy0AddressTooBigLeft.json                              Skip
  extcodecopy0AddressTooBigRight.json                             Skip
  extcodecopyZeroMemExpansion.json                                Skip
  extcodecopy_DataIndexTooHigh.json                               Skip
  extcodesize0.json                                               Skip
  extcodesize1.json                                               Skip
  extcodesizeUnderFlow.json                                       Skip
  gasprice.json                                                   Skip
  origin.json                                                     Skip
```
OK: 0/52 Fail: 0/52 Skip: 52/52
## vmIOandFlowOperations
```diff
  BlockNumberDynamicJump0_AfterJumpdest.json                      Skip
  BlockNumberDynamicJump0_AfterJumpdest3.json                     Skip
  BlockNumberDynamicJump0_foreverOutOfGas.json                    Skip
  BlockNumberDynamicJump0_jumpdest0.json                          Skip
  BlockNumberDynamicJump0_jumpdest2.json                          Skip
  BlockNumberDynamicJump0_withoutJumpdest.json                    Skip
  BlockNumberDynamicJump1.json                                    Skip
  BlockNumberDynamicJumpInsidePushWithJumpDest.json               Skip
  BlockNumberDynamicJumpInsidePushWithoutJumpDest.json            Skip
  BlockNumberDynamicJumpi0.json                                   Skip
  BlockNumberDynamicJumpi1.json                                   Skip
  BlockNumberDynamicJumpi1_jumpdest.json                          Skip
  BlockNumberDynamicJumpiAfterStop.json                           Skip
  BlockNumberDynamicJumpiOutsideBoundary.json                     Skip
  BlockNumberDynamicJumpifInsidePushWithJumpDest.json             Skip
  BlockNumberDynamicJumpifInsidePushWithoutJumpDest.json          Skip
  DyanmicJump0_outOfBoundary.json                                 Skip
  DynamicJump0_AfterJumpdest.json                                 Skip
  DynamicJump0_AfterJumpdest3.json                                Skip
  DynamicJump0_foreverOutOfGas.json                               Skip
  DynamicJump0_jumpdest0.json                                     Skip
  DynamicJump0_jumpdest2.json                                     Skip
  DynamicJump0_withoutJumpdest.json                               Skip
  DynamicJump1.json                                               Skip
  DynamicJumpAfterStop.json                                       Skip
  DynamicJumpInsidePushWithJumpDest.json                          Skip
  DynamicJumpInsidePushWithoutJumpDest.json                       Skip
  DynamicJumpJD_DependsOnJumps0.json                              Skip
  DynamicJumpJD_DependsOnJumps1.json                              Skip
  DynamicJumpPathologicalTest0.json                               Skip
  DynamicJumpPathologicalTest1.json                               Skip
  DynamicJumpPathologicalTest2.json                               Skip
  DynamicJumpPathologicalTest3.json                               Skip
  DynamicJumpStartWithJumpDest.json                               Skip
  DynamicJump_value1.json                                         Skip
  DynamicJump_value2.json                                         Skip
  DynamicJump_value3.json                                         Skip
  DynamicJump_valueUnderflow.json                                 Skip
  DynamicJumpi0.json                                              Skip
  DynamicJumpi1.json                                              Skip
  DynamicJumpi1_jumpdest.json                                     Skip
  DynamicJumpiAfterStop.json                                      Skip
  DynamicJumpiOutsideBoundary.json                                Skip
  DynamicJumpifInsidePushWithJumpDest.json                        Skip
  DynamicJumpifInsidePushWithoutJumpDest.json                     Skip
  JDfromStorageDynamicJump0_AfterJumpdest.json                    Skip
  JDfromStorageDynamicJump0_AfterJumpdest3.json                   Skip
  JDfromStorageDynamicJump0_foreverOutOfGas.json                  Skip
  JDfromStorageDynamicJump0_jumpdest0.json                        Skip
  JDfromStorageDynamicJump0_jumpdest2.json                        Skip
  JDfromStorageDynamicJump0_withoutJumpdest.json                  Skip
  JDfromStorageDynamicJump1.json                                  Skip
  JDfromStorageDynamicJumpInsidePushWithJumpDest.json             Skip
  JDfromStorageDynamicJumpInsidePushWithoutJumpDest.json          Skip
  JDfromStorageDynamicJumpi0.json                                 Skip
  JDfromStorageDynamicJumpi1.json                                 Skip
  JDfromStorageDynamicJumpi1_jumpdest.json                        Skip
  JDfromStorageDynamicJumpiAfterStop.json                         Skip
  JDfromStorageDynamicJumpiOutsideBoundary.json                   Skip
  JDfromStorageDynamicJumpifInsidePushWithJumpDest.json           Skip
  JDfromStorageDynamicJumpifInsidePushWithoutJumpDest.json        Skip
  bad_indirect_jump1.json                                         Skip
  bad_indirect_jump2.json                                         Skip
  byte1.json                                                      Skip
  calldatacopyMemExp.json                                         Skip
  codecopyMemExp.json                                             Skip
  deadCode_1.json                                                 Skip
  dupAt51becameMload.json                                         Skip
  extcodecopyMemExp.json                                          Skip
  for_loop1.json                                                  Skip
  for_loop2.json                                                  Skip
  gas0.json                                                       Skip
  gas1.json                                                       Skip
  gasOverFlow.json                                                Skip
  indirect_jump1.json                                             Skip
  indirect_jump2.json                                             Skip
  indirect_jump3.json                                             Skip
  indirect_jump4.json                                             Skip
  jump0_AfterJumpdest.json                                        Skip
  jump0_AfterJumpdest3.json                                       Skip
  jump0_foreverOutOfGas.json                                      Skip
  jump0_jumpdest0.json                                            Skip
  jump0_jumpdest2.json                                            Skip
  jump0_outOfBoundary.json                                        Skip
  jump0_withoutJumpdest.json                                      Skip
  jump1.json                                                      Skip
  jumpAfterStop.json                                              Skip
  jumpDynamicJumpSameDest.json                                    Skip
  jumpHigh.json                                                   Skip
  jumpInsidePushWithJumpDest.json                                 Skip
  jumpInsidePushWithoutJumpDest.json                              Skip
  jumpOntoJump.json                                               Skip
  jumpTo1InstructionafterJump.json                                Skip
  jumpTo1InstructionafterJump_jumpdestFirstInstruction.json       Skip
  jumpTo1InstructionafterJump_noJumpDest.json                     Skip
  jumpToUint64maxPlus1.json                                       Skip
  jumpToUintmaxPlus1.json                                         Skip
  jumpdestBigList.json                                            Skip
  jumpi0.json                                                     Skip
  jumpi1.json                                                     Skip
  jumpi1_jumpdest.json                                            Skip
  jumpiAfterStop.json                                             Skip
  jumpiOutsideBoundary.json                                       Skip
  jumpiToUint64maxPlus1.json                                      Skip
  jumpiToUintmaxPlus1.json                                        Skip
  jumpi_at_the_end.json                                           Skip
  jumpifInsidePushWithJumpDest.json                               Skip
  jumpifInsidePushWithoutJumpDest.json                            Skip
  kv1.json                                                        Skip
  log1MemExp.json                                                 Skip
  loop_stacklimit_1020.json                                       Skip
  loop_stacklimit_1021.json                                       Skip
  memory1.json                                                    Skip
  mloadError0.json                                                Skip
  mloadError1.json                                                Skip
  mloadMemExp.json                                                Skip
  mloadOutOfGasError2.json                                        Skip
  msize0.json                                                     Skip
  msize1.json                                                     Skip
  msize2.json                                                     Skip
  msize3.json                                                     Skip
  mstore0.json                                                    Skip
  mstore1.json                                                    Skip
  mstore8MemExp.json                                              Skip
  mstore8WordToBigError.json                                      Skip
  mstore8_0.json                                                  Skip
  mstore8_1.json                                                  Skip
  mstoreMemExp.json                                               Skip
  mstoreWordToBigError.json                                       Skip
  mstore_mload0.json                                              Skip
  pc0.json                                                        Skip
  pc1.json                                                        Skip
  pop0.json                                                       Skip
  pop1.json                                                       Skip
  return1.json                                                    Skip
  return2.json                                                    Skip
  sha3MemExp.json                                                 Skip
  sstore_load_0.json                                              Skip
  sstore_load_1.json                                              Skip
  sstore_load_2.json                                              Skip
  sstore_underflow.json                                           Skip
  stack_loop.json                                                 Skip
  stackjump1.json                                                 Skip
  swapAt52becameMstore.json                                       Skip
  when.json                                                       Skip
```
OK: 0/145 Fail: 0/145 Skip: 145/145
## vmLogTest
```diff
  log0_emptyMem.json                                              Skip
  log0_logMemStartTooHigh.json                                    Skip
  log0_logMemsizeTooHigh.json                                     Skip
  log0_logMemsizeZero.json                                        Skip
  log0_nonEmptyMem.json                                           Skip
  log0_nonEmptyMem_logMemSize1.json                               Skip
  log0_nonEmptyMem_logMemSize1_logMemStart31.json                 Skip
  log1_Caller.json                                                Skip
  log1_MaxTopic.json                                              Skip
  log1_emptyMem.json                                              Skip
  log1_logMemStartTooHigh.json                                    Skip
  log1_logMemsizeTooHigh.json                                     Skip
  log1_logMemsizeZero.json                                        Skip
  log1_nonEmptyMem.json                                           Skip
  log1_nonEmptyMem_logMemSize1.json                               Skip
  log1_nonEmptyMem_logMemSize1_logMemStart31.json                 Skip
  log2_Caller.json                                                Skip
  log2_MaxTopic.json                                              Skip
  log2_emptyMem.json                                              Skip
  log2_logMemStartTooHigh.json                                    Skip
  log2_logMemsizeTooHigh.json                                     Skip
  log2_logMemsizeZero.json                                        Skip
  log2_nonEmptyMem.json                                           Skip
  log2_nonEmptyMem_logMemSize1.json                               Skip
  log2_nonEmptyMem_logMemSize1_logMemStart31.json                 Skip
  log3_Caller.json                                                Skip
  log3_MaxTopic.json                                              Skip
  log3_PC.json                                                    Skip
  log3_emptyMem.json                                              Skip
  log3_logMemStartTooHigh.json                                    Skip
  log3_logMemsizeTooHigh.json                                     Skip
  log3_logMemsizeZero.json                                        Skip
  log3_nonEmptyMem.json                                           Skip
  log3_nonEmptyMem_logMemSize1.json                               Skip
  log3_nonEmptyMem_logMemSize1_logMemStart31.json                 Skip
  log4_Caller.json                                                Skip
  log4_MaxTopic.json                                              Skip
  log4_PC.json                                                    Skip
  log4_emptyMem.json                                              Skip
  log4_logMemStartTooHigh.json                                    Skip
  log4_logMemsizeTooHigh.json                                     Skip
  log4_logMemsizeZero.json                                        Skip
  log4_nonEmptyMem.json                                           Skip
  log4_nonEmptyMem_logMemSize1.json                               Skip
  log4_nonEmptyMem_logMemSize1_logMemStart31.json                 Skip
  log_2logs.json                                                  Skip
```
OK: 0/46 Fail: 0/46 Skip: 46/46
## vmPerformance
```diff
  ackermann31.json                                                Skip
  ackermann32.json                                                Skip
  ackermann33.json                                                Skip
  fibonacci10.json                                                Skip
  fibonacci16.json                                                Skip
  loop-add-10M.json                                               Skip
  loop-divadd-10M.json                                            Skip
  loop-divadd-unr100-10M.json                                     Skip
  loop-exp-16b-100k.json                                          Skip
  loop-exp-1b-1M.json                                             Skip
  loop-exp-2b-100k.json                                           Skip
  loop-exp-32b-100k.json                                          Skip
  loop-exp-4b-100k.json                                           Skip
  loop-exp-8b-100k.json                                           Skip
  loop-exp-nop-1M.json                                            Skip
  loop-mul.json                                                   Skip
  loop-mulmod-2M.json                                             Skip
  manyFunctions100.json                                           Skip
```
OK: 0/18 Fail: 0/18 Skip: 18/18
## vmPushDupSwapTest
```diff
- dup1.json                                                       Fail
- dup10.json                                                      Fail
- dup11.json                                                      Fail
- dup12.json                                                      Fail
- dup13.json                                                      Fail
- dup14.json                                                      Fail
- dup15.json                                                      Fail
- dup16.json                                                      Fail
- dup2.json                                                       Fail
+ dup2error.json                                                  OK
- dup3.json                                                       Fail
- dup4.json                                                       Fail
- dup5.json                                                       Fail
- dup6.json                                                       Fail
- dup7.json                                                       Fail
- dup8.json                                                       Fail
- dup9.json                                                       Fail
- push1.json                                                      Fail
- push10.json                                                     Fail
- push11.json                                                     Fail
- push12.json                                                     Fail
- push13.json                                                     Fail
- push14.json                                                     Fail
- push15.json                                                     Fail
- push16.json                                                     Fail
- push17.json                                                     Fail
- push18.json                                                     Fail
- push19.json                                                     Fail
+ push1_missingStack.json                                         OK
- push2.json                                                      Fail
- push20.json                                                     Fail
- push21.json                                                     Fail
- push22.json                                                     Fail
- push23.json                                                     Fail
- push24.json                                                     Fail
- push25.json                                                     Fail
- push26.json                                                     Fail
- push27.json                                                     Fail
- push28.json                                                     Fail
- push29.json                                                     Fail
- push3.json                                                      Fail
- push30.json                                                     Fail
- push31.json                                                     Fail
- push32.json                                                     Fail
+ push32AndSuicide.json                                           OK
+ push32FillUpInputWithZerosAtTheEnd.json                         OK
+ push32Undefined.json                                            OK
- push32Undefined2.json                                           Fail
+ push32Undefined3.json                                           OK
+ push33.json                                                     OK
- push4.json                                                      Fail
- push5.json                                                      Fail
- push6.json                                                      Fail
- push7.json                                                      Fail
- push8.json                                                      Fail
- push9.json                                                      Fail
- swap1.json                                                      Fail
- swap10.json                                                     Fail
- swap11.json                                                     Fail
- swap12.json                                                     Fail
- swap13.json                                                     Fail
- swap14.json                                                     Fail
- swap15.json                                                     Fail
- swap16.json                                                     Fail
- swap2.json                                                      Fail
+ swap2error.json                                                 OK
- swap3.json                                                      Fail
- swap4.json                                                      Fail
- swap5.json                                                      Fail
- swap6.json                                                      Fail
- swap7.json                                                      Fail
- swap8.json                                                      Fail
- swap9.json                                                      Fail
+ swapjump1.json                                                  OK
```
OK: 9/74 Fail: 65/74 Skip: 0/74
## vmRandomTest
```diff
  201503102037PYTHON.json                                         Skip
  201503102148PYTHON.json                                         Skip
  201503102300PYTHON.json                                         Skip
  201503102320PYTHON.json                                         Skip
  201503110050PYTHON.json                                         Skip
  201503110206PYTHON.json                                         Skip
  201503110219PYTHON.json                                         Skip
  201503110226PYTHON_DUP6.json                                    Skip
  201503110346PYTHON_PUSH24.json                                  Skip
  201503110526PYTHON.json                                         Skip
  201503111844PYTHON.json                                         Skip
  201503112218PYTHON.json                                         Skip
  201503120317PYTHON.json                                         Skip
  201503120525PYTHON.json                                         Skip
  201503120547PYTHON.json                                         Skip
  201503120909PYTHON.json                                         Skip
  randomTest.json                                                 Skip
```
OK: 0/17 Fail: 0/17 Skip: 17/17
## vmSha3Test
```diff
  sha3_0.json                                                     Skip
  sha3_1.json                                                     Skip
  sha3_2.json                                                     Skip
  sha3_3.json                                                     Skip
  sha3_4.json                                                     Skip
  sha3_5.json                                                     Skip
  sha3_6.json                                                     Skip
  sha3_bigOffset.json                                             Skip
  sha3_bigOffset2.json                                            Skip
  sha3_bigSize.json                                               Skip
  sha3_memSizeNoQuadraticCost31.json                              Skip
  sha3_memSizeQuadraticCost32.json                                Skip
  sha3_memSizeQuadraticCost32_zeroSize.json                       Skip
  sha3_memSizeQuadraticCost33.json                                Skip
  sha3_memSizeQuadraticCost63.json                                Skip
  sha3_memSizeQuadraticCost64.json                                Skip
  sha3_memSizeQuadraticCost64_2.json                              Skip
  sha3_memSizeQuadraticCost65.json                                Skip
```
OK: 0/18 Fail: 0/18 Skip: 18/18
## vmSystemOperations
```diff
  ABAcalls0.json                                                  Skip
  ABAcalls1.json                                                  Skip
  ABAcalls2.json                                                  Skip
  ABAcalls3.json                                                  Skip
  ABAcallsSuicide0.json                                           Skip
  ABAcallsSuicide1.json                                           Skip
  CallRecursiveBomb0.json                                         Skip
  CallRecursiveBomb1.json                                         Skip
  CallRecursiveBomb2.json                                         Skip
  CallRecursiveBomb3.json                                         Skip
  CallToNameRegistrator0.json                                     Skip
  CallToNameRegistratorNotMuchMemory0.json                        Skip
  CallToNameRegistratorNotMuchMemory1.json                        Skip
  CallToNameRegistratorOutOfGas.json                              Skip
  CallToNameRegistratorTooMuchMemory0.json                        Skip
  CallToNameRegistratorTooMuchMemory1.json                        Skip
  CallToNameRegistratorTooMuchMemory2.json                        Skip
  CallToPrecompiledContract.json                                  Skip
  CallToReturn1.json                                              Skip
  PostToNameRegistrator0.json                                     Skip
  PostToReturn1.json                                              Skip
  TestNameRegistrator.json                                        Skip
  callcodeToNameRegistrator0.json                                 Skip
  callcodeToReturn1.json                                          Skip
  callstatelessToNameRegistrator0.json                            Skip
  callstatelessToReturn1.json                                     Skip
  createNameRegistrator.json                                      Skip
  createNameRegistratorOutOfMemoryBonds0.json                     Skip
  createNameRegistratorOutOfMemoryBonds1.json                     Skip
  createNameRegistratorValueTooHigh.json                          Skip
  return0.json                                                    Skip
  return1.json                                                    Skip
  return2.json                                                    Skip
  suicide0.json                                                   Skip
  suicideNotExistingAccount.json                                  Skip
  suicideSendEtherToMe.json                                       Skip
```
OK: 0/36 Fail: 0/36 Skip: 36/36
## vmTests
```diff
  arith.json                                                      Skip
- boolean.json                                                    Fail
- mktx.json                                                       Fail
- suicide.json                                                    Fail
```
OK: 0/4 Fail: 3/4 Skip: 1/4
