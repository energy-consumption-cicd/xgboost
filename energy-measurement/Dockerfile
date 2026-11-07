# syntax=docker/dockerfile:1

# The toolchain and the sources are installed at image build time so every measured stage runs offline.
# ubuntu-latest of the tag commit (2025-10-16) is 24.04: the base image and the archive snapshot of that date.
FROM ubuntu:noble-20251013@sha256:c35e29c9450151419d9448b0fd75374fec4fff364a27f176fb458d472dfc9e54

ARG XGBOOST_SHA=ccb511768e13d1670c10be07dea89d0edca138f3
ARG DMLC_CORE_SHA=8986b0598df709117570984571476c3614f55724
# This tag still carries the gputreeshap submodule; actions/checkout with submodules: true checks it out.
ARG GPUTREESHAP_SHA=40eae8c4c45974705f8053e4d3d05b88e3cfaefd
ARG APT_SNAPSHOT=20251016T202232Z

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# ca-certificates comes from the current archive only to reach the snapshot service over https.
RUN set -eux; \
    apt-get update -qq; \
    apt-get install -qq -y --no-install-recommends ca-certificates; \
    sed -i "s#http://archive.ubuntu.com/ubuntu/#https://snapshot.ubuntu.com/ubuntu/${APT_SNAPSHOT}/#; s#http://security.ubuntu.com/ubuntu/#https://snapshot.ubuntu.com/ubuntu/${APT_SNAPSHOT}/#" \
        /etc/apt/sources.list.d/ubuntu.sources; \
    rm -rf /var/lib/apt/lists/*

# The job installs ninja-build over the hosted image's compiler. iproute2 adds the default route the collective tests need; python3 runs the network check.
RUN set -eux; \
    apt-get update -qq; \
    apt-get install -qq -y --no-install-recommends --allow-downgrades \
        build-essential cmake ninja-build git curl iproute2 procps python3; \
    rm -rf /var/lib/apt/lists/*

# Toolchain versions of the archive at the tag commit; a rebuild that resolves others fails here.
RUN set -eux; \
    test "$(dpkg-query -W -f='${Version}' gcc-13)" = "13.3.0-6ubuntu2~24.04"; \
    test "$(dpkg-query -W -f='${Version}' g++-13)" = "13.3.0-6ubuntu2~24.04"; \
    test "$(dpkg-query -W -f='${Version}' cmake)" = "3.28.3-1build7"; \
    test "$(dpkg-query -W -f='${Version}' ninja-build)" = "1.11.1-2"

# The hosted runner user, uid 1001, with the workspace path of the hosted runner.
RUN set -eux; \
    userdel -r ubuntu; \
    useradd --create-home --uid 1001 --shell /bin/bash runner; \
    install -d -o runner -g runner /home/runner/work/xgboost/xgboost /image-provenance

# Configure-time input of dmlc-core/test/unittest/CMakeLists.txt (FetchContent URL, googletest v1.14.0): staged here so every stage runs offline.
ARG GOOGLETEST_TARBALL_SHA256=8ad598c73ad796e0d8280b082cebd82a630d73e73cd3c70057938a6501bba5d7
RUN set -eux; \
    curl -fsSL -o /tmp/googletest.tar.gz https://github.com/google/googletest/archive/refs/tags/v1.14.0.tar.gz; \
    echo "${GOOGLETEST_TARBALL_SHA256}  /tmp/googletest.tar.gz" | sha256sum -c -; \
    mkdir /opt/googletest-1.14.0; \
    tar -xzf /tmp/googletest.tar.gz -C /opt/googletest-1.14.0 --strip-components=1; \
    rm -f /tmp/googletest.tar.gz; \
    echo "${GOOGLETEST_TARBALL_SHA256}  googletest v1.14.0 tarball" > /image-provenance/googletest.sha256

USER runner
WORKDIR /home/runner/work/xgboost/xgboost

# A git checkout with the submodules, as actions/checkout with submodules: true does.
RUN set -eux; \
    git init -q .; \
    git remote add origin https://github.com/dmlc/xgboost.git; \
    git fetch --depth 1 -q origin "$XGBOOST_SHA"; \
    git checkout -q --detach FETCH_HEAD; \
    test "$(git rev-parse HEAD)" = "$XGBOOST_SHA"; \
    git submodule update --init --depth 1 dmlc-core gputreeshap; \
    test "$(git -C dmlc-core rev-parse HEAD)" = "$DMLC_CORE_SHA"; \
    test "$(git -C gputreeshap rev-parse HEAD)" = "$GPUTREESHAP_SHA"

# Mount point of the per-run build volume; created here so the volume inherits the owner.
RUN set -eux; \
    mkdir build; \
    dpkg -l > /image-provenance/dpkg.txt; \
    git rev-parse HEAD > /image-provenance/xgboost.sha; \
    git -C dmlc-core rev-parse HEAD > /image-provenance/dmlc-core.sha
