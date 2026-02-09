#!/usr/bin/env bash
#
# release.sh - Automate version management and release branch creation for GitLab repos.
#
# Usage: ./scripts/release.sh [OPTIONS]
#
# Options:
#   --dry-run        Run all checks without making changes
#   --no-mr          Skip merge request creation
#   --config FILE    Path to config file
#   --version X.Y.Z  Set release version non-interactively
#   --yes, -y        Auto-confirm all prompts (for CI/CD)
#   --help           Show this help message
#
set -euo pipefail

# ─── Globals ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"

DRY_RUN=false
NO_MR=false
UPDATE_DEFAULT_BRANCH=false
CONFIG_FILE=""
AUTO_YES=false
CLI_VERSION=""
CLEANUP_BRANCH=""
CLEANUP_TAG=""

# Snapshot env vars BEFORE config loading so they can override config files.
# _ENV_* vars hold the original environment values (empty string if unset).
_ENV_GITLAB_TOKEN="${GITLAB_TOKEN:-}"
_ENV_GITLAB_API_URL="${GITLAB_API_URL:-}"
_ENV_RELEASE_DEFAULT_BRANCH="${RELEASE_DEFAULT_BRANCH:-}"
_ENV_RELEASE_TAG_PREFIX="${RELEASE_TAG_PREFIX:-}"
_ENV_RELEASE_REMOTE="${RELEASE_REMOTE:-}"
_ENV_GITLAB_VERIFY_SSL="${GITLAB_VERIFY_SSL:-}"

# Defaults (overridden by config / env)
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
GITLAB_API_URL="${GITLAB_API_URL:-https://gitlab.com/api/v4}"
VERIFY_SSL="${GITLAB_VERIFY_SSL:-true}"
DEFAULT_BRANCH="${RELEASE_DEFAULT_BRANCH:-main}"
TAG_PREFIX="${RELEASE_TAG_PREFIX:-v}"
REMOTE="${RELEASE_REMOTE:-origin}"

# ─── Logging ────────────────────────────────────────────────────────────────────

_use_color=false
[[ -t 2 ]] && _use_color=true

_color() {
  if $_use_color; then printf "\e[%sm" "$1"; fi
}
_reset() {
  if $_use_color; then printf "\e[0m"; fi
}

log_info()    { echo -e "$(_color "94")ℹ $*$(_reset)" >&2; }
log_warn()    { echo -e "$(_color "33")⚠ $*$(_reset)" >&2; }
log_error()   { echo -e "$(_color "31")✖ $*$(_reset)" >&2; }
log_success() { echo -e "$(_color "32")✔ $*$(_reset)" >&2; }

# ─── Utility ────────────────────────────────────────────────────────────────────

confirm() {
  local message="${1:-Continue?}"
  if $DRY_RUN; then
    log_info "[dry-run] Would prompt: $message [y/N]"
    return 0
  fi
  if $AUTO_YES; then
    log_info "[auto-yes] $message [y/N]"
    return 0
  fi
  read -rp "$message [y/N] " answer
  case "$answer" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

validate_semver() {
  local version="$1"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "Invalid semver format: '$version' (expected X.Y.Z)"
    return 1
  fi
}

# ─── Prerequisites ──────────────────────────────────────────────────────────────

check_prerequisites() {
  local missing=()
  for cmd in git curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    log_error "Install them and try again."
    exit 1
  fi
}

# ─── Argument parsing ───────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: release.sh [OPTIONS]

Automate version management and release branch creation for GitLab repos.

Options:
  --dry-run                  Run all checks without making changes
  --no-mr                    Skip merge request creation
  --update-default-branch    Change GitLab default branch to the release branch
  --config FILE              Path to config file (default: .release.conf)
  --version X.Y.Z            Set release version non-interactively
  --yes, -y                  Auto-confirm all prompts (for CI/CD)
  --help                     Show this help message

CI/CD usage:
  ./scripts/release.sh --version 1.2.3 --yes --no-mr
  GITLAB_TOKEN=\$TOKEN ./scripts/release.sh --version 1.2.3 --yes

Environment variables:
  GITLAB_TOKEN             GitLab personal access token (required for API calls)
  GITLAB_API_URL           GitLab API base URL (default: https://gitlab.com/api/v4)
  RELEASE_DEFAULT_BRANCH   Branch to release from (default: main)
  RELEASE_TAG_PREFIX       Tag prefix (default: v)
  RELEASE_REMOTE           Git remote name (default: origin)
  GITLAB_VERIFY_SSL        Verify SSL certificates (default: true, set to false for self-signed certs)

Token resolution (first match wins):
  GITLAB_TOKEN env var     Exported shell variable (highest priority)
  .release.conf            GITLAB_TOKEN key in any config file
  ~/.gitlab_token          Plain-text file containing just the token

Config files (loaded in order, later values win):
  ~/.release.conf          User-level config
  <repo>/.release.conf     Repo-level config
  --config FILE            Explicit config file
  Environment variables    Highest priority
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --no-mr)
        NO_MR=true
        shift
        ;;
      --update-default-branch)
        UPDATE_DEFAULT_BRANCH=true
        shift
        ;;
      --config)
        if [[ -z "${2:-}" ]]; then
          log_error "--config requires a file path argument"
          exit 1
        fi
        CONFIG_FILE="$2"
        shift 2
        ;;
      --version)
        if [[ -z "${2:-}" ]]; then
          log_error "--version requires a version argument (X.Y.Z)"
          exit 1
        fi
        CLI_VERSION="$2"
        shift 2
        ;;
      --yes|-y)
        AUTO_YES=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
}

