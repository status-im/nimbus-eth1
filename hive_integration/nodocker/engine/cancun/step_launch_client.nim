import
  std/strutils,
  ./step_desc,
  ../test_env

# A step that launches a new client
type
  LaunchClients* = ref object of TestStep
    clientCount*             : int
    skipConnectingToBootnode*: bool
    skipAddingToCLMock*      : bool

func getClientCount(step: LaunchClients): int =
  var clientCount = step.clientCount
  if clientCount == 0:
    clientCount = 1
  return clientCount

method execute*(step: LaunchClients, ctx: CancunTestContext): bool =
  # Launch a new client
  let clientCount = step.getClientCount()
  for i in 0..<clientCount:
    let connectBootNode = not step.skipConnectingToBootnode
    let addToClMock = not step.skipAddingToCLMock
    discard ctx.env.addEngine(addToClMock, connectBootNode)

  return true

method description*(step: LaunchClients): string =
  "Launch $1 new engine client(s)" % [$step.getClientCount()]
