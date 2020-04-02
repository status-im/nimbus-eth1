FROM debian:bullseye-slim AS build

SHELL ["/bin/bash", "-c"]

RUN apt-get -qq update \
 && apt-get -qq -y install build-essential make wget libpcre3-dev git curl &>/dev/null \
 && apt-get -qq clean

ARG GIT_REVISION

RUN cd /root \
 && git clone https://github.com/status-im/nimbus.git \
 && cd nimbus \
 && git reset --hard ${GIT_REVISION} \
 && { make &>/dev/null || true; } \
 && make -j$(nproc) update \
 && make NIMFLAGS="-d:debug -d:insecure" wakunode

# --------------------------------- #
# Starting new image to reduce size #
# --------------------------------- #
FROM debian:bullseye-slim

SHELL ["/bin/bash", "-c"]

RUN apt-get -qq update \
 && apt-get -qq -y install libpcre3 &>/dev/null \
 && apt-get -qq clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=build /root/nimbus/build/wakunode /usr/bin/wakunode

MAINTAINER Kim De Mey <kimdemey@status.im>
LABEL description="Wakunode: Waku and Whisper client"

ENTRYPOINT ["/usr/bin/wakunode"]
