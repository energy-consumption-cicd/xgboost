# syntax=docker/dockerfile:1

# The toolchain and the sources are installed at image build time so every measured stage runs offline.
FROM ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254

ARG XGBOOST_SHA=d5cd2b40725d55747447f66e4a24f9a2c341b0bf
ARG DMLC_CORE_SHA=4baa84e627849e675a3f99c92990ef9c39e4269e
ARG ENV_FILE=ops/conda_env/cpp_test.yml
ARG ENV_FILE_SHA256=727f8257d5b539cabda901c20d9cf3ae94f783c1f3122b4b01f47e38868e344b
# sha256 of the sorted URL lines of the pre-registered lock, resolved by the rehearsal of this tag (the reference run logs expired).
ARG LOCK_URLS_SHA256=41ad88efad07f6b3c257b366978e0226234969899b021a2fd04337d88f21daad
# The action asks for `latest`; this is the release the reference run resolved.
ARG MINIFORGE_VERSION=26.5.3-0
ARG MINIFORGE_SHA256=14db468222ad564658656f769506056209b6dc375f5e7dfd31eb5ebbf08fa529
# The tag pins no compiler; on the date of its reference run conda-forge resolved c-compiler/cxx-compiler 1.11.0 (GCC 14), the
# last 1.x line before 2.0.0 (2026-08-13), which drops the activation scripts the job relies on. Pinned by date, declared.
ARG COMPILER_META_VERSION=1.11.0
# dmlc/xgboost-devops/actions/sccache pins this rapidsai release.
ARG SCCACHE_VERSION=v0.16.0-rapids.4

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# No compiler from apt: the job takes its whole toolchain from conda-forge. iproute2 adds the default route the collective tests need.
RUN set -eux; \
    apt-get update -qq; \
    apt-get install -qq -y --no-install-recommends \
        bzip2 ca-certificates curl git iproute2 procps; \
    rm -rf /var/lib/apt/lists/*

# The hosted runner user, uid 1001, with the workspace path of the hosted runner.
RUN set -eux; \
    userdel -r ubuntu; \
    useradd --create-home --uid 1001 --shell /bin/bash runner; \
    install -d -o runner -g runner /home/runner/work/xgboost/xgboost /home/runner/.local/bin /home/runner/.cache/sccache /image-provenance

USER runner
ENV PATH="/home/runner/.local/bin:/home/runner/miniconda3/bin:${PATH}"

RUN set -eux; \
    curl -fsSL -o /tmp/miniforge.sh \
        "https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/Miniforge3-${MINIFORGE_VERSION}-Linux-x86_64.sh"; \
    echo "${MINIFORGE_SHA256}  /tmp/miniforge.sh" | sha256sum -c -; \
    bash /tmp/miniforge.sh -b -p /home/runner/miniconda3; \
    rm -f /tmp/miniforge.sh; \
    conda --version

# dmlc/xgboost-devops/actions/sccache: the rapidsai fork, installed under ~/.local/bin.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -o sccache.tar.gz \
        "https://github.com/rapidsai/sccache/releases/download/${SCCACHE_VERSION}/sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz"; \
    tar -xzf sccache.tar.gz; \
    mv "sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl/sccache" /home/runner/.local/bin/; \
    rm -rf sccache.tar.gz "sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl"; \
    sccache --version

WORKDIR /home/runner/work/xgboost/xgboost

# A git checkout with the submodule, as actions/checkout with submodules: true does.
RUN set -eux; \
    git init -q .; \
    git remote add origin https://github.com/dmlc/xgboost.git; \
    git fetch --depth 1 -q origin "$XGBOOST_SHA"; \
    git checkout -q --detach FETCH_HEAD; \
    test "$(git rev-parse HEAD)" = "$XGBOOST_SHA"; \
    git submodule update --init --depth 1 dmlc-core; \
    test "$(git -C dmlc-core rev-parse HEAD)" = "$DMLC_CORE_SHA"; \
    echo "${ENV_FILE_SHA256}  ${ENV_FILE}" | sha256sum -c -

# dmlc/xgboost-devops/actions/impls/miniforge-setup: the environment from the upstream file plus the date pin; it must equal the pre-registered lock URL by URL.
RUN set -ex; \
    { cat "$ENV_FILE"; echo "- c-compiler=${COMPILER_META_VERSION}"; echo "- cxx-compiler=${COMPILER_META_VERSION}"; } > /tmp/cpp_test.pinned.yml; \
    sha256sum /tmp/cpp_test.pinned.yml > /image-provenance/env-file-pinned.sha256; \
    mamba env create -q -n cpp_test -f /tmp/cpp_test.pinned.yml; \
    conda list -n cpp_test --explicit | grep '^https://' | sort > /tmp/explicit.txt; \
    test "$(grep -c . /tmp/explicit.txt)" = "62"; \
    echo "${LOCK_URLS_SHA256}  /tmp/explicit.txt" | sha256sum -c -; \
    conda list -n cpp_test --explicit > /image-provenance/conda-explicit.txt; \
    conda clean --tarballs --yes; \
    rm -f /tmp/explicit.txt

# Mount point of the per-run build volume; created here so the volume inherits the owner.
RUN set -eux; \
    mkdir build; \
    dpkg -l > /image-provenance/dpkg.txt; \
    sha256sum "$ENV_FILE" > /image-provenance/env-file.sha256; \
    git rev-parse HEAD > /image-provenance/xgboost.sha; \
    git -C dmlc-core rev-parse HEAD > /image-provenance/dmlc-core.sha
