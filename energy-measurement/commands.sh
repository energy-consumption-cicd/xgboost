#!/usr/bin/env bash

# Literal transcription of job gtest-cpu-nonomp of misc.yml at d2aa6ce1: `bash ops/pipeline/build-cpu.sh cpu-nonomp`, split at ctest.

set -eo pipefail
STAGE="${1:?stage required: build | test}"

# sha256 of the sorted URL lines of the pre-registered lock, 46 packages.
LOCK_URLS_SHA256=bb00220f3b0f324733640369253af5dcfdb92bbac611cf85f6f9f394e59a0bf8
LOCK_MISMATCH_EXIT=93
REPORT_MISSING_EXIT=94

cd /home/runner/work/xgboost/xgboost

# misc.yml:31-33, `shell: bash -l {0}`: the login shell activates the conda environment of the job.
source /home/runner/miniconda3/etc/profile.d/conda.sh
conda activate cpp_test
# dmlc/xgboost-devops/actions/sccache, step "Configure sccache (Unix)"; empty on every run.
export SCCACHE_DIR=/home/runner/.cache/sccache

if [ "$(conda list -n cpp_test --explicit | grep '^https://' | sort | sha256sum | cut -d' ' -f1)" != "$LOCK_URLS_SHA256" ]; then
  echo "the cpp_test environment does not match the pre-registered lock $LOCK_URLS_SHA256" >&2
  exit "$LOCK_MISMATCH_EXIT"
fi

record_memory() {
  cp /sys/fs/cgroup/memory.peak /timing/memory_peak.txt 2>/dev/null || true
  cp /sys/fs/cgroup/memory.events /timing/memory_events.txt 2>/dev/null || true
}

trap record_memory EXIT

case "$STAGE" in

  build)
    # Step "Start sccache server (Unix)" of the sccache action precedes the measured step in the job.
    sccache --start-server || true
    # ops/pipeline/build-cpu.sh:9-10 and :28-38, case cpu-nonomp; build/ is the per-run volume.
    set -x
    mkdir -p build
    pushd build
    cmake .. \
      -GNinja \
      -DUSE_OPENMP=OFF \
      -DHIDE_CXX_SYMBOLS=ON \
      -DGOOGLE_TEST=ON \
      -DENABLE_ALL_WARNINGS=ON \
      -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF \
      -DCMAKE_C_COMPILER_LAUNCHER=sccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=sccache
    time ninja -v
    popd
    set +x
    # misc.yml:45, the step after the measured one; kept for the hit count of the cold cache.
    sccache --show-stats > /timing/sccache_stats.txt 2>&1 || true
    ;;

  test)
    # ops/pipeline/build-cpu.sh:39; googletest writes the per-case report through this variable, the command is unchanged.
    export GTEST_OUTPUT=xml:/timing/gtest.xml
    rc=0
    set -x
    pushd build
    ctest --extra-verbose || rc=$?
    popd
    set +x
    if [ ! -f /timing/gtest.xml ] && [ "$rc" -lt "$REPORT_MISSING_EXIT" ]; then
      rc="$REPORT_MISSING_EXIT"
    fi
    exit "$rc"
    ;;

  *)
    echo "unknown stage: $STAGE" >&2
    exit 2
    ;;

esac
