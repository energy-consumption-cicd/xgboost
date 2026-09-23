#!/usr/bin/env bash

set -euo pipefail
# Numeric formatting in awk must not follow the locale of the invoking shell.
export LC_ALL=C

RUN_NUM="${1:?run number required (e.g. 1)}"
PROJECT_NAME="xgboost"
IMAGE_NAME="${IMAGE_NAME:-xgboost-medicao}"
MEDICAO_DIR="${MEDICAO_DIR:-$HOME/experimentos/medicao/repositorios/xgboost}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/experimentos/medicao/resultados/xgboost/runs}"
LOGS_DIR="${LOGS_DIR:-$HOME/experimentos/medicao/resultados/xgboost/logs}"
RAPL_BASE="/sys/class/powercap/intel-rapl"
# Its per-second rate is subtracted from the stage, so energy is workload above idle.
BASELINE_DURATION=120
# Above this the bench is not idle and the run is not started; 90 is outside the declared exits.
BASELINE_GATE_MAX_PKG_W=1.0
BASELINE_GATE_EXIT=90
ENERGY_BASELINE_GATE="${ENERGY_BASELINE_GATE:-on}"
# Pre-registered ceilings per stage; 91 is outside the declared exits, like 90.
STAGE_TIMEOUT_BUILD_DEFAULT=400
STAGE_TIMEOUT_TEST_DEFAULT=120
ENERGY_STAGE_TIMEOUT_BUILD_S="${ENERGY_STAGE_TIMEOUT_BUILD_S:-$STAGE_TIMEOUT_BUILD_DEFAULT}"
ENERGY_STAGE_TIMEOUT_TEST_S="${ENERGY_STAGE_TIMEOUT_TEST_S:-$STAGE_TIMEOUT_TEST_DEFAULT}"
STAGE_TIMEOUT_EXIT=91
NETWORK_CHECK_EXIT=92
# The collective tests need a default route to pick a source address; 95 is outside the declared exits.
ROUTE_MISSING_EXIT=95
# Empty on the campaign, which applies no CPU limit.
ENERGY_CPUSET="${ENERGY_CPUSET:-}"
TIME_FILE="/tmp/xgboost_time_$$.txt"
RUN_ID=$(printf '%02d' "$RUN_NUM")
CSV_FILE="$RESULTS_DIR/run_${RUN_ID}.csv"
EXITS_FILE="$RESULTS_DIR/exit_codes_run_${RUN_ID}.txt"
ARTIFACT_FILE="$RESULTS_DIR/artifact_check_run_${RUN_ID}.txt"
NETWORK_FILE="$RESULTS_DIR/network_check_run_${RUN_ID}.txt"
BASELINE_DISCARD_FILE="$RESULTS_DIR/discarded_baseline_run_${RUN_ID}.txt"
TIMEOUT_DISCARD_FILE="$RESULTS_DIR/discarded_timeout_run_${RUN_ID}.txt"
NETWORK_DISCARD_FILE="$RESULTS_DIR/discarded_network_run_${RUN_ID}.txt"
# Each stage is a new container; build/ reaches the test stage through this per-run volume.
BUILD_VOLUME="xgboost-build-run${RUN_ID}"
BUILD_DIR=/home/runner/work/xgboost/xgboost/build
# Internal bridge per run, no external route: the collective tests need an eth0 and a default route through it.
NETWORK_NAME="energy-internal-run${RUN_ID}"
ENV_PYTHON=/home/runner/miniconda3/bin/python

# No swap inside the container: the limit is the bench's usable RAM.
MEM_LIMIT="${MEM_LIMIT:-12g}"
MEM_SWAP="${MEM_SWAP:-$MEM_LIMIT}"

# Pre-registered exits and counts; a divergence does not change the recorded exit.
EXPECTED_EXIT_BUILD=0
EXPECTED_EXIT_TEST=0
TEST_EXPECTED_TOTAL=752
TEST_EXPECTED_FAILED=()
PIPELINE_EXIT=0
FAILED_STAGES=""
NONCONFORM_STAGES=""

# A signal to the docker client does not stop the container; kill it by name.
CURRENT_CONTAINER=""
cleanup_container() {
  if [ -n "$CURRENT_CONTAINER" ]; then
    docker kill "$CURRENT_CONTAINER" >/dev/null 2>&1 || true
    docker rm -f "$CURRENT_CONTAINER" >/dev/null 2>&1 || true
  fi
  docker volume rm -f "$BUILD_VOLUME" >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
}
trap cleanup_container EXIT INT TERM

