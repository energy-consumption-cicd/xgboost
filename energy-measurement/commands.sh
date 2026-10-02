#!/usr/bin/env bash

# Literal transcription of job gtest-cpu-nonomp of misc.yml at d5cd2b40 (tag v3.3.0): `bash ops/pipeline/build-cpu.sh cpu-nonomp`, split at ctest.

set -eo pipefail
STAGE="${1:?stage required: build | test}"

# sha256 of the sorted URL lines of the pre-registered lock, 62 packages.
LOCK_URLS_SHA256=41ad88efad07f6b3c257b366978e0226234969899b021a2fd04337d88f21daad
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
    # ops/pipeline/build-cpu.sh:13-14 and :34-45, case cpu-nonomp; build/ is the per-run volume.
    set -x
    mkdir -p build
    pushd build
    cmake .. \
      -GNinja \
      -DUSE_OPENMP=OFF \
      -DHIDE_CXX_SYMBOLS=ON \
      -DGOOGLE_TEST=ON \
      -DENABLE_ALL_WARNINGS=ON \
      -DCMAKE_C_COMPILER_LAUNCHER=sccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=sccache \
      -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF
    time ninja -v
    popd
    set +x
    # misc.yml:45, the step after the measured one; kept for the hit count of the cold cache.
    sccache --show-stats > /timing/sccache_stats.txt 2>&1 || true
    ;;

  test)
    # ops/pipeline/build-cpu.sh:46; ctest runs testxgboost and dmlc_unit_tests; googletest writes one per-case report per binary into this directory, the command is unchanged.
    # World-writable so the host, which owns /timing, can remove the reports the image user writes.
    mkdir -p /timing/gtest
    chmod 0777 /timing/gtest
    export GTEST_OUTPUT=xml:/timing/gtest/
    rc=0
    set -x
    pushd build
    ctest --extra-verbose || rc=$?
    popd
    set +x
    if { [ ! -f /timing/gtest/testxgboost.xml ] || [ ! -f /timing/gtest/dmlc_unit_tests.xml ]; } && [ "$rc" -lt "$REPORT_MISSING_EXIT" ]; then
      rc="$REPORT_MISSING_EXIT"
    fi
    exit "$rc"
    ;;

  *)
    echo "unknown stage: $STAGE" >&2
    exit 2
    ;;

esac
