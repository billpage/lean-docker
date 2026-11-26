# Lean 4 + Mathlib container on STRIX. See README.md.
# The image holds only the OS and tools. elan, the toolchains and the Mathlib cache
# live in the bind-mounted home (~/lean-home on the host), so a rebuild downloads nothing.
FROM ubuntu:24.04
ARG UID=1000
ARG GID=1000
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 \
    ELAN_HOME=/home/lean/.elan \
    MATHLIB_CACHE_DIR=/home/lean/.cache/mathlib \
    PATH=/home/lean/.elan/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates util-linux procps \
 && rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 already has user "ubuntu" with UID 1000; remove it first.
RUN userdel -r ubuntu 2>/dev/null; groupadd -g ${GID} lean \
 && useradd -m -u ${UID} -g ${GID} -s /bin/bash lean

COPY scripts/ /usr/local/bin/
USER lean
WORKDIR /home/lean/work
CMD ["sleep", "infinity"]
