# Energy measurement

No file of the upstream project is modified: this directory and
`.github/workflows/energy-measurement.yml` are the only additions, and
`git diff d2aa6ce1 --stat` on this branch lists only these five paths.

## What is measured

Two stages from job `gtest-cpu-nonomp` ("Test Google C++ unittest (CPU Non-OMP)") of
`.github/workflows/misc.yml` at commit `d2aa6ce17dd3270053b20c56440527e020293816`, with the
submodule `dmlc-core` at `ee879b7f`. The job has no matrix and runs on `ubuntu-latest`. Among
the hosted jobs of the push CI it is the one that runs the full C++ unit suite with the default
toolchain: no SYCL plugin, no third-party container, no download at test time. The Python CPU
suite of `main.yml` runs on the project's own runners and is not measurable here.

| stage | command | origin |
|---|---|---|
| `build` | `cmake .. -GNinja -DUSE_OPENMP=OFF -DHIDE_CXX_SYMBOLS=ON -DGOOGLE_TEST=ON -DENABLE_ALL_WARNINGS=ON -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF` with the sccache launchers, then `ninja -v` | `ops/pipeline/build-cpu.sh`, case `cpu-nonomp`, lines 28-38 |
| `test` | `ctest --extra-verbose`, i.e. `testxgboost`, 752 cases in 151 suites | same script, line 39 |

The job runs the script in one step; the two stages split it at the boundary between `ninja`
and `ctest`, with no command changed. There is no `train` stage: every booster is fitted inside
a googletest case.

The environment is the one the job creates with `mamba env create` from
`ops/conda_env/cpp_test.yml` (conda-forge, GCC 14.4.0, gtest 1.18.0, CMake 4.4.3, ninja 1.13.2);
the upstream file pins only `gcc_linux-64=14.*`, so the image verifies the resolved packages
against a 46-URL lock at build time and again at the start of each stage. The stages run with
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
- `GTEST_OUTPUT=xml:` is exported for the `test` stage so googletest writes a per-case report;
  the `ctest` command is unchanged.
- `ninja` runs with its default job count, `nproc + 2`: 10 on the measurement host against 6 on
  the hosted runner.
- Miniforge is pinned to `26.5.3-0`, the release the reference run resolved through `latest`.

Expected exits: `build` 0 and `test` 0 with 752 of 752 cases passing; a run is conform when
`gtest.xml` lists 752 cases with no failure.

## Build

```
docker build -t xgboost-medicao -f energy-measurement/Dockerfile energy-measurement
```

## Run

```
gh workflow run energy-measurement.yml -f campaign=validation
gh workflow run energy-measurement.yml -f campaign=full
```

`validation` runs run 0 only; `full` runs a warm-up, runs 1 to 10 and the median.
Results, including `gtest.xml`, the sccache statistics, the route applied in the `test`
container, the memory files per stage and the network check per run, are uploaded as a workflow
artifact.

One run locally:

```
bash energy-measurement/run_pipeline.sh 1
```
