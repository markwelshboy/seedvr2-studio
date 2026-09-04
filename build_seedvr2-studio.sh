#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./build_seedvr2-studio.sh [options]

Options:
  --no-push              Do not push (default: push)
  --load                 Load into local docker (implies --no-push)
  --platform <plats>     Default: linux/amd64
  --no-cache             Disable build cache
  --prune                Safe-ish prune before build (keeps builder cache)
  --prune-hard           Aggressive prune before build (includes builder cache)
  --all-targets          Build final and browser targets

Tagging:
  --image <repo/name>    Default: markwelshboy/seedvr2-studio
  --tag <tag>            Default: latest

Target stage:
  --target <stage>       Build a specific Dockerfile stage (final/browser).
                         If omitted, prefers 'final'.

Metadata:
  --image-version <v>    Default: 0.1.0
  --build-date <iso>     Default: now UTC
  --vcs-ref <sha>        Default: git rev-parse --short HEAD or "unknown"

Pass-through:
  --build-arg KEY=VALUE  Repeatable
  --dockerfile <path>    Default: Dockerfile

Examples:
  ./build_seedvr2-studio.sh
  ./build_seedvr2-studio.sh --target browser
  ./build_seedvr2-studio.sh --target browser --load
  ./build_seedvr2-studio.sh --all-targets
  ./build_seedvr2-studio.sh --build-arg UPSTREAM_REF=main --target browser
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

IMAGE="markwelshboy/seedvr2-studio"
TAG="latest"
DOCKERFILE="Dockerfile"
PUSH=true
LOAD=false
PLATFORM="linux/amd64"
NO_CACHE=false
PRUNE=false
PRUNE_HARD=false
ALL_TARGETS=false
TARGET=""
IMAGE_VERSION="0.1.0"
BUILD_DATE=""
VCS_REF=""
EXTRA_BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push) PUSH=false; shift ;;
    --load) LOAD=true; PUSH=false; shift ;;
    --platform) [[ -n "${2:-}" ]] || die "--platform requires a value"; PLATFORM="$2"; shift 2 ;;
    --no-cache) NO_CACHE=true; shift ;;
    --prune) PRUNE=true; shift ;;
    --prune-hard) PRUNE_HARD=true; shift ;;
    --all-targets) ALL_TARGETS=true; shift ;;
    --image) [[ -n "${2:-}" ]] || die "--image requires a value"; IMAGE="$2"; shift 2 ;;
    --tag) [[ -n "${2:-}" ]] || die "--tag requires a value"; TAG="$2"; shift 2 ;;
    --dockerfile) [[ -n "${2:-}" ]] || die "--dockerfile requires a path"; DOCKERFILE="$2"; shift 2 ;;
    --target) [[ -n "${2:-}" ]] || die "--target requires a stage name"; TARGET="$2"; shift 2 ;;
    --image-version) [[ -n "${2:-}" ]] || die "--image-version requires a value"; IMAGE_VERSION="$2"; shift 2 ;;
    --build-date) [[ -n "${2:-}" ]] || die "--build-date requires a value"; BUILD_DATE="$2"; shift 2 ;;
    --vcs-ref) [[ -n "${2:-}" ]] || die "--vcs-ref requires a value"; VCS_REF="$2"; shift 2 ;;
    --build-arg) [[ -n "${2:-}" ]] || die "--build-arg requires KEY=VALUE"; EXTRA_BUILD_ARGS+=(--build-arg "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

have_cmd docker || die "docker not found"
sudo docker buildx version >/dev/null 2>&1 || die "docker buildx not available"
[[ -f "${DOCKERFILE}" ]] || die "Dockerfile not found: ${DOCKERFILE}"
$ALL_TARGETS && [[ -n "${TARGET}" ]] && die "--target cannot be used with --all-targets"

BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
if [[ -z "${VCS_REF}" ]]; then
  VCS_REF="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi

STAGES="$(grep -E '^[[:space:]]*FROM[[:space:]].*[[:space:]]+AS[[:space:]]+' "${DOCKERFILE}" \
  | sed -E 's/.*[[:space:]]+AS[[:space:]]+([A-Za-z0-9_.-]+).*/\1/I' \
  | tr -d ' ' || true)"
stage_exists() { echo "${STAGES}" | grep -qx "$1"; }

if [[ -z "${TARGET}" ]] && ! $ALL_TARGETS; then
  if stage_exists final; then TARGET="final"; fi
fi

case "${TARGET:-}" in
  ""|final|browser) ;;
  *) stage_exists "${TARGET}" || die "Dockerfile stage not found: ${TARGET}" ;;
esac

echo "== Build settings =="
echo "Image       : ${IMAGE}:${TAG}"
echo "Platform    : ${PLATFORM}"
echo "Push        : ${PUSH}"
echo "Load        : ${LOAD}"
echo "No-cache    : ${NO_CACHE}"
echo "Prune       : ${PRUNE}"
echo "Prune-hard  : ${PRUNE_HARD}"
echo "All-targets : ${ALL_TARGETS}"
echo "Dockerfile  : ${DOCKERFILE}"
echo "Target      : ${TARGET:-<default last stage>}"
echo "Build date  : ${BUILD_DATE}"
echo "VCS ref     : ${VCS_REF}"
echo "Version     : ${IMAGE_VERSION}"
echo ""

if $PRUNE_HARD; then
  sudo docker system prune -af || true
  sudo docker builder prune -af || true
elif $PRUNE; then
  sudo docker container prune -f || true
  sudo docker image prune -f || true
fi

if ! sudo docker buildx inspect >/dev/null 2>&1; then
  sudo docker buildx create --use --name default >/dev/null
fi

COMMON=(
  -f "${DOCKERFILE}"
  --platform "${PLATFORM}"
  --build-arg "BUILD_DATE=${BUILD_DATE}"
  --build-arg "VCS_REF=${VCS_REF}"
  --build-arg "IMAGE_VERSION=${IMAGE_VERSION}"
)
$NO_CACHE && COMMON+=(--no-cache)
if $PUSH; then COMMON+=(--push); else COMMON+=(--load); fi

build_one() {
  local image_ref="$1"
  local target_stage="$2"
  local args=("${COMMON[@]}")
  [[ -n "${target_stage}" ]] && args+=(--target "${target_stage}")
  echo "== Building ${image_ref}:${TAG} (target: ${target_stage:-default}) =="
  sudo docker buildx build \
    -t "${image_ref}:${TAG}" \
    "${args[@]}" \
    "${EXTRA_BUILD_ARGS[@]}" \
    .
}

if $ALL_TARGETS; then
  stage_exists final || die "Stage final not found"
  stage_exists browser || die "Stage browser not found"
  build_one "${IMAGE}" final
  build_one "${IMAGE}-browser" browser
else
  build_one "${IMAGE}" "${TARGET}"
fi

echo "== Done =="
if $ALL_TARGETS; then
  echo "  ${IMAGE}:${TAG}"
  echo "  ${IMAGE}-browser:${TAG}"
else
  echo "  ${IMAGE}:${TAG}"
fi
