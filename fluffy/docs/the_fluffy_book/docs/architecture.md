# Fluffy Architecture

The following diagram outlines the Fluffy high-level architecture.

```mermaid
graph LR
    portal_bridge --> nimbus_execution_client
    portal_bridge --> fluffy
```

## Fluffy Components

```mermaid

graph TD;
    Fluffy --> id2(PortalNode) & id3(RpcHttpServer) & id4(RpcWebSocketServer) & id5(MetricsHttpServer)
    id3(RpcHttpServer) & id4(RpcWebSocketServer) & id2(PortalNode) --> id7(BeaconNetwork)
    id3(RpcHttpServer) & id4(RpcWebSocketServer) & id2(PortalNode) ---> id8(HistoryNetwork)
    id3(RpcHttpServer) & id4(RpcWebSocketServer) & id2(PortalNode) ----> id9(StateNetwork)
    id3(RpcHttpServer) & id4(RpcWebSocketServer) ----> id6(AsyncEvm)
```

## Portal Node Components

```mermaid

graph LR
    PortalNode --> Discv5_Protocol
    PortalNode --> ContentDB
    PortalNode --> StreamManager
    ContentDB --> sqlite
    PortalNode --> BeaconNetwork
    PortalNode --> HistoryNetwork
    PortalNode --> StateNetwork
    PortalNode --> LightClient

```

## State Network Components

```mermaid

graph LR
    StateNetwork --> State_ContentQueue
    StateNetwork --> State_PortalProtocol
    StateNetwork --> HistoryNetwork
    State_PortalProtocol --> State_PortalStream
    State_PortalStream --> State_ContentQueue
    State_PortalProtocol --> ContentDB

```

## History Network Components

```mermaid

graph LR
    HistoryNetwork --> History_ContentQueue
    HistoryNetwork --> History_PortalProtocol
    History_PortalProtocol --> History_PortalStream
    History_PortalStream --> History_ContentQueue
    History_PortalProtocol --> ContentDB

```

## Beacon Network Components

```mermaid

graph LR
    LightClient --> BeaconNetwork
    LightClient --> ForkedLightClientStore
    LightClient --> LightClientProcessor
    LightClient --> LightClientManager
    LightClientManager --> BeaconNetwork
    BeaconNetwork --> Beacon_ContentQueue
    BeaconNetwork --> Beacon_PortalProtocol
    Beacon_PortalProtocol --> Beacon_PortalStream
    BeaconNetwork --> BeaconDb
    BeaconNetwork --> LightClientProcessor

```

## Portal Protocol Components

```mermaid

graph LR
    PortalProtocol --> Discv5_Protocol & RoutingTable & ContentCache & OfferCache & ContentDb & PortalStream & RadiusCache & OfferQueue

```

## Stream Manager Components

```mermaid

graph LR
    PortalStream --> UtpDiscv5Protocol
    PortalStream --> ContentQueue
    StreamManager --> UtpDiscv5Protocol
    StreamManager --> PortalStream
    UtpDiscv5Protocol --> Discv5_Protocol

```


## Async Evm Components

```mermaid

graph LR
  AsyncEvm --> NimbusEvm
  AsyncEvm --> AsyncEvmPortalBackend
  AsyncEvmPortalBackend --> StateNetwork

```
