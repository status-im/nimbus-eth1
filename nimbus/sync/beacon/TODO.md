## General TODO items

* Update/resolve code fragments which are tagged FIXME

## Open issues

### 1. Weird behaviour of the RPC/engine API

See issue [#2816](https://github.com/status-im/nimbus-eth1/issues/2816)

### 2. Some assert

        Error: unhandled exception: key not found: 0x441a0f..027bc96a [AssertionDefect]

which happened on several `holesky` tests immediately after loging somehing like

        NTC 2024-10-31 21:37:34.728 Finalized blocks persisted   file=forked_chain.nim:231 numberOfBlocks=129 last=044d22843cbe baseNumber=2646764 baseHash=21ec11c1deac

or from another machine with literally the same exception text (but the stack-trace differs)

        NTC 2024-10-31 21:58:07.616 Finalized blocks persisted   file=forked_chain.nim:231 numberOfBlocks=129 last=9cbcc52953a8 baseNumber=2646857 baseHash=9db5c2ac537b

### 3. Mem overflow possible on small breasted systems

Running the exe client, a 1.5G response message was opbserved (on my 8G test system this kills the program as it has already 80% mem load. It happens while syncing holesky at around block #184160 and is reproducible on the 8G system but not yet on the an 80G system.)

		[..]
		DBG 2024-11-20 16:16:18.871+00:00 Processing JSON-RPC request  file=router.nim:135 id=178 name=eth_getLogs
		DBG 2024-11-20 16:16:18.915+00:00 Returning JSON-RPC response  file=router.nim:137 id=178 name=eth_getLogs len=201631
		TRC 2024-11-20 16:16:18.951+00:00 <<< find_node from           topics="eth p2p discovery" file=discovery.nim:248 node=Node[94.16.123.192:30303]
		TRC 2024-11-20 16:16:18.951+00:00 Neighbours to                topics="eth p2p discovery" file=discovery.nim:161 node=Node[94.16.123.192:30303] nodes=[..]
		TRC 2024-11-20 16:16:18.951+00:00 Neighbours to                topics="eth p2p discovery" file=discovery.nim:161 node=Node[94.16.123.192:30303] nodes=[..]
		DBG 2024-11-20 16:16:19.027+00:00 Received JSON-RPC request    topics="JSONRPC-HTTP-SERVER" file=httpserver.nim:52 address=127.0.0.1:49746 len=239
		DBG 2024-11-20 16:16:19.027+00:00 Processing JSON-RPC request  file=router.nim:135 id=179 name=eth_getLogs
		DBG 2024-11-20 16:20:23.664+00:00 Returning JSON-RPC response  file=router.nim:137 id=179 name=eth_getLogs len=1630240149
