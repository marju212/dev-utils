# dev-utils

A collection of utility scripts for DevOps workflows.

## release.sh

Automates version management and release branch creation for GitLab repositories. The script handles the full release lifecycle: version bumping, changelog generation, release branch creation, tagging, and merge request creation.

### Prerequisites

The following tools must be installed and available on your `PATH`:

- **git**
- **curl**
- **jq**

A **GitLab personal access token** with `api` scope is required for API operations (merge request creation, project detection, default branch updates).

### Quick Start

```bash
# Dry run — validate everything without making changes
./scripts/release.sh --dry-run

# Create a release (interactive version prompt)
./scripts/release.sh

# Create a release without a merge request
./scripts/release.sh --no-mr

# Use a custom config file
./scripts/release.sh --config /path/to/my.conf

# Also update the GitLab default branch to the release branch
./scripts/release.sh --update-default-branch
```

### What It Does

When you run `release.sh`, it performs the following steps in order:

1. **Parses arguments and loads configuration** from config files and environment variables.
2. **Checks prerequisites** — ensures `git`, `curl`, and `jq` are available.
3. **Validates repository state** — confirms you are on the default branch, the working tree is clean, and the local branch is in sync with the remote.
4. **Fetches the latest tags** from the remote.
5. **Detects the current version** by finding the latest semver tag (e.g. `v1.2.3`). Pre-release and non-semver tags are filtered out. If no tags exist, defaults to `0.0.0`.
6. **Prompts for a version bump** — presents patch, minor, and major suggestions, or allows a custom version. Validates that the chosen tag and release branch don't already exist.
7. **Generates a changelog** from commit messages since the last tag, formatted as a markdown list.
8. **Asks for confirmation** before proceeding.
9. **Detects the GitLab project ID** by parsing the git remote URL (supports SSH and HTTPS, including nested groups and self-hosted instances).
10. **Creates a release branch** named `release/<tag>` (e.g. `release/v1.3.0`) and pushes it to the remote.
11. **Creates an annotated tag** with the changelog as the tag message and pushes it to the remote.
12. **Optionally updates the GitLab default branch** to the release branch (if `--update-default-branch` is passed).
13. **Creates a merge request** from the release branch back to the default branch, with the changelog in the description.
14. **Switches back** to the default branch and prints a summary.

If any step fails after branches or tags have been pushed, a **cleanup trap** automatically deletes the partial remote branch and tag, then restores you to the default branch.

### Command-Line Options

| Option | Description |
|---|---|
| `--dry-run` | Run all validation and checks without making any changes. API calls, branch creation, tagging, and MR creation are skipped. |
| `--no-mr` | Skip merge request creation. The release branch and tag are still created. |
| `--update-default-branch` | After creating the release branch, update the GitLab project's default branch to point to it. |
| `--config FILE` | Load configuration from the specified file (in addition to the default config locations). |
| `--help`, `-h` | Show the help message and exit. |

### Configuration

Settings can be provided through config files and environment variables. Multiple sources are loaded in order, with later values overriding earlier ones.

#### Config File Locations (loaded in order)

| Priority | Location | Description |
|---|---|---|
| 1 (lowest) | `~/.release.conf` | User-level defaults |
| 2 | `<repo>/.release.conf` | Repository-level overrides |
| 3 | `--config FILE` | Explicitly specified file |
| 4 (highest) | Environment variables | Always take precedence |

An example config file is provided at `scripts/.release.conf.example`.

#### Config File Format

Config files use a simple `KEY=VALUE` format. Comments (lines starting with `#`) and blank lines are ignored. Values can be optionally quoted with single or double quotes.

```bash
# GitLab API base URL (change for self-hosted instances)
GITLAB_API_URL=https://gitlab.com/api/v4

# Branch to release from
DEFAULT_BRANCH=main

# Prefix for version tags (produces tags like v1.2.3)
TAG_PREFIX=v

# Git remote name
REMOTE=origin

# Skip merge request creation (true/false)
NO_MR=false

# GitLab token (prefer env var or ~/.gitlab_token instead)
# GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx
```

#### Environment Variables

| Variable | Config Key | Default | Description |
|---|---|---|---|
| `GITLAB_TOKEN` | `GITLAB_TOKEN` | *(none)* | GitLab personal access token (required for API calls) |
| `GITLAB_API_URL` | `GITLAB_API_URL` | `https://gitlab.com/api/v4` | GitLab API base URL |
| `RELEASE_DEFAULT_BRANCH` | `DEFAULT_BRANCH` | `main` | Branch to release from |
| `RELEASE_TAG_PREFIX` | `TAG_PREFIX` | `v` | Prefix for version tags |
| `RELEASE_REMOTE` | `REMOTE` | `origin` | Git remote name |

Environment variables are snapshotted at script startup. This means that if a config file sets a value for a variable that was already set in the environment, the environment value is preserved.

#### Token Resolution

The GitLab token is resolved using the first match from this chain:

1. **`GITLAB_TOKEN` environment variable** — highest priority, recommended for CI/CD.
2. **`GITLAB_TOKEN` key in a `.release.conf` file** — loaded from any config file in the chain.
3. **`~/.gitlab_token` file** — a plain-text file containing just the token. Useful for personal machines.

