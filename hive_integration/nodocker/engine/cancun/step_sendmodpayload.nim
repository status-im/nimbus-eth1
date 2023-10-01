# Send a modified version of the latest payload produced using NewPayloadV3
type SendModifiedLatestPayload struct {
  ClientID             uint64
  NewPayloadCustomizer helper.NewPayloadCustomizer
}

method execute*(step: SendModifiedLatestPayload, ctx: CancunTestContext): bool =
  # Get the latest payload
  var (
    payload                           = &env.clMock.latestPayloadBuilt
    expectedError  *int               = nil
    expectedStatus test.PayloadStatus = test.Valid
    err            error              = nil
  )
  if payload == nil {
    return error "TEST-FAIL: no payload available")
  }
  if env.clMock.LatestBlobBundle == nil {
    return error "TEST-FAIL: no blob bundle available")
  }
  if step.NewPayloadCustomizer == nil {
    return error "TEST-FAIL: no payload customizer available")
  }

  # Send a custom new payload
  step.NewPayloadCustomizer.setEngineAPIVersionResolver(t.ForkConfig)
  payload, err = step.NewPayloadCustomizer.customizePayload(payload)
  if err != nil {
    fatal "Error customizing payload: %v", err)
  }
  expectedError, err = step.NewPayloadCustomizer.getExpectedError()
  if err != nil {
    fatal "Error getting custom expected error: %v", err)
  }
  if step.NewPayloadCustomizer.getExpectInvalidStatus() {
    expectedStatus = test.Invalid
  }

  # Send the payload
  if step.ClientID >= uint64(len(t.TestEngines)) {
    return error "invalid client index %d", step.ClientID)
  }
  testEngine = t.TestEngines[step.ClientID].WithEngineAPIVersionResolver(step.NewPayloadCustomizer)
  r = env.client.NewPayload(payload)
  if expectedError != nil {
    r.ExpectErrorCode(*expectedError)
  else:
    r.ExpectStatus(expectedStatus)
  }
  return nil
}

method description*(step: SendModifiedLatestPayload): string =
  desc = fmt.Sprintf("SendModifiedLatestPayload: client %d, expected invalid=%T, ", step.ClientID, step.NewPayloadCustomizer.getExpectInvalidStatus())
  /*
    TODO: Figure out if we need this.
    if step.VersionedHashes != nil {
      desc += step.VersionedHashes.Description()
    }
  */

  return desc
}