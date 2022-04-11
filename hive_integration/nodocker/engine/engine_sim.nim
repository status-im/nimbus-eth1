import
  test_env,
  engine_tests,
  chronos,
  unittest2

proc runTest(x: TestSpec, testStatusIMPL: var TestStatus) =
  var t = setupELClient()
  t.setRealTTD(x.ttd)
  x.run(t, testStatusIMPL)
  t.stopELClient()

proc main() =
  suite "Engine Tests":
    for x in engineTestList:
      test x.name:
        runTest(x, testStatusIMPL)

main()
