# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

FROM debian:trixie-slim AS build

SHELL ["/bin/bash", "-c"]

RUN apt-get clean && apt update \
 && apt -y install curl build-essential git-lfs

RUN ldd --version

ADD . /root/nimbus-eth1

RUN cd /root/nimbus-eth1 \
 && make -j$(nproc) init \
 && make -j$(nproc) DISABLE_MARCH_NATIVE=1 V=1 nimbus

# --------------------------------- #
# Starting new image to reduce size #
# --------------------------------- #
FROM debian:trixie-slim AS deploy

SHELL ["/bin/bash", "-c"]
RUN apt-get clean && apt update \
 && apt -y install build-essential
RUN apt update && apt -y upgrade

RUN ldd --version

RUN rm -f /home/user/nimbus-eth1/build/nimbus

COPY --from=build /root/nimbus-eth1/build/nimbus /home/user/nimbus-eth1/build/nimbus

ENV PATH="/home/user/nimbus-eth1/build:${PATH}"
ENTRYPOINT ["nimbus"]
WORKDIR /home/user/nimbus-eth1/build

STOPSIGNAL SIGINT