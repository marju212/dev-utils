#!/usr/bin/env bats

load test_helpers

setup() {
  source_release_functions
}

# ─── validate_semver ─────────────────────────────────────────────────────────────

@test "validate_semver: accepts 0.0.0" {
  run validate_semver "0.0.0"
  [ "$status" -eq 0 ]
}

@test "validate_semver: accepts 1.2.3" {
  run validate_semver "1.2.3"
  [ "$status" -eq 0 ]
}

@test "validate_semver: accepts 10.20.30" {
  run validate_semver "10.20.30"
  [ "$status" -eq 0 ]
}

@test "validate_semver: rejects v1.2.3 (prefix)" {
  run validate_semver "v1.2.3"
  [ "$status" -eq 1 ]
}

@test "validate_semver: rejects 1.2 (too few parts)" {
  run validate_semver "1.2"
  [ "$status" -eq 1 ]
}

@test "validate_semver: rejects 1.2.3.4 (too many parts)" {
  run validate_semver "1.2.3.4"
  [ "$status" -eq 1 ]
}

@test "validate_semver: rejects abc" {
  run validate_semver "abc"
  [ "$status" -eq 1 ]
}

@test "validate_semver: rejects empty string" {
  run validate_semver ""
  [ "$status" -eq 1 ]
}

@test "validate_semver: rejects 1.2.3-beta (prerelease)" {
  run validate_semver "1.2.3-beta"
  [ "$status" -eq 1 ]
}

# ─── suggest_versions ────────────────────────────────────────────────────────────

@test "suggest_versions: from 0.0.0" {
  suggest_versions "0.0.0"
  [ "$SUGGESTED_PATCH" = "0.0.1" ]
  [ "$SUGGESTED_MINOR" = "0.1.0" ]
  [ "$SUGGESTED_MAJOR" = "1.0.0" ]
}

@test "suggest_versions: from 1.2.3" {
  suggest_versions "1.2.3"
  [ "$SUGGESTED_PATCH" = "1.2.4" ]
  [ "$SUGGESTED_MINOR" = "1.3.0" ]
  [ "$SUGGESTED_MAJOR" = "2.0.0" ]
}

@test "suggest_versions: from 9.99.999" {
  suggest_versions "9.99.999"
  [ "$SUGGESTED_PATCH" = "9.99.1000" ]
  [ "$SUGGESTED_MINOR" = "9.100.0" ]
  [ "$SUGGESTED_MAJOR" = "10.0.0" ]
}

@test "suggest_versions: from 0.1.0" {
  suggest_versions "0.1.0"
  [ "$SUGGESTED_PATCH" = "0.1.1" ]
  [ "$SUGGESTED_MINOR" = "0.2.0" ]
  [ "$SUGGESTED_MAJOR" = "1.0.0" ]
}
