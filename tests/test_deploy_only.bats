#!/usr/bin/env bats

load test_helpers

setup() {
  source_release_functions
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  if [[ -n "${ORIGINAL_DIR:-}" ]]; then
    cd "$ORIGINAL_DIR"
  fi
  if [[ -n "${_ORIGINAL_PATH:-}" ]]; then
    export PATH="$_ORIGINAL_PATH"
    _ORIGINAL_PATH=""
  fi
  rm -rf "$TEST_TMPDIR"
}

# ─── parse_args: --deploy-only ──────────────────────────────────────────────

@test "parse_args: --deploy-only sets DEPLOY_ONLY=true" {
  DEPLOY_ONLY=false
  parse_args --deploy-only
  [ "$DEPLOY_ONLY" = "true" ]
}

@test "parse_args: --deploy-only combined with --version and --non-interactive" {
  DEPLOY_ONLY=false
  CLI_VERSION=""
  NON_INTERACTIVE=false
  parse_args --deploy-only --version 1.2.3 --non-interactive
  [ "$DEPLOY_ONLY" = "true" ]
  [ "$CLI_VERSION" = "1.2.3" ]
  [ "$NON_INTERACTIVE" = "true" ]
}

@test "parse_args: --deploy-only combined with --dry-run" {
  DEPLOY_ONLY=false
  DRY_RUN=false
  parse_args --deploy-only --dry-run
  [ "$DEPLOY_ONLY" = "true" ]
  [ "$DRY_RUN" = "true" ]
}

@test "parse_args: --deploy-only + --hotfix-mr is mutually exclusive" {
  DEPLOY_ONLY=false
  HOTFIX_MR_BRANCH=""
  run parse_args --deploy-only --hotfix-mr release/v1.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be combined"* ]]
}

@test "parse_args: --hotfix-mr + --deploy-only is mutually exclusive" {
  DEPLOY_ONLY=false
  HOTFIX_MR_BRANCH=""
  run parse_args --hotfix-mr release/v1.0.0 --deploy-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be combined"* ]]
}

# ─── deploy_only_flow ──────────────────────────────────────────────────────

@test "deploy_only_flow: fails when DEPLOY_BASE_PATH is empty" {
  DEPLOY_BASE_PATH=""
  run deploy_only_flow
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEPLOY_BASE_PATH is not configured"* ]]
}

@test "deploy_only_flow: fails when tag does not exist" {
  setup_test_repo
  CLI_VERSION="9.9.9"
  TAG_PREFIX="v"
  DEPLOY_BASE_PATH="$TEST_TMPDIR/deploy"
  DRY_RUN=false
  NON_INTERACTIVE=true

  add_test_commit "feature"
  push_test_commits

  run deploy_only_flow
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "deploy_only_flow: dry-run succeeds with a valid tag" {
  setup_test_repo
  CLI_VERSION="1.0.0"
  TAG_PREFIX="v"
  DEPLOY_BASE_PATH="$TEST_TMPDIR/deploy"
  DRY_RUN=true
  NON_INTERACTIVE=false

  add_test_commit "feature"
  push_test_commits
  create_test_tag "v1.0.0"

  run deploy_only_flow
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"Deploy of v1.0.0 completed"* ]]
}

@test "deploy_only_flow: succeeds with --non-interactive and valid tag" {
  setup_test_repo
  CLI_VERSION="1.0.0"
  TAG_PREFIX="v"
  DEPLOY_BASE_PATH="$TEST_TMPDIR/deploy"
  DRY_RUN=true
  NON_INTERACTIVE=true

  add_test_commit "feature"
  push_test_commits
  create_test_tag "v1.0.0"

  run deploy_only_flow
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deploy of v1.0.0 completed"* ]]
}

# ─── show_main_menu ──────────────────────────────────────────────────────────

@test "show_main_menu: choice 1 falls through (release)" {
  DEPLOY_ONLY=false
  HOTFIX_MR_BRANCH=""
  DEFAULT_BRANCH="main"

  show_main_menu <<< "1"
  [ "$DEPLOY_ONLY" = "false" ]
  [ -z "$HOTFIX_MR_BRANCH" ]
}

@test "show_main_menu: choice 2 sets DEPLOY_ONLY=true" {
  DEPLOY_ONLY=false
  HOTFIX_MR_BRANCH=""
  DEFAULT_BRANCH="main"

  show_main_menu <<< "2"
  [ "$DEPLOY_ONLY" = "true" ]
}

@test "show_main_menu: choice 3 sets HOTFIX_MR_BRANCH" {
  DEPLOY_ONLY=false
  HOTFIX_MR_BRANCH=""
  DEFAULT_BRANCH="main"

  show_main_menu < <(printf "3\nrelease/v1.2.3\n")
  [ "$HOTFIX_MR_BRANCH" = "release/v1.2.3" ]
}

@test "show_main_menu: invalid choice re-prompts then accepts valid choice" {
  DEPLOY_ONLY=false
  HOTFIX_MR_BRANCH=""
  DEFAULT_BRANCH="main"

  show_main_menu < <(printf "x\n2\n")
  [ "$DEPLOY_ONLY" = "true" ]
}
