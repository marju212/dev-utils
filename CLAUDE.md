# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

dev-utils is a collection of Bash utility scripts for DevOps workflows. The primary component is `scripts/release.sh`, a GitLab release automation tool that handles semantic versioning, release branch creation, tagging, changelog generation, and merge request management.

## Commands

### Running Tests

```bash
# Run all tests
bats tests/test_*.bats

# Run a single test file
bats tests/test_semver.bats

# Run a specific test by name
bats tests/test_semver.bats -f "validates correct semver"
```

Test suites: `test_parse_args`, `test_config`, `test_git_operations`, `test_semver`, `test_gitlab_api`, `test_integration`.

### Running the Script

```bash
./scripts/release.sh --dry-run       # validate without side effects
./scripts/release.sh --config FILE   # use custom config file
./scripts/release.sh --hotfix-mr release/v1.2.3  # create MR from release branch
```

## Architecture

### release.sh Structure

The script (~750 lines) is organized into sequential modules, each responsible for one phase of the release workflow:

1. **Logging & utilities** — color-coded output (`log_info`, `log_warn`, `log_error`, `log_success`), `confirm()` prompt, `validate_semver()`
2. **Argument parsing** — `parse_args()` handles CLI flags (`--dry-run`, `--hotfix-mr`, `--update-default-branch`, `--config`, `--help`)
3. **Configuration loading** — multi-level config resolution with strict priority: env vars (snapshotted at startup) > `--config` file > repo `.release.conf` > user `~/.release.conf` > `~/.gitlab_token`
4. **Repository validation** — `check_branch()` verifies git state (correct branch, clean tree, synced with remote)
5. **Version management** — `get_latest_version()`, `suggest_versions()`, `prompt_version()` with duplicate tag/branch detection
6. **Changelog generation** — markdown-formatted commit list since last tag
7. **GitLab API module** — `gitlab_api()` passes tokens via temp file headers (never CLI args); `get_gitlab_project_id()` parses SSH/HTTPS remotes including nested groups; `create_merge_request()` and `update_default_branch()`
8. **Hotfix MR flow** — `hotfix_mr_flow()` validates a release branch, generates a changelog from commits ahead of the default branch, and creates a merge request back to the default branch
9. **Git operations** — branch/tag creation with push
10. **Error recovery** — `cleanup_on_failure()` trap handler removes partial remote branches/tags on failure
11. **Main flow** — `main()` orchestrates the full workflow; dispatches to `hotfix_mr_flow()` when `--hotfix-mr` is used

Key design patterns:
- Every write operation respects `$DRY_RUN` — full validation runs without side effects
- Environment variables are snapshotted into `_ENV_*` vars at startup so config files cannot override them
- The `cleanup_on_failure` trap ensures partial releases are rolled back
- Release flow creates branch + tag only (no MR); MR creation is a separate step via `--hotfix-mr`

### Test Infrastructure

Tests use **BATS** (Bash Automated Testing System). Shared helpers in `tests/test_helpers.bash` provide:
- `setup_test_repo()` — creates a bare remote + working clone per test
- `source_release_functions()` — sources the script without executing `main()`
- `start_mock_gitlab()` / `stop_mock_gitlab()` — manages `tests/mock_gitlab.py`, a Python HTTP server simulating GitLab API endpoints with scenario-based failure injection

The mock server supports request recording for assertions and dynamic port assignment via a state file.