# ─── Configuration ──────────────────────────────────────────────────────────────

_load_conf_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    log_info "Loading config: $file"
    # Source in a subshell-safe way: only accept known variables
    local line key value
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
      # Skip comments and blank lines
      key="${key// /}"
      [[ -z "$key" || "$key" == \#* ]] && continue
      # Strip surrounding quotes from value
      value="${value#\"}"
      value="${value%\"}"
      value="${value#\'}"
      value="${value%\'}"
      case "$key" in
        GITLAB_TOKEN)       GITLAB_TOKEN="$value" ;;
        GITLAB_API_URL)     GITLAB_API_URL="$value" ;;
        DEFAULT_BRANCH)     DEFAULT_BRANCH="$value" ;;
        TAG_PREFIX)         TAG_PREFIX="$value" ;;
        REMOTE)             REMOTE="$value" ;;
        VERIFY_SSL)         VERIFY_SSL="$value" ;;
        NO_MR)              [[ "$value" == "true" ]] && NO_MR=true ;;
        *)                  log_warn "Unknown config key: $key" ;;
      esac
    done < "$file"
  fi
}

load_config() {
  # 0. Load token from ~/.gitlab_token file if it exists and token is not
  #    already set via environment variable
  if [[ -z "$GITLAB_TOKEN" && -f "$HOME/.gitlab_token" ]]; then
    GITLAB_TOKEN="$(<"$HOME/.gitlab_token")"
    # Strip whitespace/newlines
    GITLAB_TOKEN="${GITLAB_TOKEN%"${GITLAB_TOKEN##*[![:space:]]}"}"
    if [[ -n "$GITLAB_TOKEN" ]]; then
      log_info "Loaded token from ~/.gitlab_token"
    fi
  fi

  # 1. User-level config
  _load_conf_file "$HOME/.release.conf"

  # 2. Repo-level config
  _load_conf_file "$REPO_ROOT/.release.conf"

  # 3. Explicit --config file
  if [[ -n "$CONFIG_FILE" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
      log_error "Config file not found: $CONFIG_FILE"
      exit 1
    fi
    _load_conf_file "$CONFIG_FILE"
  fi

  # 4. Env vars override everything — re-apply from the snapshots saved at
  #    startup so that config file values don't shadow environment variables.
  if [[ -n "$_ENV_GITLAB_TOKEN" ]]; then           GITLAB_TOKEN="$_ENV_GITLAB_TOKEN"; fi
  if [[ -n "$_ENV_GITLAB_API_URL" ]]; then         GITLAB_API_URL="$_ENV_GITLAB_API_URL"; fi
  if [[ -n "$_ENV_RELEASE_DEFAULT_BRANCH" ]]; then DEFAULT_BRANCH="$_ENV_RELEASE_DEFAULT_BRANCH"; fi
  if [[ -n "$_ENV_RELEASE_TAG_PREFIX" ]]; then     TAG_PREFIX="$_ENV_RELEASE_TAG_PREFIX"; fi
  if [[ -n "$_ENV_RELEASE_REMOTE" ]]; then         REMOTE="$_ENV_RELEASE_REMOTE"; fi
  if [[ -n "$_ENV_GITLAB_VERIFY_SSL" ]]; then     VERIFY_SSL="$_ENV_GITLAB_VERIFY_SSL"; fi
}

# ─── Branch validation ──────────────────────────────────────────────────────────

check_branch() {
  log_info "Checking repository state..."

  # Must be inside a git repo
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    log_error "Not inside a git repository."
    exit 1
  fi

  # Must be on the default branch (or at its tip in detached HEAD for CI)
  local current_branch _detached_head=false
  if current_branch="$(git symbolic-ref --short HEAD 2>/dev/null)"; then
    if [[ "$current_branch" != "$DEFAULT_BRANCH" ]]; then
      log_error "Must be on '$DEFAULT_BRANCH' branch (currently on '$current_branch')."
      exit 1
    fi
  else
    _detached_head=true
    log_info "Detached HEAD detected (common in CI environments)."
  fi

  # Working tree must be clean
  if [[ -n "$(git status --porcelain)" ]]; then
    log_error "Working tree is dirty. Commit or stash changes first."
    exit 1
  fi

  # Fetch latest from remote
  log_info "Fetching from $REMOTE..."
  git fetch "$REMOTE" --tags --quiet

  # Must be in sync with remote
  local local_sha remote_sha
  local_sha="$(git rev-parse HEAD)"
  remote_sha="$(git rev-parse "$REMOTE/$DEFAULT_BRANCH" 2>/dev/null || echo "")"

  if [[ -z "$remote_sha" ]]; then
    log_warn "Remote branch '$REMOTE/$DEFAULT_BRANCH' not found. Continuing anyway."
  elif [[ "$local_sha" != "$remote_sha" ]]; then
    if $_detached_head; then
      log_error "HEAD is not at the tip of '$REMOTE/$DEFAULT_BRANCH'."
      log_error "Ensure the CI job checks out the latest '$DEFAULT_BRANCH' commit."
    else
      log_error "Local '$DEFAULT_BRANCH' is not in sync with '$REMOTE/$DEFAULT_BRANCH'."
      log_error "Pull or push changes before releasing."
    fi
    exit 1
  fi

  log_success "Repository is clean and in sync."
}

# ─── Version management ─────────────────────────────────────────────────────────

get_latest_version() {
  local version_stripped
  local all_tags
  all_tags="$(git tag --list "${TAG_PREFIX}*" --sort=-v:refname 2>/dev/null || true)"

  # Filter to only strict semver tags (X.Y.Z after stripping prefix)
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    version_stripped="${tag#"$TAG_PREFIX"}"
    if [[ "$version_stripped" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$version_stripped"
      return 0
    fi
  done <<< "$all_tags"

  echo "0.0.0"
}

suggest_versions() {
  local current="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$current"

  SUGGESTED_PATCH="$major.$minor.$((patch + 1))"
  SUGGESTED_MINOR="$major.$((minor + 1)).0"
  SUGGESTED_MAJOR="$((major + 1)).0.0"
}

prompt_version() {
  local current="$1"
  suggest_versions "$current"

  echo "" >&2
  echo "Current version: ${TAG_PREFIX}${current}" >&2
  echo "" >&2
  echo "  1) Patch  → ${TAG_PREFIX}${SUGGESTED_PATCH}" >&2
  echo "  2) Minor  → ${TAG_PREFIX}${SUGGESTED_MINOR}" >&2
  echo "  3) Major  → ${TAG_PREFIX}${SUGGESTED_MAJOR}" >&2
  echo "  4) Custom" >&2
  echo "" >&2

  local choice
  read -rp "Select version bump [1-4]: " choice

  case "$choice" in
    1) NEW_VERSION="$SUGGESTED_PATCH" ;;
    2) NEW_VERSION="$SUGGESTED_MINOR" ;;
    3) NEW_VERSION="$SUGGESTED_MAJOR" ;;
    4)
      read -rp "Enter version (X.Y.Z): " NEW_VERSION
      validate_semver "$NEW_VERSION"
      ;;
    *)
      log_error "Invalid choice: $choice"
      exit 1
      ;;
  esac

  # Check if tag already exists
  if git rev-parse "${TAG_PREFIX}${NEW_VERSION}" &>/dev/null; then
    log_error "Tag '${TAG_PREFIX}${NEW_VERSION}' already exists."
    exit 1
  fi

  # Check if release branch already exists
  local branch_name="release/${TAG_PREFIX}${NEW_VERSION}"
  if git rev-parse --verify "$branch_name" &>/dev/null || \
     git rev-parse --verify "$REMOTE/$branch_name" &>/dev/null; then
    log_error "Branch '$branch_name' already exists."
    exit 1
  fi

  log_success "Will release ${TAG_PREFIX}${NEW_VERSION}"
}

