FROM statusteam/nim-base AS build

RUN apt update \
 && apt install -y build-essential make \
 && apt clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN git clone https://github.com/status-im/nimbus.git \
 && cd nimbus \
 && make update deps

ARG NETWORK
ARG NETWORK_BACKEND

RUN cd nimbus \
 && set -a \
 && . vendor/nim-beacon-chain/scripts/${NETWORK}.env \
 && ./env.sh nim \
      -o:/usr/bin/beacon_node \
      -d:release \
      -d:with${NETWORK_BACKEND} \
      -d:SHARD_COUNT=${SHARD_COUNT} \
      -d:SLOTS_PER_EPOCH=${SLOTS_PER_EPOCH} \
      c vendor/nim-beacon-chain/beacon_chain/beacon_node.nim

# --------------------------------- #
# Starting new image to reduce size #
# --------------------------------- #
FROM debian:9-slim

RUN apt update \
 && apt install -y librocksdb-dev \
 && apt clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=build /usr/bin/beacon_node /usr/bin/beacon_node 

MAINTAINER Zahary Karadjov <zahary@status.im>
LABEL description="Nimbus installation that can act as an ETH2 network bootstrap node."

ENTRYPOINT ["/usr/bin/beacon_node"]
