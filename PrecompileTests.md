PrecompileTests
===
## PrecompileTests
```diff
+ blake2F.json                                                    OK
- blsG1Add.json                                                   Fail
- blsG1Mul.json                                                   Fail
- blsG1MultiExp.json                                              Fail
- blsG2Add.json                                                   Fail
- blsG2Mul.json                                                   Fail
- blsG2MultiExp.json                                              Fail
- blsMapG1.json                                                   Fail
- blsMapG2.json                                                   Fail
- blsPairing.json                                                 Fail
+ bn256Add.json                                                   OK
+ bn256Add_istanbul.json                                          OK
+ bn256mul.json                                                   OK
+ bn256mul_istanbul.json                                          OK
+ ecrecover.json                                                  OK
+ identity.json                                                   OK
+ modexp.json                                                     OK
+ modexp_eip2565.json                                             OK
+ pairing.json                                                    OK
+ pairing_istanbul.json                                           OK
+ ripemd160.json                                                  OK
+ sha256.json                                                     OK
```
OK: 13/22 Fail: 9/22 Skip: 0/22

---TOTAL---
OK: 13/22 Fail: 9/22 Skip: 0/22