# ─── Changelog ──────────────────────────────────────────────────────────────────

generate_changelog() {
  local current_tag="${TAG_PREFIX}${1}"
  local changelog

  log_info "Generating changelog..."

  if git rev-parse "$current_tag" &>/dev/null; then
    changelog="$(git log "${current_tag}..HEAD" --pretty=format:"- %s (%h)" --no-merges)"
  else
    changelog="$(git log --pretty=format:"- %s (%h)" --no-merges)"
  fi

  if [[ -z "$changelog" ]]; then
    changelog="- No changes recorded"
  fi

  CHANGELOG="$changelog"
  echo "" >&2
  echo "── Changelog ──────────────────────────────────" >&2
  echo "$CHANGELOG" >&2
  echo "────────────────────────────────────────────────" >&2
  echo "" >&2
}

# ─── GitLab API ─────────────────────────────────────────────────────────────────

gitlab_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  if [[ -z "$GITLAB_TOKEN" ]]; then
    log_error "GITLAB_TOKEN is not set. Export it or add it to .release.conf."
    exit 1
  fi

  local url="${GITLAB_API_URL}${endpoint}"
  local response http_code

  # Write token header to a temp file to avoid exposing it in process args.
  # The file is deleted immediately after opening the file descriptor.
  local header_file
  header_file="$(mktemp)"
  printf 'PRIVATE-TOKEN: %s' "$GITLAB_TOKEN" > "$header_file"

  local curl_args=(
    --silent
    --write-out "\n%{http_code}"
    --header @"$header_file"
    --header "Content-Type: application/json"
    --request "$method"
  )

  if [[ "$VERIFY_SSL" == "false" ]]; then
    curl_args+=(--insecure)
  fi

  if [[ -n "$data" ]]; then
    curl_args+=(--data "$data")
  fi

  response="$(curl "${curl_args[@]}" "$url")"
  rm -f "$header_file"
  http_code="$(echo "$response" | tail -n1)"
  response="$(echo "$response" | sed '$d')"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    log_error "GitLab API error (HTTP $http_code): $endpoint"
    log_error "Response: $response"
    return 1
  fi

  echo "$response"
}