mkdir -p "$RESULTS_DIR" "$LOGS_DIR"

if [ ! -d "$RAPL_BASE" ]; then
  echo "RAPL not available at $RAPL_BASE" >&2
  exit 1
fi

if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "Docker image '$IMAGE_NAME' not found." >&2
  echo "  Build it first, from a checkout of this repository:" >&2
  echo "  docker build -t $IMAGE_NAME -f energy-measurement/Dockerfile energy-measurement" >&2
  exit 1
fi

: > "$EXITS_FILE"
: > "$ARTIFACT_FILE"

# Records which RAPL domains the bench exposes, so a zero column is auditable.
for d in "$RAPL_BASE"/*/ "$RAPL_BASE"/*/*/; do [ -f "$d/name" ] && printf '%s,%s\n' "$(basename "$d")" "$(cat "$d/name")"; done > "$RESULTS_DIR/rapl_domains_run_${RUN_ID}.txt"

# Hermeticity of the internal bridge, verified once per run before the baseline, outside the RAPL window.
# Conform when the container has eth0, no default route, and a connect by address fails by route; the route is added only inside the test container.
network_check() {
  local verdict
  docker run --rm -i --network "$NETWORK_NAME" "$IMAGE_NAME" "$ENV_PYTHON" - <<'PY' > "$NETWORK_FILE" 2>&1 || true
import errno, socket
names = [n for _, n in socket.if_nameindex()]
print("interfaces," + " ".join(names))
default_route = any(
    line.split()[1] == "00000000" for line in open("/proc/net/route").read().splitlines()[1:] if line.strip()
)
print("default_route," + ("yes" if default_route else "no"))
try:
    socket.create_connection(("1.1.1.1", 443), timeout=5).close()
    outcome = "connected"
except socket.timeout:
    outcome = "timeout"
except OSError as e:
    outcome = errno.errorcode.get(e.errno, str(e.errno))
print("connect_1.1.1.1_443," + outcome)
try:
    socket.getaddrinfo("github.com", 443)
    dns = "resolved"
except OSError as e:
    dns = "failed"
print("dns_github.com," + dns)
ok = ("eth0" in names) and (not default_route) and outcome == "ENETUNREACH"
print("verdict," + ("no_external_route" if ok else "external_route_or_no_eth0"))
PY
  echo "network_utc,$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$NETWORK_FILE"
  if grep -q '^verdict,no_external_route$' "$NETWORK_FILE"; then
    verdict="conform"
  else
    verdict="nonconform"
  fi
  echo "  network check ($NETWORK_NAME): $verdict"
  if [ "$verdict" != "conform" ]; then
    {
      echo "run,$RUN_NUM"
      echo "timestamp_utc,$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "reason,the internal network has an external route, no eth0, or the check did not run"
      cat "$NETWORK_FILE"
    } > "$NETWORK_DISCARD_FILE"
    echo "::error title=Network check::run $RUN_NUM: the internal network failed the hermeticity check. Run not started; see $NETWORK_DISCARD_FILE"
    rm -f "$EXITS_FILE" "$ARTIFACT_FILE"
    exit "$NETWORK_CHECK_EXIT"
  fi
}

read_rapl() {
  local domain_name="$1"
  local value=0
  for dir in "$RAPL_BASE"/*/; do
    local name_file="$dir/name"
    [ -f "$name_file" ] || continue
    local name
    name=$(cat "$name_file")
    if [[ "$name" == "package-0" && "$domain_name" == "pkg" ]] || \
       [[ "$name" == "core"      && "$domain_name" == "cores" ]] || \
       [[ "$name" == "uncore"    && "$domain_name" == "gpu" ]] || \
       [[ "$name" == "dram"      && "$domain_name" == "ram" ]]; then
      local energy_file="$dir/energy_uj"
      [ -f "$energy_file" ] && value=$(cat "$energy_file") && break
    fi
    for subdir in "$dir"*/; do
      local sub_name_file="$subdir/name"
      [ -f "$sub_name_file" ] || continue
      local sub_name
      sub_name=$(cat "$sub_name_file")
      if [[ "$sub_name" == "core"   && "$domain_name" == "cores" ]] || \
         [[ "$sub_name" == "uncore" && "$domain_name" == "gpu" ]] || \
         [[ "$sub_name" == "dram"   && "$domain_name" == "ram" ]]; then
        local sub_energy="$subdir/energy_uj"
        [ -f "$sub_energy" ] && value=$(cat "$sub_energy") && break 2
      fi
    done
  done
  echo "$value"
}

