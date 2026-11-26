#!/bin/sh
# Decides whether tonight's nightly build is worth making: yes when `main` has moved since the last
# nightly or release, no when there is nothing new. Pure git; run it in a checkout with the tags.
#
# Usage:
#   [FORCE=true] scripts/ci/should-build-nightly.sh [--github-output]
#
# Output, one key=value per line (and appended to $GITHUB_OUTPUT with --github-output):
#   build=true|false
#   reason=<why, in words>
#
# Rules:
#   * FORCE=true always builds.
#   * Skip when HEAD is the commit of the newest `nightly-*` tag (an identical nightly) or of the
#     newest `vX.Y.Z` / `X.Y.Z` release tag (a release already covers this code).
#   * With no earlier nightly or release at all, build.
#   * A shallow clone without tags fails loudly: it can't tell, and "build" or "skip" would both be
#     guesses. Fetch tags (`fetch-depth: 0`).
set -eu

die() { echo "error: $*" >&2; exit 1; }

GITHUB_OUTPUT_FLAG=NO
while [ $# -gt 0 ]; do
    case "$1" in
        --github-output) GITHUB_OUTPUT_FLAG=YES; shift ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
HEAD_SHA="$(git rev-parse HEAD)"

emit() {
    echo "$1=$2"
    if [ "${GITHUB_OUTPUT_FLAG}" = "YES" ]; then
        [ -n "${GITHUB_OUTPUT:-}" ] || die "--github-output needs the GITHUB_OUTPUT environment variable"
        echo "$1=$2" >> "${GITHUB_OUTPUT}"
    fi
}

if [ "${FORCE:-false}" = "true" ]; then
    emit build true
    emit reason "forced"
    exit 0
fi

# Newest nightly tag by the 14-digit stamp inside its name (nightly-X.Y.Z-<stamp>.<hash>).
NIGHTLY_TAG="$(git tag --list 'nightly-*' \
    | sed -nE 's/^(nightly-.*-([0-9]{14})\.[0-9a-f]+)$/\2 \1/p' \
    | sort -nr | head -n 1 | cut -d' ' -f2)"

# Newest release tag by number, v-prefixed or bare.
RELEASE_VERSION="$(git tag --list | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' \
    | sort -t. -k1,1nr -k2,2nr -k3,3nr | head -n 1)"
RELEASE_TAG=""
if [ -n "${RELEASE_VERSION}" ]; then
    if git rev-parse -q --verify "refs/tags/v${RELEASE_VERSION}" >/dev/null; then RELEASE_TAG="v${RELEASE_VERSION}"; else RELEASE_TAG="${RELEASE_VERSION}"; fi
fi

if [ -z "${NIGHTLY_TAG}" ] && [ -z "${RELEASE_TAG}" ]; then
    if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
        die "no tags found in a shallow clone; fetch the tags (actions/checkout with fetch-depth: 0)"
    fi
    emit build true
    emit reason "no earlier nightly or release"
    exit 0
fi

if [ -n "${NIGHTLY_TAG}" ] && [ "$(git rev-parse "${NIGHTLY_TAG}^{commit}")" = "${HEAD_SHA}" ]; then
    emit build false
    emit reason "main has not changed since ${NIGHTLY_TAG}"
    exit 0
fi
if [ -n "${RELEASE_TAG}" ] && [ "$(git rev-parse "${RELEASE_TAG}^{commit}")" = "${HEAD_SHA}" ]; then
    emit build false
    emit reason "main is at release ${RELEASE_TAG}"
    exit 0
fi

emit build true
emit reason "main has new commits since the last nightly or release"
