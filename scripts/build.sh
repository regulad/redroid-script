#!/usr/bin/env bash
# Builds one image of the matrix, for one architecture, from the inputs pinned
# in matrix.json. CI runs exactly this; so can anyone with Docker and buildx.
#
#   scripts/build.sh <android> <arch> --load
#   scripts/build.sh <android> <arch> --push <repository> <metadata-file>
#   scripts/build.sh <android> <arch> --print
#
# <android> is a redroid variant from matrix.json (12.0.0, 16.0.0_64only, ...),
# <arch> amd64 or arm64. --load puts the image in the local Docker engine as
# redroid-script:<android>-<arch>; --push sends it to <repository> by digest
# only (CI tags it afterwards) and writes buildx's metadata, digest included,
# to <metadata-file>; --print shows the resolved inputs and builds nothing.
#
# The image's timestamps come from SOURCE_DATE_EPOCH, by default the time of the
# last commit that touched an input, so that rebuilding the same inputs gives
# the same layers.
set -euo pipefail

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 3 ] || usage
android=$1 arch=$2 mode=$3
shift 3

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

cell=$(jq -ce --arg android "$android" --arg arch "$arch" '
  . as $m
  | [.images[] | select(.android == $android)][0] as $image
  | ($image // error("no image \($android) in matrix.json"))
  | ($image.platforms[$arch] // error("\($android) has no \($arch) build")) as $p
  | ($m.gapps[$p.gapps] // error("unknown gapps \($p.gapps)")) as $g
  | {
      android: $android,
      arch: $arch,
      base: $image.base,
      tools: $m.tools,
      gapps: $p.gapps,
      gapps_kind: $g.kind,
      gapps_file: $g.file,
      gapps_url: $g.url,
      gapps_sha256: $g.sha256,
      litegapps_tree: ($g.tree // ""),
      native_bridge: $p.native_bridge,
      houdini: $m.houdini,
      hack: $m.houdini_hack
    }' matrix.json)

field() { jq -r ".$1" <<<"$cell"; }

native_bridge=$(field native_bridge)
case "$native_bridge" in
  none) target_bridge=none; bridge_label=none ;;
  # The base's own libndk_translation: nothing to add.
  builtin) target_bridge=none; bridge_label="libndk_translation (from the redroid base)" ;;
  houdini) target_bridge=houdini; bridge_label="libhoudini $(field houdini.version)" ;;
  *) echo "unknown native_bridge $native_bridge" >&2; exit 1 ;;
esac

if [ "$mode" = --print ]; then
  jq . <<<"$cell"
  exit 0
fi

: "${SOURCE_DATE_EPOCH:=$(git log -1 --format=%ct -- Dockerfile matrix.json native-bridge scripts/build.sh)}"
export SOURCE_DATE_EPOCH
revision=$(git rev-parse HEAD)
base=$(field base)

args=(
  --platform "linux/$arch"
  --build-arg "BASE=$base"
  --build-arg "TOOLS=$(field tools)"
  --build-arg "GAPPS_KIND=$(field gapps_kind)"
  --build-arg "GAPPS_URL=$(field gapps_url)"
  --build-arg "GAPPS_SHA256=$(field gapps_sha256)"
  --build-arg "LITEGAPPS_TREE=$(field litegapps_tree)"
  --build-arg "NATIVE_BRIDGE=$target_bridge"
  --build-arg "HOUDINI_REPO=$(field houdini.repo)"
  --build-arg "HOUDINI_COMMIT=$(field houdini.commit)"
  --build-arg "HACK_REPO=$(field hack.repo)"
  --build-arg "HACK_COMMIT=$(field hack.commit)"
  --build-arg "HACK_ANDROID=${android%%_*}"
  --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
  --label "org.opencontainers.image.title=redroid $android with Google apps"
  --label "org.opencontainers.image.description=redroid/redroid $android with $(field gapps_file); ARM translation: $bridge_label"
  --label "org.opencontainers.image.source=https://github.com/regulad/redroid-script"
  --label "org.opencontainers.image.revision=$revision"
  --label "org.opencontainers.image.base.name=${base%@*}"
  --label "org.opencontainers.image.base.digest=${base#*@}"
  --label "xyz.regulad.redroid-script.gapps=$(field gapps_file)"
  --label "xyz.regulad.redroid-script.native-bridge=$bridge_label"
)

case "$mode" in
  --load)
    args+=(--output "type=docker,name=redroid-script:$android-$arch,rewrite-timestamp=true")
    ;;
  --push)
    [ $# -ge 2 ] || usage
    repository=$1 metadata=$2
    shift 2
    args+=(
      --provenance mode=max
      --output "type=image,name=$repository,push-by-digest=true,name-canonical=true,push=true,rewrite-timestamp=true"
      --metadata-file "$metadata"
    )
    ;;
  *) usage ;;
esac

echo "building $android for $arch from $base (SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH)" >&2
exec docker buildx build "${args[@]}" "$@" .