read_rapl_max() {
  local domain_name="$1"
  local value=0
  for dir in "$RAPL_BASE"/*/; do
    local name_file="$dir/name"
    [ -f "$name_file" ] || continue
    local name
    name=$(cat "$name_file")
    if [[ "$name" == "package-0" && "$domain_name" == "pkg" ]]; then
      local max_file="$dir/max_energy_range_uj"
      [ -f "$max_file" ] && value=$(cat "$max_file") && break
    fi
    for subdir in "$dir"*/; do
      local sub_name_file="$subdir/name"
      [ -f "$sub_name_file" ] || continue
      local sub_name
      sub_name=$(cat "$sub_name_file")
      if [[ "$sub_name" == "core"   && "$domain_name" == "cores" ]] || \
         [[ "$sub_name" == "uncore" && "$domain_name" == "gpu" ]] || \
         [[ "$sub_name" == "dram"   && "$domain_name" == "ram" ]]; then
        local sub_max="$subdir/max_energy_range_uj"
        [ -f "$sub_max" ] && value=$(cat "$sub_max") && break 2
      fi
    done
  done
  [ "$value" -eq 0 ] && value=999999999999
  echo "$value"
}

# RAPL counters wrap at max_energy_range_uj; deltas are overflow-corrected.
delta_uj() {
  local ini="$1" fin="$2" max="$3"
  if [ "$fin" -ge "$ini" ]; then
    echo $(( fin - ini ))
  else
    echo $(( max - ini + fin ))
  fi
}
echo ""
echo ""
echo " Run $RUN_NUM - $PROJECT_NAME"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
docker network create --internal --driver bridge "$NETWORK_NAME" >/dev/null
network_check
docker volume rm -f "$BUILD_VOLUME" >/dev/null 2>&1 || true
docker volume create "$BUILD_VOLUME" >/dev/null
echo ""
echo "Baseline rest (${BASELINE_DURATION}s)..."

b_pkg_ini=$(read_rapl pkg)
b_cores_ini=$(read_rapl cores)
b_gpu_ini=$(read_rapl gpu)
b_ram_ini=$(read_rapl ram)

sleep "$BASELINE_DURATION"

b_pkg_fin=$(read_rapl pkg)
b_cores_fin=$(read_rapl cores)
b_gpu_fin=$(read_rapl gpu)
b_ram_fin=$(read_rapl ram)

max_pkg=$(read_rapl_max pkg)
max_cores=$(read_rapl_max cores)
max_gpu=$(read_rapl_max gpu)
max_ram=$(read_rapl_max ram)

b_delta_pkg=$(delta_uj "$b_pkg_ini" "$b_pkg_fin" "$max_pkg")
b_delta_cores=$(delta_uj "$b_cores_ini" "$b_cores_fin" "$max_cores")
b_delta_gpu=$(delta_uj "$b_gpu_ini" "$b_gpu_fin" "$max_gpu")
b_delta_ram=$(delta_uj "$b_ram_ini" "$b_ram_fin" "$max_ram")

taxa_pkg=$(awk  "BEGIN {printf \"%.6f\", $b_delta_pkg  / $BASELINE_DURATION}")
taxa_cores=$(awk "BEGIN {printf \"%.6f\", $b_delta_cores / $BASELINE_DURATION}")
taxa_gpu=$(awk  "BEGIN {printf \"%.6f\", $b_delta_gpu  / $BASELINE_DURATION}")
taxa_ram=$(awk  "BEGIN {printf \"%.6f\", $b_delta_ram  / $BASELINE_DURATION}")

# The rate drives the subtraction, so it is recorded beside the energy it produced.
taxa_pkg_w=$(awk   "BEGIN {printf \"%.6f\", $taxa_pkg   / 1e6}")
taxa_cores_w=$(awk "BEGIN {printf \"%.6f\", $taxa_cores / 1e6}")
taxa_ram_w=$(awk   "BEGIN {printf \"%.6f\", $taxa_ram   / 1e6}")

