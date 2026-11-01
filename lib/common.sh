#!/usr/bin/env bash
# Common helper functions for buildpack

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

APT_EOL_FIX=". /etc/os-release 2>/dev/null; case \"\${VERSION_CODENAME:-}\" in bullseye) sed -i '/bullseye-security/d' /etc/apt/sources.list ;; buster|stretch) sed -i -e '/^deb /s|http://[a-z.]*debian.org|http://archive.debian.org|' -e '/-updates/d' /etc/apt/sources.list; echo 'Acquire::Check-Valid-Until \"false\";' > /etc/apt/apt.conf.d/99archive ;; esac"

# Output functions
header() {
  echo ""
  echo -e "${BLUE}-----> $1${NC}"
}

info() {
  echo "       $1"
}

success() {
  echo -e "${GREEN}-----> $1${NC}"
}

warning() {
  echo -e "${YELLOW}-----> $1${NC}"
}

error() {
  echo -e "${RED}-----> ERROR: $1${NC}" >&2
}

registry_host() {
  case "$1" in
    */*) ;;
    *) return 0 ;;
  esac
  local ref="${1#*://}"
  ref="${ref%%/*}"
  case "$ref" in
    *.*|*:*|localhost) echo "$ref" ;;
  esac
}

is_transient_registry_error() {
  local log="$1" host
  [ -f "$log" ] || return 1
  if grep -qE 'database system is shutting down|unexpected status from [A-Z]+ request to [^ ]+: (429|50[0-4])( |$)|failed to do request: .*(i/o timeout|connection refused|connection reset by peer|TLS handshake timeout|EOF)' "$log"; then
    return 0
  fi
  for host in $(registry_host "$REGISTRY_MIRROR") $(registry_host "$OUTPUT_IMAGE") $(registry_host "$CACHE_IMAGE"); do
    if grep -qE "unexpected status from [A-Z]+ request to https?://${host//./\\.}[/:][^ ]*: 401" "$log"; then
      return 0
    fi
  done
  return 1
}

buildx_with_retry() {
  local log="$1"
  shift
  local attempt=1 max="${BUILD_RETRY_ATTEMPTS:-3}" delay="${BUILD_RETRY_DELAY:-15}" status
  while :; do
    docker buildx build "$@" 2>&1 | tee "$log" | filter_buildx_output
    status=${PIPESTATUS[0]}
    [ "$status" -eq 0 ] && return 0
    if [ "$attempt" -ge "$max" ] || ! is_transient_registry_error "$log"; then
      return "$status"
    fi
    attempt=$((attempt + 1))
    warning "Registry temporarily unavailable, retrying build in ${delay}s (attempt ${attempt}/${max})"
    sleep "$delay"
    delay=$((delay * 2))
  done
}

# Validate a name against the POSIX environment-variable identifier rule
# (IEEE Std 1003.1 sec. 8.1): a letter or underscore followed by letters,
# digits, or underscores. This is the same constraint Docker enforces on
# `ARG`/`ENV` keys and shells enforce on `$VAR` expansion.
#
# Build args MUST satisfy it; runtime-only settings with other names (e.g. the
# dotted `discovery.seed_hosts` style used by Elasticsearch/Java) are valid
# container env vars but cannot be Docker build args, so the build-arg
# projection skips them. See docs/configuration/environment-variables.mdx.
is_valid_build_arg_name() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# Normalize a git repository reference to a canonical https URL:
#   - convert scp-style git@host:org/repo to https://host/org/repo
#   - strip a leading ssh:// or git@
#   - strip embedded credentials (https://user:pass@host/... -> https://host/...)
#   - ensure an https scheme
#   - strip a trailing ".git"
# Empty input yields empty output.
normalize_git_repository() {
  local url="$1"
  [ -z "$url" ] && return 0
  if [[ "$url" =~ ^[A-Za-z0-9._-]+@([A-Za-z0-9._-]+):(.+)$ ]]; then
    url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  url="${url#ssh://}"
  url="${url#git@}"
  url="$(printf '%s' "$url" | sed -E 's#^(https?://)[^@/]+@#\1#')"
  [[ "$url" =~ ^https?:// ]] || url="https://$url"
  url="${url%.git}"
  printf '%s' "$url"
}

# Detect language
detect_language() {
  local build_dir=$1
  "$BUILDPACK_DIR/bin/detect" "$build_dir" 2>/dev/null || echo ""
}

# Resolve one build-meta field by precedence:
#   1. the BUILD_META JSON envelope ($2), keyed by $1
#   2. a direct environment variable named $3
#   3. a git fallback value ($4)
# Echoes the first non-empty source (or empty).
resolve_meta_field() {
  local key="$1" envelope="$2" env_name="$3" git_value="$4" v=""
  if [ -n "$envelope" ] && [ "$envelope" != "{}" ]; then
    v=$(printf '%s' "$envelope" | jq -r --arg k "$key" '.[$k] // empty')
  fi
  if [ -z "$v" ] && [ -n "$env_name" ]; then
    v="${!env_name}"
  fi
  [ -z "$v" ] && v="$git_value"
  printf '%s' "$v"
}

# Gather build metadata into a compact JSON object on stdout. Precedence per
# field: $BUILD_META envelope, then MIGET_GIT_*/SOURCE_VERSION env, then git in
# $1. Builder-known fields are passed in ($2 built_at, $3 builder_version,
# $4 language). Empty fields are omitted. All git calls are guarded.
gather_build_meta() {
  local src_dir="$1" built_at="$2" builder_version="$3" language="$4"
  local envelope="${BUILD_META:-}"
  local g_commit="" g_branch="" g_desc="" g_committed="" g_repo=""

  if [ -d "$src_dir/.git" ] && command -v git >/dev/null 2>&1; then
    g_commit=$(git -C "$src_dir" rev-parse HEAD 2>/dev/null || true)
    g_branch=$(git -C "$src_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [ "$g_branch" = "HEAD" ] && g_branch=""
    g_desc=$(git -C "$src_dir" log -1 --pretty=%s 2>/dev/null || true)
    g_committed=$(git -C "$src_dir" log -1 --date=format:'%Y-%m-%dT%H:%M:%SZ' --pretty=%cd 2>/dev/null || true)
    g_repo=$(normalize_git_repository "$(git -C "$src_dir" remote get-url origin 2>/dev/null || true)")
  fi

  local commit branch desc committed repo
  # commit precedence: envelope -> MIGET_GIT_COMMIT or SOURCE_VERSION (env tier) -> .git
  commit=$(printf '%s' "$envelope" | jq -r 'if type=="object" then (.commit // empty) else empty end' 2>/dev/null)
  [ -z "$commit" ] && commit="${MIGET_GIT_COMMIT:-${SOURCE_VERSION:-}}"
  [ -z "$commit" ] && commit="$g_commit"
  branch=$(resolve_meta_field branch "$envelope" MIGET_GIT_BRANCH "$g_branch")
  desc=$(resolve_meta_field description "$envelope" MIGET_GIT_DESCRIPTION "$g_desc")
  committed=$(resolve_meta_field committed_at "$envelope" MIGET_GIT_COMMITTED_AT "$g_committed")
  repo=$(resolve_meta_field repository "$envelope" MIGET_GIT_REPOSITORY "$g_repo")

  local commit_short=""
  [ -n "$commit" ] && commit_short="${commit:0:7}"

  jq -nc \
    --arg commit "$commit" \
    --arg commit_short "$commit_short" \
    --arg branch "$branch" \
    --arg description "$desc" \
    --arg committed_at "$committed" \
    --arg built_at "$built_at" \
    --arg builder_version "$builder_version" \
    --arg language "$language" \
    --arg repo "$repo" \
    '{commit:$commit, commit_short:$commit_short, branch:$branch,
      description:$description, committed_at:$committed_at, built_at:$built_at,
      builder_version:$builder_version, language:$language, repository:$repo}
     | with_entries(select(.value != ""))'
}

# Fill the BUILD_LABEL_FLAGS array with OCI + miget --label pairs from a
# build-meta JSON object ($1). Labels with empty values are skipped.
build_meta_label_flags() {
  local meta="$1"
  BUILD_LABEL_FLAGS=()
  [ -z "$meta" ] && return 0
  local commit branch desc repo built builder
  commit=$(printf '%s' "$meta" | jq -r '.commit // empty')
  branch=$(printf '%s' "$meta" | jq -r '.branch // empty')
  desc=$(printf '%s' "$meta" | jq -r '.description // empty')
  repo=$(printf '%s' "$meta" | jq -r '.repository // empty')
  built=$(printf '%s' "$meta" | jq -r '.built_at // empty')
  builder=$(printf '%s' "$meta" | jq -r '.builder_version // empty')
  [ -n "$commit" ]  && BUILD_LABEL_FLAGS+=(--label "org.opencontainers.image.revision=$commit")
  [ -n "$repo" ]    && BUILD_LABEL_FLAGS+=(--label "org.opencontainers.image.source=$repo")
  [ -n "$built" ]   && BUILD_LABEL_FLAGS+=(--label "org.opencontainers.image.created=$built")
  [ -n "$branch" ]  && BUILD_LABEL_FLAGS+=(--label "com.miget.git.branch=$branch")
  [ -n "$desc" ]    && BUILD_LABEL_FLAGS+=(--label "com.miget.git.description=$desc")
  [ -n "$builder" ] && BUILD_LABEL_FLAGS+=(--label "com.miget.builder.version=$builder")
  return 0
}

# Fill BUILD_META_ARG_FLAGS with MIGET_* --build-arg pairs from a build-meta
# JSON object ($1), for Dockerfile/Compose opt-in. Empty values are skipped.
build_meta_arg_flags() {
  local meta="$1"
  BUILD_META_ARG_FLAGS=()
  [ -z "$meta" ] && return 0
  local pairs=(
    "commit:MIGET_GIT_COMMIT" "commit_short:MIGET_GIT_COMMIT_SHORT"
    "branch:MIGET_GIT_BRANCH" "description:MIGET_GIT_DESCRIPTION"
    "committed_at:MIGET_GIT_COMMITTED_AT" "repository:MIGET_GIT_REPOSITORY"
    "built_at:MIGET_BUILD_AT" "builder_version:MIGET_BUILDER_VERSION"
    "language:MIGET_LANGUAGE"
  )
  local pair key argname val
  for pair in "${pairs[@]}"; do
    key="${pair%%:*}"; argname="${pair#*:}"
    val=$(printf '%s' "$meta" | jq -r --arg k "$key" '.[$k] // empty')
    [ -n "$val" ] && BUILD_META_ARG_FLAGS+=(--build-arg "$argname=$val")
  done
  return 0
}

# Stage /.miget/build.json into the image via the build context. COPY works on
# distroless (DHI) too, unlike RUN. No-op when meta is empty or the context is
# read-only (a `-v src:ro` mount); labels + result.json still carry the data.
stage_build_json() {
  local dockerfile="$1" ctx="$2" meta="$3"
  { [ -z "$meta" ] || [ "$meta" = "{}" ]; } && return 0
  if ! ( : > "$ctx/.miget-build.json" ) 2>/dev/null; then
    warning "Build context read-only; skipping /.miget/build.json (labels + result.json still set)"
    return 0
  fi
  printf '%s' "$meta" > "$ctx/.miget-build.json"
  # A user or generated .dockerignore could exclude the staged file and make the
  # COPY below fail; a trailing negation re-includes it (last match wins).
  if [ -f "$ctx/.dockerignore" ]; then
    grep -qxF '!.miget-build.json' "$ctx/.dockerignore" 2>/dev/null || \
      echo '!.miget-build.json' >> "$ctx/.dockerignore"
  fi
  {
    echo ""
    echo "# Build metadata (miget)"
    echo "COPY --chmod=0644 .miget-build.json /.miget/build.json"
  } >> "$dockerfile"
  return 0
}
