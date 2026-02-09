#!/usr/bin/env bats

load test_helpers

setup() {
  source_release_functions
}

# ─── --help ──────────────────────────────────────────────────────────────────────

@test "parse_args: --help exits 0 and prints usage" {
  run bash -c 'source '"$RELEASE_SCRIPT"' --help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: release.sh"* ]]
}

@test "parse_args: -h exits 0 and prints usage" {
  run bash -c 'source '"$RELEASE_SCRIPT"' -h'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: release.sh"* ]]
}

# ─── --dry-run ───────────────────────────────────────────────────────────────────

@test "parse_args: --dry-run sets DRY_RUN=true" {
  DRY_RUN=false
  parse_args --dry-run
  [ "$DRY_RUN" = "true" ]
}

# ─── --no-mr ─────────────────────────────────────────────────────────────────────

@test "parse_args: --no-mr sets NO_MR=true" {
  NO_MR=false
  parse_args --no-mr
  [ "$NO_MR" = "true" ]
}

# ─── --config ────────────────────────────────────────────────────────────────────

@test "parse_args: --config sets CONFIG_FILE" {
  CONFIG_FILE=""
  parse_args --config /tmp/my.conf
  [ "$CONFIG_FILE" = "/tmp/my.conf" ]
}

@test "parse_args: --config without value exits with error" {
  run bash -c '
    source "'"$RELEASE_SCRIPT"'" --config 2>&1
  '
  [ "$status" -ne 0 ]
}

# ─── combined flags ──────────────────────────────────────────────────────────────

@test "parse_args: multiple flags combined" {
  DRY_RUN=false
  NO_MR=false
  CONFIG_FILE=""
  parse_args --dry-run --no-mr --config /tmp/x.conf
  [ "$DRY_RUN" = "true" ]
  [ "$NO_MR" = "true" ]
  [ "$CONFIG_FILE" = "/tmp/x.conf" ]
}

# ─── --update-default-branch ─────────────────────────────────────────────────────

@test "parse_args: --update-default-branch sets UPDATE_DEFAULT_BRANCH=true" {
  UPDATE_DEFAULT_BRANCH=false
  parse_args --update-default-branch
  [ "$UPDATE_DEFAULT_BRANCH" = "true" ]
}

@test "parse_args: UPDATE_DEFAULT_BRANCH defaults to true" {
  [ "$UPDATE_DEFAULT_BRANCH" = "true" ]
}

# ─── unknown option ──────────────────────────────────────────────────────────────

@test "parse_args: unknown option exits with error" {
  run bash -c '
    source "'"$RELEASE_SCRIPT"'" --bogus 2>&1
  '
  [ "$status" -ne 0 ]
}

# ─── --version ──────────────────────────────────────────────────────────────────

@test "parse_args: --version sets CLI_VERSION" {
  CLI_VERSION=""
  parse_args --version 2.0.0
  [ "$CLI_VERSION" = "2.0.0" ]
}

@test "parse_args: --version without value exits with error" {
  run bash -c '
    source "'"$RELEASE_SCRIPT"'" --version 2>&1
  '
  [ "$status" -ne 0 ]
}

# ─── --yes / -y ─────────────────────────────────────────────────────────────────

@test "parse_args: --yes sets AUTO_YES=true" {
  AUTO_YES=false
  parse_args --yes
  [ "$AUTO_YES" = "true" ]
}

@test "parse_args: -y sets AUTO_YES=true" {
  AUTO_YES=false
  parse_args -y
  [ "$AUTO_YES" = "true" ]
}

# ─── combined flags with --version and --yes ─────────────────────────────────────

@test "parse_args: --version --yes --no-mr --dry-run combined" {
  DRY_RUN=false
  NO_MR=false
  AUTO_YES=false
  CLI_VERSION=""
  parse_args --version 2.0.0 --yes --no-mr --dry-run
  [ "$CLI_VERSION" = "2.0.0" ]
  [ "$AUTO_YES" = "true" ]
  [ "$NO_MR" = "true" ]
  [ "$DRY_RUN" = "true" ]
}