echo "Baseline rate:"
echo "   pkg:   $(awk "BEGIN {printf \"%.2f\", $taxa_pkg_w}") W"
echo "   cores: $(awk "BEGIN {printf \"%.2f\", $taxa_cores_w}") W"
echo "   ram:   $(awk "BEGIN {printf \"%.2f\", $taxa_ram_w}") W"

if [ "$ENERGY_BASELINE_GATE" != "off" ] && \
   awk "BEGIN {exit !($taxa_pkg_w > $BASELINE_GATE_MAX_PKG_W)}"; then
  {
    echo "run,$RUN_NUM"
    echo "timestamp_utc,$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "baseline_rate_pkg_w,$taxa_pkg_w"
    echo "baseline_rate_cores_w,$taxa_cores_w"
    echo "baseline_rate_ram_w,$taxa_ram_w"
    echo "threshold_pkg_w,$BASELINE_GATE_MAX_PKG_W"
  } > "$BASELINE_DISCARD_FILE"
  echo "::error title=Baseline gate::run $RUN_NUM: idle package rate ${taxa_pkg_w} W exceeds ${BASELINE_GATE_MAX_PKG_W} W; the bench is not idle. Run not started; see $BASELINE_DISCARD_FILE"
  rm -f "$EXITS_FILE" "$ARTIFACT_FILE"
  exit "$BASELINE_GATE_EXIT"
fi
if [ "$ENERGY_BASELINE_GATE" = "off" ]; then
  echo "::warning title=Baseline gate disabled::ENERGY_BASELINE_GATE=off for run $RUN_NUM (diagnostic session; must be declared)"
fi
for s in BUILD TEST; do
  cur="ENERGY_STAGE_TIMEOUT_${s}_S"; def="STAGE_TIMEOUT_${s}_DEFAULT"
  if [ "${!cur}" != "${!def}" ]; then
    echo "::warning title=Stage ceiling changed::${s,,} ${!cur}s for run $RUN_NUM (pre-registered ${!def}s; diagnostic session; must be declared)"
  fi
done
if [ -n "$ENERGY_CPUSET" ]; then
  echo "::warning title=CPU set pinned::ENERGY_CPUSET=$ENERGY_CPUSET for run $RUN_NUM (rehearsal only; the campaign applies no CPU limit)"
fi

echo "run,stage,energy_pkg_j,energy_cores_j,energy_gpu_j,energy_ram_j,wall_time_s,user_time_s,sys_time_s,energy_ram_liquid_raw_j,wall_time_container_s,baseline_rate_pkg_w,baseline_rate_cores_w,baseline_rate_ram_w,cpu_time_cgroup_s" \
  > "$CSV_FILE"

total_pkg=0; total_cores=0; total_gpu=0; total_ram=0; total_ram_raw=0
total_wall=0; total_user=0; total_sys=0; total_wall_container=0; total_cpu_cgroup=0

