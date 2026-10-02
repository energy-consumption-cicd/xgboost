# Energy measurement

No file of the upstream project is modified: this directory and
`.github/workflows/energy-measurement.yml` are the only additions, and
`git diff v3.2.0 --stat` on this branch lists only these five paths.

## What is measured

Two stages from job `gtest-cpu-nonomp` ("Test Google C++ unittest (CPU Non-OMP)") of
`.github/workflows/misc.yml` at commit `7991260512353c8f408adf2e2cea1a0d0b4b4468` (tag `v3.2.0`), with the
submodule `dmlc-core` at `4baa84e6` and `gputreeshap` at `40eae8c4`, unused by the CPU build. The job has no matrix and runs on `ubuntu-latest`. Among
the hosted jobs of the push CI it is the one that runs the full C++ unit suite with the default
toolchain: no SYCL plugin, no third-party container, no download at test time. The Python CPU
suite of `main.yml` runs on the project's own runners and is not measurable here.

| stage | command | origin |
|---|---|---|
| `build` | `cmake .. -GNinja -DUSE_OPENMP=OFF -DHIDE_CXX_SYMBOLS=ON -DGOOGLE_TEST=ON -DENABLE_ALL_WARNINGS=ON` with the sccache launchers and `-DCMAKE_COMPILE_WARNING_AS_ERROR=OFF`, then `ninja -v` | `ops/pipeline/build-cpu.sh`, case `cpu-nonomp`, lines 13-14 and :34-45 |
| `test` | `ctest --extra-verbose`, i.e. `testxgboost` (685 cases in 146 suites) and `dmlc_unit_tests` (70 cases in 17 suites, registered by the dmlc-core of this tag) | same script, line 46 |

The job runs the script in one step; the two stages split it at the boundary between `ninja`
and `ctest`, with no command changed. There is no `train` stage: every booster is fitted inside
a googletest case.

The environment is the one the job creates with `mamba env create` from
`ops/conda_env/cpp_test.yml` (conda-forge, GCC 14.4.0, gtest 1.18.0, CMake 4.4.3, ninja 1.13.2, libprotobuf 7.35.1, libgrpc 1.83.1);
the upstream file pins no version, so the image verifies the resolved packages
against a 62-URL lock, resolved by the rehearsal of this tag, at build time and again at the start of each stage. The stages run with
`--memory=12g` and no swap, on an internal Docker bridge created per run with no external route;
`run_pipeline.sh` verifies once per run, before the baseline, that the network has an `eth0` and
no route out. `memory.peak` and `memory.events` of the container cgroup are recorded per stage.

## Differences from the hosted job

- The job is the Non-OMP variant: `-DUSE_OPENMP=OFF`, so the boosters run single-threaded. The
  OpenMP variant of the same script runs only on the project's self-hosted runners.
- The sccache directory lives inside the container and starts empty on every run, so `build`
  measures a full compilation. The hosted job restores a cache through `actions/cache`; the
  reference run hit it for 2 of 242 compilations.
- The collective tests discover the local address through a UDP `connect` and reject loopback
  (`src/collective/tracker.cc`), which needs a default route. Inside the `test` container, before
  the measured block, `ip route add default dev eth0` gives that route on the internal bridge; no
  packet leaves it.
- `GTEST_OUTPUT=xml:<dir>/` is exported for the `test` stage so googletest writes one per-case report
  per test binary; the `ctest` command is unchanged.
- `ninja` runs with its default job count, `nproc + 2`: 10 on the measurement host against 6 on
  the hosted runner.
- Miniforge is pinned to `26.5.3-0`, the release the reference run resolved through `latest`.

Expected exits: `build` 0 and `test` 0 with 755 of 755 cases passing; a run is conform when
the two gtest reports list 755 cases with no failure.

## Build

```
docker build -t xgboost-measurement-3.2.0 -f energy-measurement/Dockerfile energy-measurement
```

## Run

```
gh workflow run energy-measurement.yml -f campaign=validation
gh workflow run energy-measurement.yml -f campaign=full
```

`validation` runs run 0 only; `full` runs a warm-up, runs 1 to 10 and the median.
Results, including `gtest.xml`, the sccache statistics, the route applied in the `test`
container, the memory files per stage, the network check per run and the host swap and package temperature
sidecars read outside the RAPL window, are uploaded as a workflow artifact.

One run locally:

```
bash energy-measurement/run_pipeline.sh 1
```
