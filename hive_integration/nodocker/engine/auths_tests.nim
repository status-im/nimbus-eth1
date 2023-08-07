import
  std/[base64, times, strutils],
  test_env,
  unittest2,
  chronicles,
  nimcrypto/[hmac],
  json_rpc/[rpcclient],
  ./types

# JWT Authentication Related
const
  defaultJwtTokenSecretBytes = "secretsecretsecretsecretsecretse"
  maxTimeDriftSeconds        = 60'i64
  defaultProtectedHeader     = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9"

proc base64urlEncode(x: auto): string =
  base64.encode(x, safe = true).replace("=", "")

proc prepareAuthCallToken(secret: string, time: int64): string =
  let key = cast[seq[byte]](secret)
  let payload = """{"iat": $1}""" % [$time]
  let token = defaultProtectedHeader & "." & payload.base64urlEncode
  let sig = base64urlEncode(sha256.hmac(key, token).data)
  token & "." & sig

proc getClient(t: TestEnv, token: string): RpcHttpClient =
  proc authHeaders(): seq[(string, string)] =
    @[("Authorization", "Bearer " & token)]

  let client = newRpcHttpClient(getHeaders = authHeaders)
  waitFor client.connect("127.0.0.1", t.conf.rpcPort, false)
  return client

template genAuthTest(procName: untyped, timeDriftSeconds: int64, customAuthSecretBytes: string, authOK: bool) =
  proc procName(t: TestEnv): TestStatus =
    result = TestStatus.OK

    # Default values
    var
      # All test cases send a simple TransitionConfigurationV1 to check the Authentication mechanism (JWT)
      tConf = TransitionConfigurationV1(
        terminalTotalDifficulty: t.ttd
      )
      testSecret = customAuthSecretBytes
      testTime   = getTime().toUnix

    if testSecret.len == 0:
      testSecret = defaultJwtTokenSecretBytes

    if timeDriftSeconds != 0:
      testTime = testTime + timeDriftSeconds

    let token = prepareAuthCallToken(testSecret, testTime)
    let client = getClient(t, token)

    try:
      discard waitFor client.call("engine_exchangeTransitionConfigurationV1", %[%tConf])
      testCond authOk:
        error "Authentication was supposed to fail authentication but passed"
    except CatchableError:
      testCond not authOk:
        error "Authentication was supposed to pass authentication but failed"

genAuthTest(authTest1, 0'i64, "", true)
genAuthTest(authTest2, 0'i64, "secretsecretsecretsecretsecrets", false)
genAuthTest(authTest3, 0'i64, "\0secretsecretsecretsecretsecretse", false)
genAuthTest(authTest4, -1 - maxTimeDriftSeconds, "", false)
genAuthTest(authTest5, 1 - maxTimeDriftSeconds, "", true)
genAuthTest(authTest6, maxTimeDriftSeconds + 1, "", false)
genAuthTest(authTest7, maxTimeDriftSeconds - 1, "", true)

# JWT Authentication Tests
const authTestList* = [
  TestSpec(
    name: "JWT Authentication: No time drift, correct secret",
    run: authTest1,
    enableAuth: true
  ),
  TestSpec(
    name: "JWT Authentication: No time drift, incorrect secret (shorter)",
    run: authTest2,
    enableAuth: true
  ),
  TestSpec(
    name: "JWT Authentication: No time drift, incorrect secret (longer)",
    run: authTest3,
    enableAuth: true
  ),
  TestSpec(
    name: "JWT Authentication: Negative time drift, exceeding limit, correct secret",
    run: authTest4,
    enableAuth: true
  ),
  TestSpec(
    name: "JWT Authentication: Negative time drift, within limit, correct secret",
    run: authTest5,
    enableAuth: true
  ),
  TestSpec(
    name: "JWT Authentication: Positive time drift, exceeding limit, correct secret",
    run: authTest6,
    enableAuth: true
  ),
  TestSpec(
    name: "JWT Authentication: Positive time drift, within limit, correct secret",
    run: authTest7,
    enableAuth: true
  )
]
