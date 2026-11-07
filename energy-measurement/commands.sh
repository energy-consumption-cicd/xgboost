#!/usr/bin/env bash

# Literal transcription of job gtest-cpu-nonomp of misc.yml at ccb51176 (tag v3.1.0): `bash ops/pipeline/build-test-cpu-nonomp.sh`, split at ctest.
# The only addition is -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST: it points the configure-time googletest v1.14.0 fetch at the copy staged in the image.

set -eo pipefail
STAGE="${1:?stage required: build | test}"

REPORT_MISSING_EXIT=94

cd /home/runner/work/xgboost/xgboost

record_memory() {
  cp /sys/fs/cgroup/memory.peak /timing/memory_peak.txt 2>/dev/null || true
  cp /sys/fs/cgroup/memory.events /timing/memory_events.txt 2>/dev/null || true
}

trap record_memory EXIT

case "$STAGE" in

  build)
    # ops/pipeline/build-test-cpu-nonomp.sh, cmake and ninja; build/ is the per-run volume.
    set -x
    mkdir -p build
    pushd build
    cmake .. \
      -GNinja \
      -DUSE_OPENMP=OFF \
      -DHIDE_CXX_SYMBOLS=ON \
      -DGOOGLE_TEST=ON \
      -DUSE_DMLC_GTEST=ON \
      -DENABLE_ALL_WARNINGS=ON \
      -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF \
      -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=/opt/googletest-1.14.0 \
      -DBUILD_DEPRECATED_CLI=ON
    time ninja -v
    popd
    set +x
    # The tag writes the CLI binary of TestXGBoostCLI at the tree root, outside build/, the only directory the test container receives.
    cp xgboost build/xgboost-cli
    ;;

  test)
    # Same script, ctest; it runs testxgboost and dmlc_unit_tests, and googletest writes one per-case report per binary into this directory, the command is unchanged.
    # World-writable so the host, which owns /timing, can remove the reports the image user writes.
    mkdir -p /timing/gtest
    chmod 0777 /timing/gtest
    export GTEST_OUTPUT=xml:/timing/gtest/
    cp build/xgboost-cli xgboost
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
