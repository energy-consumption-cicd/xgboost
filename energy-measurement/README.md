# Energy measurement

No file of the upstream project is modified: this directory and
`.github/workflows/energy-measurement.yml` are the only additions, and
`git diff v3.1.0 --stat` on this branch lists only these five paths.

## What is measured

Two stages from job `gtest-cpu-nonomp` ("Test Google C++ unittest (CPU Non-OMP)") of
`.github/workflows/misc.yml` at commit `ccb511768e13d1670c10be07dea89d0edca138f3` (tag `v3.1.0`), with the
submodule `dmlc-core` at `8986b059` and `gputreeshap` at `40eae8c4`, unused by the CPU build. The job has no matrix and runs on `ubuntu-latest`. Among
the hosted jobs of the push CI it is the one that runs the full C++ unit suite with the default
toolchain: no SYCL plugin, no third-party container, no download at test time. The Python CPU
suite of `main.yml` runs on the project's own runners and is not measurable here.

| stage | command | origin |
|---|---|---|
| `build` | `cmake .. -GNinja -DUSE_OPENMP=OFF -DHIDE_CXX_SYMBOLS=ON -DGOOGLE_TEST=ON -DUSE_DMLC_GTEST=ON -DENABLE_ALL_WARNINGS=ON -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF -DBUILD_DEPRECATED_CLI=ON`, then `ninja -v` | `ops/pipeline/build-test-cpu-nonomp.sh` |
| `test` | `ctest --extra-verbose`, i.e. `testxgboost` (666 cases in 145 suites) and `dmlc_unit_tests` (70 cases in 17 suites, registered by the dmlc-core of this tag) and `TestXGBoostCLI` (`runxgboost` on `tests/cli/machine.conf`) | same script |

The job runs the script in one step; the two stages split it at the boundary between `ninja`
and `ctest`, with no command changed. There is no `train` stage: every booster is fitted inside
a googletest case.

The job installs `ninja-build` with `apt-get` and uses the toolchain of the hosted image; there is no compiler cache.
The image takes GCC 13.3.0, CMake 3.28.3 and ninja 1.11.1 from the Ubuntu 24.04 archive snapshot of 20251016T202232Z, the day of the tag
commit, and asserts these versions at build time. The stages run with
`--memory=12g` and no swap, on an internal Docker bridge created per run with no external route;
`run_pipeline.sh` verifies once per run, before the baseline, that the network has an `eth0` and
no route out. `memory.peak` and `memory.events` of the container cgroup are recorded per stage.

## Differences from the hosted job

- The job is the Non-OMP variant: `-DUSE_OPENMP=OFF`, so the boosters run single-threaded. The
  OpenMP variant of the same script runs only on the project's self-hosted runners.
- The hosted runner brings its own, newer CMake; the image uses the 3.28.3 of the archive.
- `dmlc-core` downloads googletest v1.14.0 at configure time (`FetchContent`, `URL`). The image carries the tarball, verified by sha256, and
  `commands.sh` adds `-DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=/opt/googletest-1.14.0` to the cmake command so the stages run offline.
- The build starts from an empty `build/` on every run and uses no compiler cache, as the hosted job does.
- The collective tests discover the local address through a UDP `connect` and reject loopback
  (`src/collective/tracker.cc`), which needs a default route. Inside the `test` container, before
  the measured block, `ip route add default dev eth0` gives that route on the internal bridge; no
  packet leaves it.
- `GTEST_OUTPUT=xml:<dir>/` is exported for the `test` stage so googletest writes one per-case report
  per test binary; the `ctest` command is unchanged.
- With `-DBUILD_DEPRECATED_CLI=ON` the build writes the CLI binary `xgboost` at the root of the source
  tree, outside `build/`, and `TestXGBoostCLI` runs it from there. The two stages run in separate containers
  that share only the `build/` volume, so `commands.sh` copies the binary into `build/xgboost-cli` at the
  end of `build` and back to the tree root at the start of `test`; `cmake` and `ctest` are unchanged.
- `ninja` runs with its default job count, `nproc + 2`: 10 on the measurement host against 6 on
  the hosted runner.

Expected exits: `build` 0 and `test` 0 (3 of 3 ctest tests) with 736 of 736 cases passing; a run is conform when
the two gtest reports list 736 cases with no failure.

## Build

```
docker build -t xgboost-measurement-3.1.0 -f energy-measurement/Dockerfile energy-measurement
```

The image holds the sources, the toolchain and googletest v1.14.0; it needs network access only at build time.

## Run

```
gh workflow run energy-measurement.yml -f campaign=validation
gh workflow run energy-measurement.yml -f campaign=full
```

`validation` runs run 0 only; `full` runs a warm-up, runs 1 to 10 and the median.
Results, including `gtest.xml`, the route applied in the `test`
container, the memory files per stage, the network check per run and the host swap and package temperature
sidecars read outside the RAPL window, are uploaded as a workflow artifact.

One run locally:

```
bash energy-measurement/run_pipeline.sh 1
```
