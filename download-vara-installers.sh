#!/usr/bin/env bash
# Download the latest VARA FM and VARA HF installers from Winlink (by vX.Y.Z in the
# filename), unzip into /opt/vara/installers.

set -euo pipefail

readonly VARA_ROOT="${VARA_ROOT:-/opt/vara}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: download-vara-installers.sh

  Fetches latest VARA FM and VARA HF setup zips from Winlink and extracts to /opt/vara/installers.
  Requires: curl, grep, sort, unzip. Directory must be writable (run setup-headless-prereqs.sh first).
USAGE
  exit 0
fi

readonly INDEX_URL="https://downloads.winlink.org/VARA%20Products/"
readonly SITE_ROOT="https://downloads.winlink.org"
readonly INSTALL_DIR="${VARA_INSTALLERS_DIR:-$VARA_ROOT/installers}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

require_cmd curl
require_cmd grep
require_cmd sort
require_cmd unzip

# Decode path segment for Winlink URLs (spaces as %20, optional +). POSIX sed — no bash ${var//}.
uri_decode() {
  printf '%s' "$1" | sed -e 's/+/ /g' -e 's/%20/ /g'
}

# Read relative paths /VARA%20Products/....zip from stdin; print one line url<TAB>decoded_basename.
pick_latest_zip() {
  local prefix=$1
  local relpath enc_fname fname f_lower p_lower ver fullurl cand out
  p_lower=$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')
  cand=$(mktemp)

  while read -r relpath; do
    [ -n "$relpath" ] || continue
    enc_fname="${relpath##*/}"
    fname=$(uri_decode "$enc_fname")
    f_lower=$(printf '%s' "$fname" | tr '[:upper:]' '[:lower:]')
    case "$f_lower" in
      "$p_lower "*setup.zip) ;;
      *) continue ;;
    esac
    ver=$(printf '%s' "$fname" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    [ -n "$ver" ] || continue
    fullurl="${SITE_ROOT}${relpath}"
    printf '%s\t%s\t%s\n' "$ver" "$fullurl" "$fname"
  done >"$cand"

  if [ ! -s "$cand" ]; then
    rm -f "$cand"
    echo "error: no ${prefix} setup.zip found in index" >&2
    return 1
  fi

  out=$(sort -t "$(printf '\t')" -k1,1V "$cand" | tail -n1 | cut -f2,3)
  rm -f "$cand"
  if [ -z "$out" ]; then
    echo "error: could not resolve ${prefix} download URL" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

mkdir -p "$INSTALL_DIR"

tmpdir=$(mktemp -d)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

index_html="${tmpdir}/index.html"
curl -fsSL "$INDEX_URL" -o "$index_html"

paths_txt="${tmpdir}/paths.txt"
grep -oE '/VARA%20Products/[^"&[:space:]]+\.zip' "$index_html" | sort -u >"$paths_txt"

urls_tsv="${tmpdir}/urls.tsv"
: >"$urls_tsv"
for prefix in "VARA FM" "VARA HF"; do
  pick_latest_zip "$prefix" <"$paths_txt" >>"$urls_tsv"
done

while IFS="$(printf '\t')" read -r url zipname; do
  [ -n "$url" ] || continue
  dest_zip="${tmpdir}/${zipname}"
  echo "Downloading: $zipname"
  echo "  URL: $url"
  curl -fsSL "$url" -o "$dest_zip"
  echo "Extracting into: $INSTALL_DIR"
  unzip -o "$dest_zip" -d "$INSTALL_DIR"
done <"$urls_tsv"

echo "Done. Contents of $INSTALL_DIR:"
ls -la "$INSTALL_DIR"
