# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  chronos,
  json_rpc/rpcserver

type
  RpcHttpServerParams = object
    socketFlags: set[ServerFlags]
    serverUri: Uri
    serverIdent: string
    maxConnections: int
    bufferSize: int
    backlogSize: int
    httpHeadersTimeout: chronos.Duration
    maxHeadersSize: int
    maxRequestBodySize: int


func defaultRpcHttpServerParams(): RpcHttpServerParams =
  RpcHttpServerParams(
    socketFlags: {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr},
    serverUri: Uri(),
    serverIdent: "",
    maxConnections: -1,
    bufferSize: 4096,
    backlogSize: 100,
    httpHeadersTimeout: 10.seconds,
    maxHeadersSize: 8192,
    maxRequestBodySize: 2 * 1024 * 1024,
  )

template processResolvedAddresses =
  if tas4.len + tas6.len == 0:
    # Addresses could not be resolved, critical error.
    raise newException(RpcAddressUnresolvableError, "Unable to get address!")

  for r in tas4:
    yield r

  if tas4.len == 0: # avoid ipv4 + ipv6 running together
    for r in tas6:
      yield r

iterator resolvedAddresses(address: string): TransportAddress =
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]

  # Attempt to resolve `address` for IPv4 address space.
  try:
    tas4 = resolveTAddress(address, AddressFamily.IPv4)
  except CatchableError:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, AddressFamily.IPv6)
  except CatchableError:
    discard

  processResolvedAddresses()

proc addServer*(server: RpcHttpServer, address: TransportAddress, params: RpcHttpServerParams) =
  server.addHttpServer(
    address,
    params.socketFlags,
    params.serverUri,
    params.serverIdent,
    params.maxConnections,
    params.bufferSize,
    params.backlogSize,
    params.httpHeadersTimeout,
    params.maxHeadersSize,
    params.maxRequestBodySize)

proc addServer*(server: RpcHttpServer, address: string, params: RpcHttpServerParams) =
  ## Create new server and assign it to addresses ``addresses``.
  for a in resolvedAddresses(address):
    # TODO handle partial failures, ie when 1/N addresses fail
    server.addServer(a, params)

proc newRpcHttpServerWithParams*(address: TransportAddress, authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  let server = RpcHttpServer.new(authHooks)
  let params = defaultRpcHttpServerParams()
  server.addServer(address, params)
  server

proc newRpcHttpServerWithParams*(address: string, authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer =
  let server = RpcHttpServer.new(authHooks)
  let params = defaultRpcHttpServerParams()
  server.addServer(address, params)
  server
