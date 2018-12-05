import json_rpc/rpcserver, rpc_types, stint, hexstrings, eth_common

proc setupWhisperRPC*(rpcsrv: RpcServer) =
  rpcsrv.rpc("shh_version") do() -> string:
    ## Returns string of the current whisper protocol version.
    discard

  rpcsrv.rpc("shh_post") do(message: WhisperPost) -> bool:
    ## Sends a whisper message.
    ##
    ## message: Whisper message to post.
    ## Returns true if the message was send, otherwise false.
    discard

  rpcsrv.rpc("shh_newIdentity") do() -> WhisperIdentity:
    ## Creates new whisper identity in the client.
    ##
    ## Returns the address of the new identiy.
    discard

  rpcsrv.rpc("shh_hasIdentity") do(identity: WhisperIdentityStr) -> bool:
    ## Checks if the client holds the private keys for a given identity.
    ##
    ## identity: the identity address to check.
    ## Returns true if the client holds the privatekey for that identity, otherwise false.
    discard

  rpcsrv.rpc("shh_newGroup") do() -> WhisperIdentity:
    ## (?) - This has no description information in the RPC wiki.
    ##
    ## Returns the address of the new group. (?)
    discard

  rpcsrv.rpc("shh_addToGroup") do(identity: WhisperIdentityStr) -> bool:
    ## (?) - This has no description information in the RPC wiki.
    ##
    ## identity: the identity address to add to a group (?).
    ## Returns true if the identity was successfully added to the group, otherwise false (?).
    discard

  rpcsrv.rpc("shh_newFilter") do(filterOptions: WhisperFilterOptions) -> int:
    ## Creates filter to notify, when client receives whisper message matching the filter options.
    ##
    ## filterOptions: The filter options:
    ## to: DATA, 60 Bytes - (optional) identity of the receiver. When present it will try to decrypt any incoming message if the client holds the private key to this identity.
    ## topics: Array of DATA - list of DATA topics which the incoming message's topics should match. You can use the following combinations:
    ## [A, B] = A && B
    ## [A, [B, C]] = A && (B || C)
    ## [null, A, B] = ANYTHING && A && B null works as a wildcard
    ## Returns the newly created filter.
    discard

  rpcsrv.rpc("shh_uninstallFilter") do(id: int) -> bool:
    ## Uninstalls a filter with given id.
    ## Should always be called when watch is no longer needed.
    ## Additonally Filters timeout when they aren't requested with shh_getFilterChanges for a period of time.
    ##
    ## id: the filter id.
    ## Returns true if the filter was successfully uninstalled, otherwise false.
    discard

  rpcsrv.rpc("shh_getFilterChanges") do(id: int) -> seq[WhisperMessage]:
    ## Polling method for whisper filters. Returns new messages since the last call of this method.
    ## Note: calling the shh_getMessages method, will reset the buffer for this method, so that you won't receive duplicate messages.
    ##
    ## id: the filter id.
    discard

  rpcsrv.rpc("shh_getMessages") do(id: int) -> seq[WhisperMessage]:
    ## Get all messages matching a filter. Unlike shh_getFilterChanges this returns all messages.
    ##
    ## id: the filter id.
    ## Returns a list of messages received since last poll.
    discard