# Ceiling reached: no measurement exists, so no CSV row, only the sidecar.
abort_stage_timeout() {
  local stage="$1" ceiling="$2" texit="$3" cname="$4" start_utc="$5" stage_log="$6" wall="$7"
  local abort_utc kill_result marker last_line last_utc
  abort_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if docker kill "$cname" >/dev/null 2>&1; then kill_result="ok"; else kill_result="no-such-container"; fi
  docker rm -f "$cname" >/dev/null 2>&1 || true
  CURRENT_CONTAINER=""
  # Every lookup below may legitimately find nothing; none may trip errexit.
  marker=$(grep -E '^=== .*: start ' "$stage_log" 2>/dev/null | tail -n 1 || true)
  last_line=$(tail -n 1 "$stage_log" 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | cut -c1-200 || true)
  last_utc=$(date -u -r "$stage_log" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "-")
  {
    echo "run,$RUN_NUM"
    echo "stage,$stage"
    echo "timeout_s,$ceiling"
    echo "timeout_exit,$texit"
    echo "start_utc,$start_utc"
    echo "abort_utc,$abort_utc"
    echo "wall_observed_s,$wall"
    echo "container,$cname"
    echo "docker_kill,$kill_result"
    echo "stage_log,logs/$(basename "$stage_log")"
    echo "last_step_marker,${marker:--}"
    echo "last_log_line_utc,$last_utc"
    echo "last_log_line,${last_line:--}"
    echo "csv_row_written,no"
  } > "$TIMEOUT_DISCARD_FILE"
  echo "$RUN_NUM,$stage,$STAGE_TIMEOUT_EXIT" >> "$EXITS_FILE"
  rm -f "$CSV_FILE" "$TIME_FILE"
  echo "::error title=Stage ceiling::run $RUN_NUM, stage '$stage': ${wall}s exceeded the ${ceiling}s ceiling (timeout exit $texit); container $cname killed ($kill_result). No CSV; see $TIMEOUT_DISCARD_FILE"
  exit "$STAGE_TIMEOUT_EXIT"
}
# Conformity per stage: the expected exit, no OOM kill and, for test, the case counts of gtest.xml.
check_stage() {
  local stage="$1" stage_exit="$2" report="$3" mem_events="$4" mem_peak="$5"
  local expected verdict oom_kill peak counts total failed errors disabled set_match failed_ids
  case "$stage" in
    build) expected="$EXPECTED_EXIT_BUILD" ;;
    test)  expected="$EXPECTED_EXIT_TEST" ;;
  esac
  verdict="conform"
  [ "$stage_exit" -eq "$expected" ] || verdict="nonconform"
  oom_kill=$(awk '$1=="oom_kill" {print $2}' "$mem_events" 2>/dev/null || true)
  peak=$(cat "$mem_peak" 2>/dev/null || true)
  [ "${oom_kill:-0}" = "0" ] || verdict="nonconform"
  {
    echo "${stage}_exit,$stage_exit"
    echo "${stage}_expected_exit,$expected"
    echo "${stage}_memory_peak_bytes,${peak:--}"
    echo "${stage}_oom_kill,${oom_kill:--}"
  } >> "$ARTIFACT_FILE"
  if [ "$stage" = "test" ]; then
    if [ -f "$report" ]; then
      counts=$(python3 - "$report" "$TEST_EXPECTED_TOTAL" "${TEST_EXPECTED_FAILED[@]}" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
expected_total = int(sys.argv[2])
expected = sorted(sys.argv[3:])
cases = list(root.iter("testcase"))
failed, errors, disabled = [], [], 0
for c in cases:
    nodeid = c.get("classname", "") + "." + c.get("name", "")
    if c.find("failure") is not None:
        failed.append(nodeid)
    elif c.find("error") is not None:
        errors.append(nodeid)
    elif c.get("status") == "notrun":
        disabled += 1
# googletest lists DISABLED_ cases as notrun; the pre-registered 752 is the number of cases ctest runs.
run = len(cases) - disabled
match = "yes" if run == expected_total and sorted(failed) == expected and not errors else "no"
print(run, len(failed), len(errors), disabled, match, "|".join(sorted(failed + errors)) or "-")
PY
      ) || counts="- - - - no -"
    else
      counts="- - - - no -"
    fi
    read -r total failed errors disabled set_match failed_ids <<< "$counts"
    [ "$set_match" = "yes" ] || verdict="nonconform"
    {
      echo "test_report,$([ -f "$report" ] && echo yes || echo no)"
      echo "test_cases_run,$total"
      echo "test_failed,$failed"
      echo "test_errors,$errors"
      echo "test_disabled,$disabled"
      echo "test_set_match,$set_match"
      echo "test_failed_ids,$failed_ids"
    } >> "$ARTIFACT_FILE"
    echo "  test check: exit=$stage_exit cases=$total failed=$failed errors=$errors disabled=$disabled"
  fi
  echo "${stage}_verdict,$verdict" >> "$ARTIFACT_FILE"
  echo "  $stage check: exit=$stage_exit oom_kill=${oom_kill:--} memory_peak=${peak:--} -> $verdict"
  [ "$verdict" = "conform" ] || NONCONFORM_STAGES="${NONCONFORM_STAGES:+$NONCONFORM_STAGES }$stage"
}
measure_stage() {
  local stage="$1"
  echo ""
  echo " Stage: $stage - $(date '+%H:%M:%S')"

  local timing_dir
  timing_dir=$(mktemp -d)
  # The stages run as the image user, not as the owner of this directory.
  chmod 0777 "$timing_dir"

  local stage_log="$LOGS_DIR/run_${RUN_ID}_${stage}.log"
  local stage_exit=0
  local stage_timeout cname stage_start_utc carry
  # Outside the inner `time`: the test container starts as root only to add the default route through eth0, exits 95 without it, and drops to the image user before the measured block.
  local user_args=()
  case "$stage" in
    build)
      stage_timeout="$ENERGY_STAGE_TIMEOUT_BUILD_S"
      carry='run_stage'
      ;;
    test)
      stage_timeout="$ENERGY_STAGE_TIMEOUT_TEST_S"
      user_args=(--user root)
      carry='ip route add default dev eth0; ip route > /timing/route.txt; grep -q "^default" /timing/route.txt || exit '"$ROUTE_MISSING_EXIT"'; exec setpriv --reuid=runner --regid=runner --init-groups env HOME=/home/runner bash -c "$(declare -f run_stage); run_stage"'
      ;;
  esac
  cname="xgboost-run${RUN_ID}-${stage}"
  # A residual container of the same name is exactly the case the ceiling exists for.
  docker rm -f "$cname" >/dev/null 2>&1 || true

  local cpuset_args=()
  if [ -n "$ENERGY_CPUSET" ]; then
    cpuset_args=(--cpuset-cpus="$ENERGY_CPUSET")
  fi

  local ini_pkg ini_cores ini_gpu ini_ram
  ini_pkg=$(read_rapl pkg)
  ini_cores=$(read_rapl cores)
  ini_gpu=$(read_rapl gpu)
  ini_ram=$(read_rapl ram)

  CURRENT_CONTAINER="$cname"
  stage_start_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  set +e
  # The internal network has eth0 and no external route; the image holds every input.
  # fd3 keeps the workload stderr while `time` measures inside the container.
  # The sccache server compiles as a daemon outside the tree `time` accounts for; the container cgroup counts it.
  /usr/bin/time -f "%e" -o "$TIME_FILE" \
    timeout --foreground -s TERM -k 30 "$stage_timeout" \
    docker run --rm --name "$cname" --privileged --network "$NETWORK_NAME" \
      --memory="$MEM_LIMIT" --memory-swap="$MEM_SWAP" \
      "${cpuset_args[@]}" "${user_args[@]}" \
      -v "$MEDICAO_DIR:/medicao:ro" \
      -v "$timing_dir:/timing" \
      -v "$BUILD_VOLUME:$BUILD_DIR" \
      -e "STAGE=$stage" \
      "$IMAGE_NAME" \
      bash -c 'run_stage() { C0=$(grep ^usage_usec /sys/fs/cgroup/cpu.stat | cut -d" " -f2 || echo ""); exec 3>&2; TIMEFORMAT="%R %U %S"; { time bash /medicao/commands.sh "$STAGE" 2>&3; } 2>/timing/time.txt; rc=$?; C1=$(grep ^usage_usec /sys/fs/cgroup/cpu.stat | cut -d" " -f2 || echo ""); echo "$C0 $C1" > /timing/cpu.txt; return $rc; }; '"$carry" \
      2>&1 | tee "$stage_log"
  stage_exit=${PIPESTATUS[0]}
  set -e
  local wall_now
  wall_now=$(tail -n 1 "$TIME_FILE" 2>/dev/null || echo 0)
  [[ "$wall_now" =~ ^[0-9]+(\.[0-9]+)?$ ]] || wall_now=0
  # 137 is also the workload's own SIGKILL exit, so the wall has to confirm the ceiling.
  if [ "$stage_exit" -eq 124 ] || { [ "$stage_exit" -eq 137 ] && awk "BEGIN {exit !($wall_now >= $stage_timeout)}"; }; then
    rm -rf "$timing_dir"
    abort_stage_timeout "$stage" "$stage_timeout" "$stage_exit" "$cname" "$stage_start_utc" "$stage_log" "$wall_now"
  fi

  local fin_pkg fin_cores fin_gpu fin_ram
  fin_pkg=$(read_rapl pkg)
  fin_cores=$(read_rapl cores)
  fin_gpu=$(read_rapl gpu)
  fin_ram=$(read_rapl ram)
  echo "  stage log: $stage_log"

  # The exit is the rejection criterion; the measurement is kept either way.
  echo "$RUN_NUM,$stage,$stage_exit" >> "$EXITS_FILE"
  if [ "$stage_exit" -ne 0 ]; then
    echo "  stage '$stage': container exited with exit=$stage_exit (measurement PRESERVED, see $EXITS_FILE)"
    PIPELINE_EXIT="$stage_exit"
    FAILED_STAGES="${FAILED_STAGES:+$FAILED_STAGES }$stage(exit=$stage_exit)"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "::warning title=Stage exited non-zero::Run $RUN_NUM, stage '$stage': exit=$stage_exit. The CSV row WAS written."
    fi
  else
    echo "  stage '$stage': container exited 0"
  fi
  local report_file="$RESULTS_DIR/gtest_run_${RUN_ID}_${stage}.xml"
  local sccache_file="$RESULTS_DIR/sccache_stats_run_${RUN_ID}_${stage}.txt"
  local route_file="$RESULTS_DIR/route_run_${RUN_ID}_${stage}.txt"
  local mem_peak_file="$RESULTS_DIR/memory_peak_run_${RUN_ID}_${stage}.txt"
  local mem_events_file="$RESULTS_DIR/memory_events_run_${RUN_ID}_${stage}.txt"
  rm -f "$report_file" "$sccache_file" "$route_file" "$mem_peak_file" "$mem_events_file"
  local pair
  for pair in "gtest.xml:$report_file" "sccache_stats.txt:$sccache_file" "route.txt:$route_file" "memory_peak.txt:$mem_peak_file" "memory_events.txt:$mem_events_file"; do
    if [ -f "$timing_dir/${pair%%:*}" ]; then cp -f "$timing_dir/${pair%%:*}" "${pair#*:}"; fi
  done
  check_stage "$stage" "$stage_exit" "$report_file" "$mem_events_file" "$mem_peak_file"
  CURRENT_CONTAINER=""
  local wall wall_container_t user_t sys_t
  # GNU time prepends a status line on non-zero exit; the elapsed value is last.
  wall=$(tail -n 1 "$TIME_FILE")
  if ! [[ "$wall" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "  non-numeric wall_time ('$wall') - writing 0 and continuing" >&2
    wall="0.00"
  fi
  if [ -f "$timing_dir/time.txt" ]; then
    read -r wall_container_t user_t sys_t < "$timing_dir/time.txt"
  else
    wall_container_t="0.000"; user_t="0.000"; sys_t="0.000"
  fi
  local cpu_cgroup_t="0.000" c0 c1
  if [ -f "$timing_dir/cpu.txt" ]; then
    read -r c0 c1 < "$timing_dir/cpu.txt"
    if [[ "${c0:-}" =~ ^[0-9]+$ && "${c1:-}" =~ ^[0-9]+$ && "$c1" -ge "$c0" ]]; then
      cpu_cgroup_t=$(awk "BEGIN {printf \"%.3f\", ($c1 - $c0) / 1e6}")
    else
      echo "  cpu.stat of the container cgroup unreadable ('${c0:-}' '${c1:-}') - cpu_time_cgroup_s=0" >&2
    fi
  else
    echo "  cpu.txt missing - cpu_time_cgroup_s=0" >&2
  fi
  rm -rf "$timing_dir"

  local d_pkg d_cores d_gpu d_ram
  d_pkg=$(delta_uj   "$ini_pkg"   "$fin_pkg"   "$max_pkg")
  d_cores=$(delta_uj "$ini_cores" "$fin_cores" "$max_cores")
  d_gpu=$(delta_uj   "$ini_gpu"   "$fin_gpu"   "$max_gpu")
  d_ram=$(delta_uj   "$ini_ram"   "$fin_ram"   "$max_ram")

  local j_pkg j_cores j_gpu j_ram j_ram_raw
  j_pkg=$(awk   "BEGIN {v=($d_pkg   - $taxa_pkg   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_cores=$(awk "BEGIN {v=($d_cores - $taxa_cores * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_gpu=$(awk   "BEGIN {v=($d_gpu   - $taxa_gpu   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_ram=$(awk   "BEGIN {v=($d_ram   - $taxa_ram   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")

  j_ram_raw=$(awk "BEGIN {printf \"%.6f\", ($d_ram - $taxa_ram * $wall) / 1e6}")

  # Printed per domain so the closing check does not reconstruct them from the CSV.
  local dom d t j
  for dom in pkg cores gpu ram; do
    case "$dom" in
      pkg)   d="$d_pkg";   t="$taxa_pkg";   j="$j_pkg" ;;
      cores) d="$d_cores"; t="$taxa_cores"; j="$j_cores" ;;
      gpu)   d="$d_gpu";   t="$taxa_gpu";   j="$j_gpu" ;;
      ram)   d="$d_ram";   t="$taxa_ram";   j="$j_ram" ;;
    esac
    echo "  ${dom}: delta=${d}uJ baseline=$(awk "BEGIN {printf \"%.0f\", $t * $wall}")uJ net=$(awk "BEGIN {printf \"%.3f\", ($d - $t * $wall) / 1e6}")J clamped=${j}J"
  done

  echo "$RUN_NUM,$stage,$j_pkg,$j_cores,$j_gpu,$j_ram,$wall,$user_t,$sys_t,$j_ram_raw,$wall_container_t,$taxa_pkg_w,$taxa_cores_w,$taxa_ram_w,$cpu_cgroup_t" >> "$CSV_FILE"

  total_pkg=$(awk   "BEGIN {printf \"%.6f\", $total_pkg   + $j_pkg}")
  total_cores=$(awk "BEGIN {printf \"%.6f\", $total_cores + $j_cores}")
  total_gpu=$(awk   "BEGIN {printf \"%.6f\", $total_gpu   + $j_gpu}")
  total_ram=$(awk   "BEGIN {printf \"%.6f\", $total_ram   + $j_ram}")
  total_ram_raw=$(awk "BEGIN {printf \"%.6f\", $total_ram_raw + $j_ram_raw}")
  total_wall=$(awk  "BEGIN {printf \"%.3f\", $total_wall  + $wall}")
  total_user=$(awk  "BEGIN {printf \"%.3f\", $total_user  + $user_t}")
  total_sys=$(awk   "BEGIN {printf \"%.3f\", $total_sys   + $sys_t}")
  total_wall_container=$(awk "BEGIN {printf \"%.3f\", $total_wall_container + $wall_container_t}")
  total_cpu_cgroup=$(awk "BEGIN {printf \"%.3f\", $total_cpu_cgroup + $cpu_cgroup_t}")

  echo "    pkg: ${j_pkg}J | cores: ${j_cores}J | ram: ${j_ram}J | wall: ${wall}s | cpu_cgroup: ${cpu_cgroup_t}s"
}
# The job's order: the library and testxgboost are compiled, then ctest runs the binary.
measure_stage build
measure_stage test
if [ -z "$NONCONFORM_STAGES" ]; then
  echo "verdict,conform" >> "$ARTIFACT_FILE"
else
  echo "verdict,nonconform" >> "$ARTIFACT_FILE"
  echo "::warning title=Artifact check failed::run $RUN_NUM, stage(s) $NONCONFORM_STAGES did not meet the pre-registered criterion; see $ARTIFACT_FILE. CSV rows kept, exit unchanged"
fi

echo "$RUN_NUM,total,$total_pkg,$total_cores,$total_gpu,$total_ram,$total_wall,$total_user,$total_sys,$total_ram_raw,$total_wall_container,$taxa_pkg_w,$taxa_cores_w,$taxa_ram_w,$total_cpu_cgroup" \
  >> "$CSV_FILE"

echo ""
echo ""
echo "Run $RUN_NUM finished - $(date '+%H:%M:%S')"
echo " CSV: $CSV_FILE"
echo " Total: pkg=${total_pkg}J | wall=${total_wall}s"
echo ""
echo ""

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<EOS

## Run $RUN_NUM - $PROJECT_NAME

| Stage | pkg (J) | cores (J) | gpu (J) | ram (J) | wall (s) | exit |
|-------|---------|-----------|---------|---------|----------|------|
$(grep "^$RUN_NUM," "$CSV_FILE" | awk -F',' -v ex="$EXITS_FILE" 'BEGIN { while ((getline l < ex) > 0) { split(l, a, ","); e[a[2]] = a[3] } } {printf "| %s | %s | %s | %s | %s | %s | %s |\n", $2,$3,$4,$5,$6,$7,($2 in e ? e[$2] : "-")}')
EOS
fi

rm -f "$TIME_FILE"

if [ "$PIPELINE_EXIT" -ne 0 ]; then
  echo "Run $RUN_NUM: stage(s) with non-zero exit  $FAILED_STAGES"
  echo "  CSV: $CSV_FILE  exit codes: $EXITS_FILE"
  exit "$PIPELINE_EXIT"
fi
