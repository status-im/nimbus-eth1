# Docker container spec for building the master branch of nimbus.

FROM debian:buster-slim AS build

RUN apt-get update \
 && apt-get install -y --fix-missing build-essential make git libpcre3-dev librocksdb-dev \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV NPROC=2

RUN git clone --depth 1 --branch non_blocking_startup https://github.com/status-im/nimbus-eth1.git \
 && cd nimbus-eth1 \
 && git checkout non_blocking_startup \
 && make -j${NPROC} NIMFLAGS="--parallelBuild:${NPROC}" V=1 update

RUN cd nimbus-eth1 && \
    make -j${NPROC} NIMFLAGS="--parallelBuild:${NPROC}" nimbus_execution_client && \
    mv build/nimbus_execution_client /usr/bin/

# --------------------------------- #
# Starting new image to reduce size #
# --------------------------------- #
FROM debian:buster-slim AS deploy

RUN apt-get update \
 && apt-get install -y librocksdb-dev bash curl jq\
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=build /usr/bin/nimbus_execution_client /usr/bin/nimbus_execution_client
RUN usr/bin/nimbus_execution_client --version > /version.txt

# Add genesis mapper script.
ADD genesis.json /genesis.json
ADD mapper.jq /mapper.jq

# Add the startup script.
ADD nimbus.sh /nimbus.sh
RUN chmod +x /nimbus.sh

# Add the enode URL retriever script.
ADD enode.sh /hive-bin/enode.sh
RUN chmod +x /hive-bin/enode.sh

# Export the usual networking ports to allow outside access to the node
EXPOSE 8545 8546 8547 8551 30303 30303/udp

ENTRYPOINT ["/nimbus.sh"]
