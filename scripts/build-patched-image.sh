#!/usr/bin/env bash
# Build a Nomad image from a source checkout, to run the reproduction against a
# patched build.
#
#   scripts/build-patched-image.sh <path-to-nomad-source> [base-version] [tag]
#
#   base-version  tag of the upstream image to start from (default 2.1.1)
#   tag           name of the image to build (default nomad-patched:local)
#
# It cross-compiles the nomad binary for the Docker server's architecture (needs Go
# and no cgo), then builds `FROM hashicorp/nomad:<base-version>` with /bin/nomad
# replaced. Then run the reproduction with:
#
#   CDPP_NOMAD_IMAGE=nomad-patched:local scripts/canary-drain-partial-plan.sh all
set -euo pipefail

src=${1:?usage: $0 <path-to-nomad-source> [base-version] [tag]}
version=${2:-2.1.1}
tag=${3:-nomad-patched:local}

cd "$(dirname "$0")/.."
repo=$PWD
src=$(cd "$src" && pwd)
[ -f "$src/main.go" ] && [ -f "$src/go.mod" ] || { echo "!! $src does not look like a nomad source checkout" >&2; exit 1; }

arch=$(docker version --format '{{.Server.Arch}}')
case "$arch" in
  arm64 | amd64) ;;
  *) echo "!! unsupported Docker server architecture: $arch" >&2; exit 1 ;;
esac

dir=$repo/${CDPP_OUT:-out}/patched-image
mkdir -p "$dir"

echo "==> compiling nomad from $src for linux/$arch"
(cd "$src" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath -tags codegen_generated -o "$dir/nomad" .)

printf 'FROM hashicorp/nomad:%s\nCOPY nomad /bin/nomad\n' "$version" > "$dir/Dockerfile"

echo "==> building $tag (FROM hashicorp/nomad:$version)"
docker build -q -t "$tag" "$dir" >/dev/null

echo "==> built $tag. Run the reproduction against it with:"
echo "    CDPP_NOMAD_IMAGE=$tag scripts/canary-drain-partial-plan.sh all"