```bash
# Option 1: Environment variable (recommended)
export GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx

# Option 2: Token file
echo "glpat-xxxxxxxxxxxxxxxxxxxx" > ~/.gitlab_token
chmod 600 ~/.gitlab_token
```

### Version Management

The script uses **semantic versioning** (X.Y.Z). Versions are detected from git tags matching the configured prefix (default: `v`). Only strict semver tags are considered — pre-release tags (e.g. `v1.0.0-rc1`) and non-semver tags are filtered out.

When prompted, you can select:

| Choice | Current: 1.2.3 | Result |
|---|---|---|
| **1) Patch** | 1.2.3 → 1.2.4 | Bug fixes, small changes |
| **2) Minor** | 1.2.3 → 1.3.0 | New features, backwards compatible |
| **3) Major** | 1.2.3 → 2.0.0 | Breaking changes |
| **4) Custom** | *(enter manually)* | Any valid X.Y.Z version |

The script rejects versions where the tag or release branch already exists.

### Changelog Generation

The changelog is automatically generated from git commit messages between the last tag and `HEAD`. Merge commits are excluded. The format is a markdown list:

```
- Fix login timeout issue (a1b2c3d)
- Add retry logic for API calls (e4f5g6h)
- Update dependencies (i7j8k9l)
```

If no previous tag exists, all commits are included. If there are no commits since the last tag, the changelog reads `- No changes recorded`.

The changelog is used in:
- The annotated tag message
- The merge request description

### Git Remote URL Parsing

The script automatically detects the GitLab project from the git remote URL. Both SSH and HTTPS formats are supported, with or without the `.git` suffix:

| Format | Example |
|---|---|
| SSH | `git@gitlab.com:group/project.git` |
| SSH (nested groups) | `git@gitlab.com:group/subgroup/project.git` |
| HTTPS | `https://gitlab.com/group/project.git` |
| HTTPS (nested groups) | `https://gitlab.com/group/subgroup/project.git` |
| Self-hosted SSH | `git@gitlab.example.com:team/project.git` |
| Self-hosted HTTPS | `https://gitlab.example.com/team/project.git` |

Nested group paths are URL-encoded (slashes become `%2F`) for the GitLab API.

### Security

- The GitLab token is **never passed as a command-line argument** (which would be visible in process listings). Instead, it is written to a temporary file and passed to `curl` via `--header @file`. The file is deleted immediately after the API call.
- The script uses `set -euo pipefail` for strict error handling — undefined variables and failed commands cause immediate exit.

### Error Handling and Cleanup

The script sets a `trap` on `EXIT` that runs a cleanup handler on failure. If any step fails after remote artifacts have been created:

- The remote **tag** is deleted (if it was pushed).
- The remote **release branch** is deleted (if it was pushed).
- The local checkout is switched back to the default branch.
- The local release branch is deleted.

The trap is disabled after a successful release to avoid cleaning up valid artifacts.

### CI/CD Usage

The script supports fully non-interactive execution for CI/CD pipelines via `--version` and `--yes`:

```bash
# Non-interactive release (no prompts)
./scripts/release.sh --version 1.2.3 --yes

# Combine with other flags
./scripts/release.sh --version 1.2.3 --yes --no-mr
```

| Option | Description |
|---|---|
| `--version X.Y.Z` | Set the release version directly, bypassing the interactive version prompt. |
| `--yes`, `-y` | Auto-confirm all prompts. Without this, confirmation prompts will block in CI. |

**Detached HEAD support:** GitLab CI runners typically check out a specific commit (detached HEAD) rather than a branch. The script detects this and validates that HEAD is at the tip of the remote default branch instead of requiring a named branch checkout.

A sample `.gitlab-ci.yml` job is provided at [`examples/gitlab-ci-release.yml`](examples/gitlab-ci-release.yml).

### Examples

```bash
# Standard release with all defaults
./scripts/release.sh

# Dry run to preview what would happen
./scripts/release.sh --dry-run

# Release without creating a merge request
./scripts/release.sh --no-mr

# Self-hosted GitLab instance
export GITLAB_API_URL=https://gitlab.mycompany.com/api/v4
export GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx
./scripts/release.sh

# Release from a non-main branch
export RELEASE_DEFAULT_BRANCH=develop
./scripts/release.sh

# Custom tag prefix (produces tags like release-1.0.0)
export RELEASE_TAG_PREFIX=release-
./scripts/release.sh

# Use a project-specific config file
./scripts/release.sh --config ./my-project.conf

# Full options: dry run with custom config, skip MR
./scripts/release.sh --dry-run --no-mr --config ./my-project.conf
```

### Running Tests

Tests use [BATS](https://github.com/bats-core/bats-core) (Bash Automated Testing System) and require `python3` for the mock GitLab API server.

```bash
# Run all tests
bats tests/test_*.bats

# Run a specific test suite
bats tests/test_parse_args.bats    # CLI argument parsing
bats tests/test_config.bats        # Configuration loading
bats tests/test_git_operations.bats # Git operations
bats tests/test_semver.bats        # Semantic versioning
bats tests/test_gitlab_api.bats    # GitLab API integration
bats tests/test_integration.bats   # End-to-end workflows

# Run a specific test by name
bats tests/test_semver.bats -f "validates correct semver"
```