get_gitlab_project_id() {
  local remote_url
  remote_url="$(git remote get-url "$REMOTE" 2>/dev/null || true)"

  if [[ -z "$remote_url" ]]; then
    log_error "Cannot determine remote URL for '$REMOTE'."
    exit 1
  fi

  local project_path=""

  # SSH: git@gitlab.com:group/subgroup/project.git
  if [[ "$remote_url" =~ ^git@[^:]+:(.+)\.git$ ]]; then
    project_path="${BASH_REMATCH[1]}"
  elif [[ "$remote_url" =~ ^git@[^:]+:(.+)$ ]]; then
    project_path="${BASH_REMATCH[1]}"
  # HTTPS: https://gitlab.com/group/subgroup/project.git
  elif [[ "$remote_url" =~ ^https?://[^/]+/(.+)\.git$ ]]; then
    project_path="${BASH_REMATCH[1]}"
  elif [[ "$remote_url" =~ ^https?://[^/]+/(.+)$ ]]; then
    project_path="${BASH_REMATCH[1]}"
  fi

  if [[ -z "$project_path" ]]; then
    log_error "Cannot parse project path from remote URL: $remote_url"
    exit 1
  fi

  # URL-encode the project path (slashes -> %2F)
  local encoded_path="${project_path//\//%2F}"

  log_info "Detecting GitLab project ID for: $project_path"

  if $DRY_RUN; then
    log_info "[dry-run] Would query GitLab API for project ID"
    GITLAB_PROJECT_ID="DRY_RUN_ID"
    return 0
  fi

  local response
  response="$(gitlab_api GET "/projects/${encoded_path}")"
  GITLAB_PROJECT_ID="$(echo "$response" | jq -r '.id')"

  if [[ -z "$GITLAB_PROJECT_ID" || "$GITLAB_PROJECT_ID" == "null" ]]; then
    log_error "Could not determine GitLab project ID."
    log_error "Check that GITLAB_TOKEN has access to: $project_path"
    exit 1
  fi

  log_success "Project ID: $GITLAB_PROJECT_ID"
}

update_default_branch() {
  local branch_name="$1"

  log_info "Updating GitLab default branch to '$branch_name'..."

  if $DRY_RUN; then
    log_info "[dry-run] Would update default branch to '$branch_name'"
    return 0
  fi

  gitlab_api PUT "/projects/${GITLAB_PROJECT_ID}" \
    "{\"default_branch\": \"${branch_name}\"}" >/dev/null

  log_success "Default branch updated to '$branch_name'."
}

create_merge_request() {
  local source_branch="$1"
  local version="$2"

  if $NO_MR; then
    log_info "Skipping merge request creation (--no-mr)."
    return 0
  fi

  log_info "Creating merge request: $source_branch → $DEFAULT_BRANCH"

  if $DRY_RUN; then
    log_info "[dry-run] Would create MR: $source_branch → $DEFAULT_BRANCH"
    MR_URL="https://gitlab.com (dry-run)"
    return 0
  fi

  local body
  body=$(jq -n \
    --arg source "$source_branch" \
    --arg target "$DEFAULT_BRANCH" \
    --arg title "Release ${TAG_PREFIX}${version}" \
    --arg desc "## Release ${TAG_PREFIX}${version}\n\n${CHANGELOG}" \
    '{
      source_branch: $source,
      target_branch: $target,
      title: $title,
      description: $desc,
      remove_source_branch: false
    }')

  local response
  response="$(gitlab_api POST "/projects/${GITLAB_PROJECT_ID}/merge_requests" "$body")"
  MR_URL="$(echo "$response" | jq -r '.web_url')"

  if [[ -z "$MR_URL" || "$MR_URL" == "null" ]]; then
    log_warn "Merge request created but could not retrieve URL."
    MR_URL="(unknown)"
  else
    log_success "Merge request created: $MR_URL"
  fi
}

# ─── Git operations ─────────────────────────────────────────────────────────────

create_release_branch() {
  local branch_name="$1"

  log_info "Creating branch '$branch_name'..."

  if $DRY_RUN; then
    log_info "[dry-run] Would create and push branch '$branch_name'"
    return 0
  fi

  git checkout -b "$branch_name"
  CLEANUP_BRANCH="$branch_name"

  git push -u "$REMOTE" "$branch_name"
  log_success "Branch '$branch_name' created and pushed."
}

tag_release() {
  local tag_name="$1"
  local version="$2"

  log_info "Creating annotated tag '$tag_name'..."

  if $DRY_RUN; then
    log_info "[dry-run] Would create and push tag '$tag_name'"
    return 0
  fi

  git tag -a "$tag_name" -m "Release $version

${CHANGELOG}"
  CLEANUP_TAG="$tag_name"

  git push "$REMOTE" "$tag_name"
  log_success "Tag '$tag_name' created and pushed."
}

# ─── Cleanup ────────────────────────────────────────────────────────────────────

cleanup_on_failure() {
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    return 0
  fi

  log_warn "Release failed — cleaning up partial artifacts..."

  if [[ -n "$CLEANUP_TAG" ]]; then
    log_warn "Deleting remote tag '$CLEANUP_TAG'..."
    git push "$REMOTE" --delete "$CLEANUP_TAG" 2>/dev/null || true
    git tag -d "$CLEANUP_TAG" 2>/dev/null || true
  fi

  if [[ -n "$CLEANUP_BRANCH" ]]; then
    log_warn "Deleting remote branch '$CLEANUP_BRANCH'..."
    git push "$REMOTE" --delete "$CLEANUP_BRANCH" 2>/dev/null || true
    git checkout "$DEFAULT_BRANCH" 2>/dev/null || git checkout "$REMOTE/$DEFAULT_BRANCH" 2>/dev/null || true
    git branch -D "$CLEANUP_BRANCH" 2>/dev/null || true
  fi

  log_error "Release aborted. All partial changes have been cleaned up."
}

# ─── Summary ────────────────────────────────────────────────────────────────────

print_summary() {
  local version="$1"
  local branch="$2"
  local tag="$3"
  local mr_url="${4:-n/a}"

  echo "" >&2
  echo "╔══════════════════════════════════════════════╗" >&2
  echo "║           Release Summary                    ║" >&2
  echo "╠══════════════════════════════════════════════╣" >&2
  printf "║  %-42s  ║\n" "Version:  ${TAG_PREFIX}${version}" >&2
  printf "║  %-42s  ║\n" "Branch:   ${branch}" >&2
  printf "║  %-42s  ║\n" "Tag:      ${tag}" >&2
  printf "║  %-42s  ║\n" "MR:       ${mr_url}" >&2
  echo "╚══════════════════════════════════════════════╝" >&2
  echo "" >&2

  if $DRY_RUN; then
    log_warn "This was a dry run. No changes were made."
  fi
}

# ─── Main ───────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"
  load_config
  check_prerequisites

  if $DRY_RUN; then
    log_warn "Running in dry-run mode — no changes will be made."
    echo "" >&2
  fi

  # Set up cleanup trap
  trap cleanup_on_failure EXIT

  # Validate repo state
  check_branch

  # Version selection
  local current_version
  current_version="$(get_latest_version)"

  if [[ -n "$CLI_VERSION" ]]; then
    validate_semver "$CLI_VERSION"
    NEW_VERSION="$CLI_VERSION"
    # Check if tag already exists
    if git rev-parse "${TAG_PREFIX}${NEW_VERSION}" &>/dev/null; then
      log_error "Tag '${TAG_PREFIX}${NEW_VERSION}' already exists."
      exit 1
    fi
    # Check if release branch already exists
    local branch_name="release/${TAG_PREFIX}${NEW_VERSION}"
    if git rev-parse --verify "$branch_name" &>/dev/null || \
       git rev-parse --verify "$REMOTE/$branch_name" &>/dev/null; then
      log_error "Branch '$branch_name' already exists."
      exit 1
    fi
    log_success "Will release ${TAG_PREFIX}${NEW_VERSION}"
  else
    prompt_version "$current_version"
  fi

  local release_branch="release/${TAG_PREFIX}${NEW_VERSION}"
  local release_tag="${TAG_PREFIX}${NEW_VERSION}"

  # Generate changelog
  generate_changelog "$current_version"

  # Confirm before proceeding
  if ! confirm "Create release ${release_tag}?"; then
    log_warn "Release cancelled."
    trap - EXIT
    exit 0
  fi

  # Detect GitLab project (needed for API calls)
  get_gitlab_project_id

  # Create release branch
  create_release_branch "$release_branch"

  # Create annotated tag
  tag_release "$release_tag" "$NEW_VERSION"

  # Optionally update default branch on GitLab
  if $UPDATE_DEFAULT_BRANCH; then
    update_default_branch "$release_branch"
  fi

  # Create merge request back to main
  create_merge_request "$release_branch" "$NEW_VERSION"

  # Disable cleanup trap — we succeeded
  trap - EXIT

  # Switch back to default branch
  if ! $DRY_RUN; then
    git checkout "$DEFAULT_BRANCH" 2>/dev/null || git checkout "$REMOTE/$DEFAULT_BRANCH" 2>/dev/null || true
  fi

  # Print summary
  print_summary "$NEW_VERSION" "$release_branch" "$release_tag" "${MR_URL:-n/a}"

  log_success "Release ${release_tag} completed!"
}

main "$@"
