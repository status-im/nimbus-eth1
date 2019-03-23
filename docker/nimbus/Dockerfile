FROM statusteam/nim-base AS build

RUN apt update \
 && apt install -y build-essential make \
 && apt clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ARG GIT_REVISION

RUN git clone https://github.com/status-im/nimbus.git \
 && cd nimbus \
 && git reset --hard ${GIT_REVISION} \
 && make update deps

RUN cd nimbus && \
    make nimbus && \
    mv build/nimbus /usr/bin/

# --------------------------------- #
# Starting new image to reduce size #
# --------------------------------- #
FROM debian:9-slim

RUN apt update \
 && apt install -y librocksdb-dev \
 && apt clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=build /usr/bin/nimbus /usr/bin/nimbus

MAINTAINER Zahary Karadjov <zahary@status.im>
LABEL description="Nimbus: an Ethereum 2.0 Sharding Client for Resource-Restricted Devices"

ENTRYPOINT ["/usr/bin/nimbus"]

