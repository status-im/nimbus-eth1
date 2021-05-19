# Docker container spec for building the master branch of nimbus.

FROM debian:buster-slim AS build

RUN apt-get update \
 && apt-get install -y --fix-missing build-essential make git libpcre3-dev librocksdb-dev \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV NPROC=2

RUN git clone --depth 1 https://github.com/status-im/nimbus-eth1.git \
 && cd nimbus-eth1 \
 && git checkout master \
 && make -j${NPROC} NIMFLAGS="--parallelBuild:${NPROC}" V=1 update

RUN cd nimbus-eth1 && \
    make -j${NPROC} NIMFLAGS="--parallelBuild:${NPROC}" nimbus && \
    mv build/nimbus /usr/bin/

# --------------------------------- #
# Starting new image to reduce size #
# --------------------------------- #
FROM debian:buster-slim AS deploy

RUN apt-get update \
 && apt-get install -y librocksdb-dev bash curl jq\
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=build /usr/bin/nimbus /usr/bin/nimbus
RUN usr/bin/nimbus -v > /version.txt

# Inject the startup script and helper files
COPY *.sh *.jq *.json /
RUN chmod +x /nimbus.sh
RUN chmod +x /enode.sh

# Export the usual networking ports to allow outside access to the node
EXPOSE 8545 8546 8547 30303 30303/udp

ENTRYPOINT ["/nimbus.sh"]
