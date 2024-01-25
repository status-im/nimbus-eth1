# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronos,
  chronicles, chronicles/topics_registry,
  stew/byteutils,
  eth/async_utils,
  json_rpc/clients/httpclient,
  beacon_chain/spec/eth2_apis/rest_beacon_client,
  ../../network/beacon/beacon_content,
  ../../rpc/portal_rpc_client,
  ../eth_data_exporter/cl_data_exporter

const
  restRequestsTimeout = 30.seconds

# TODO: From nimbus_binary_common, but we don't want to import that.
proc sleepAsync*(t: TimeDiff): Future[void] =
  sleepAsync(nanoseconds(
    if t.nanoseconds < 0: 0'i64 else: t.nanoseconds))

proc gossipLCBootstrapUpdate*(
    restClient: RestClientRef, portalRpcClient: RpcHttpClient,
    trustedBlockRoot: Eth2Digest,
    cfg: RuntimeConfig, forkDigests: ref ForkDigests):
    Future[Result[void, string]] {.async.} =
  var bootstrap =
    try:
      info "Downloading LC bootstrap"
      awaitWithTimeout(
        restClient.getLightClientBootstrap(
          trustedBlockRoot,
          cfg, forkDigests),
        restRequestsTimeout
      ):
        return err("Attempt to download LC bootstrap timed out")
    except CatchableError as exc:
      return err("Unable to download LC bootstrap: " & exc.msg)

  withForkyObject(bootstrap):
    when lcDataFork > LightClientDataFork.None:
      let
        slot = forkyObject.header.beacon.slot
        contentKey = encode(bootstrapContentKey(trustedBlockRoot))
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(slot), cfg)
        content = encodeBootstrapForked(
          forkDigest,
          bootstrap
        )

      proc GossipRpcAndClose(): Future[Result[void, string]] {.async.} =
        try:
          let
            contentKeyHex = contentKey.asSeq().toHex()
            peers = await portalRpcClient.portal_beaconRandomGossip(
                contentKeyHex,
                content.toHex())
          info "Beacon LC bootstrap gossiped", peers,
            contentKey = contentKeyHex
          return ok()
        except CatchableError as e:
          return err("JSON-RPC error: " & $e.msg)

      let res = await GossipRpcAndClose()
      if res.isOk():
        return ok()
      else:
        return err(res.error)

    else:
      return err("No LC bootstraps pre Altair")

proc gossipLCUpdates*(
    restClient: RestClientRef, portalRpcClient: RpcHttpClient,
    startPeriod: uint64, count: uint64,
    cfg: RuntimeConfig, forkDigests: ref ForkDigests):
    Future[Result[void, string]] {.async.} =
  var updates =
    try:
      info "Downloading LC updates", count
      awaitWithTimeout(
        restClient.getLightClientUpdatesByRange(
          SyncCommitteePeriod(startPeriod), count, cfg, forkDigests),
        restRequestsTimeout
      ):
        return err("Attempt to download LC updates timed out")
    except CatchableError as exc:
      return err("Unable to download LC updates: " & exc.msg)

  if updates.len() > 0:
    withForkyObject(updates[0]):
      when lcDataFork > LightClientDataFork.None:
        let
          slot = forkyObject.attested_header.beacon.slot
          period = slot.sync_committee_period
          contentKey = encode(updateContentKey(period.uint64, count))
          forkDigest = forkDigestAtEpoch(forkDigests[], epoch(slot), cfg)

          content = encodeLightClientUpdatesForked(
            forkDigest,
            updates
          )

        proc GossipRpcAndClose(): Future[Result[void, string]] {.async.} =
          try:
            let
              contentKeyHex = contentKey.asSeq().toHex()
              peers = await portalRpcClient.portal_beaconRandomGossip(
                contentKeyHex,
                content.toHex())
            info "Beacon LC update gossiped", peers,
              contentKey = contentKeyHex, period, count
            return ok()
          except CatchableError as e:
            return err("JSON-RPC error: " & $e.msg)

        let res = await GossipRpcAndClose()
        if res.isOk():
          return ok()
        else:
          return err(res.error)
      else:
        return err("No LC updates pre Altair")
  else:
    # TODO:
    # currently only error if no updates at all found. This might be due
    # to selecting future period or too old period.
    # Might want to error here in case count != updates.len or might not want to
    # error at all and perhaps return the updates.len.
    return err("No updates downloaded")

proc gossipLCFinalityUpdate*(
    restClient: RestClientRef, portalRpcClient: RpcHttpClient,
    cfg: RuntimeConfig, forkDigests: ref ForkDigests):
    Future[Result[Slot, string]] {.async.} =
  var update =
    try:
      info "Downloading LC finality update"
      awaitWithTimeout(
        restClient.getLightClientFinalityUpdate(
          cfg, forkDigests),
        restRequestsTimeout
      ):
        return err("Attempt to download LC finality update timed out")
    except CatchableError as exc:
      return err("Unable to download LC finality update: " & exc.msg)

  withForkyObject(update):
    when lcDataFork > LightClientDataFork.None:
      let
        finalizedSlot = forkyObject.finalized_header.beacon.slot
        contentKey = encode(finalityUpdateContentKey(finalizedSlot.uint64))
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg)
        content = encodeFinalityUpdateForked(
          forkDigest,
          update
        )

      proc GossipRpcAndClose(): Future[Result[void, string]] {.async.} =
        try:
          let
            contentKeyHex = contentKey.asSeq().toHex()
            peers = await portalRpcClient.portal_beaconRandomGossip(
                contentKeyHex,
                content.toHex())
          info "Beacon LC finality update gossiped", peers,
            contentKey = contentKeyHex, finalizedSlot
          return ok()
        except CatchableError as e:
          return err("JSON-RPC error: " & $e.msg)

      let res = await GossipRpcAndClose()
      if res.isOk():
        return ok(finalizedSlot)
      else:
        return err(res.error)

    else:
      return err("No LC updates pre Altair")

proc gossipLCOptimisticUpdate*(
    restClient: RestClientRef, portalRpcClient: RpcHttpClient,
    cfg: RuntimeConfig, forkDigests: ref ForkDigests):
    Future[Result[Slot, string]] {.async.} =
  var update =
    try:
      info "Downloading LC optimistic update"
      awaitWithTimeout(
        restClient.getLightClientOptimisticUpdate(
          cfg, forkDigests),
        restRequestsTimeout
      ):
        return err("Attempt to download LC optimistic update timed out")
    except CatchableError as exc:
      return err("Unable to download LC optimistic update: " & exc.msg)

  withForkyObject(update):
    when lcDataFork > LightClientDataFork.None:
      let
        slot = forkyObject.signature_slot
        contentKey = encode(optimisticUpdateContentKey(slot.uint64))
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg)
        content = encodeOptimisticUpdateForked(
          forkDigest,
          update
        )

      proc GossipRpcAndClose(): Future[Result[void, string]] {.async.} =
        try:
          let
            contentKeyHex = contentKey.asSeq().toHex()
            peers = await portalRpcClient.portal_beaconRandomGossip(
                contentKeyHex,
                content.toHex())
          info "Beacon LC optimistic update gossiped", peers,
            contentKey = contentKeyHex, slot

          return ok()
        except CatchableError as e:
          return err("JSON-RPC error: " & $e.msg)

      let res = await GossipRpcAndClose()
      if res.isOk():
        return ok(slot)
      else:
        return err(res.error)

    else:
      return err("No LC updates pre Altair")
