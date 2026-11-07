# syntax=docker/dockerfile:1

# The toolchain and the sources are installed at image build time so every measured stage runs offline.
# ubuntu-latest of the tag commit (2025-03-14) is 24.04: the base image and the archive snapshot of that date.
FROM ubuntu:noble-20250127@sha256:72297848456d5d37d1262630108ab308d3e9ec7ed1c3286a32fe09856619a782

ARG XGBOOST_SHA=aae009b9277d7a981ca59aa2c5227b09c44545a2
ARG DMLC_CORE_SHA=13341857549852a9a86b1894b5ba84c6276ab381
# This tag still carries the gputreeshap submodule; actions/checkout with submodules: true checks it out.
ARG GPUTREESHAP_SHA=40eae8c4c45974705f8053e4d3d05b88e3cfaefd
ARG APT_SNAPSHOT=20250314T204716Z

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
        build-essential cmake ninja-build git iproute2 procps python3; \
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

# Configure-time input of dmlc-core/cmake/gtest_cmake.in (ExternalProject git clone, GIT_TAG release-1.11.0): a local bare mirror
# answers the unchanged URL, owned by the image user so git's ownership check accepts it.
ARG GOOGLETEST_RELEASE_SHA=e2239ee6043f73722e7aa812a459f54a28552929
RUN set -eux; \
    git clone -q --bare https://github.com/google/googletest.git /opt/googletest.git; \
    test "$(git -C /opt/googletest.git rev-parse 'refs/tags/release-1.11.0^{commit}')" = "$GOOGLETEST_RELEASE_SHA"; \
    chown -R runner:runner /opt/googletest.git; \
    git config --system url./opt/googletest.git.insteadOf https://github.com/google/googletest.git; \
    echo "${GOOGLETEST_RELEASE_SHA}  googletest release-1.11.0" > /image-provenance/googletest.sha256

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
