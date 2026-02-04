#!/bin/bash
set -euo pipefail
set -x

MODE="${1:-}"
BRANCH="${GITHUB_REF_NAME}"
LANG="en"

install_deps() {
  sudo apt-get update
  sudo apt-get -y install git git-lfs rsync python3-pip python3-virtualenv python3-setuptools
  python3 -m pip install --upgrade \
    sphinx==8.2.3 \
    sphinx-rtd-theme==3.0.2 \
    importlib-metadata==8.7.0 \
    gitpython docutils==0.21.2 \
    rinohtype \
    pygments \
    sphinx-copybutton \
    sphinx_design \
    sphinx-tabs \
    sphinxcontrib.googleanalytics
  git config --global --add safe.directory '*'
}

latest_semver_branch() {
  git fetch --all --prune
  branches="$(git for-each-ref '--format=%(refname:lstrip=-1)' refs/remotes/origin/ | grep -viE '^(HEAD|gh-pages)$' || true)"
  versions="$(echo "$branches" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V || true)"
  echo "$versions" | tail -n 1 || true
}

build_only() {
  # Docs-only repo contract: conf.py must be at repo root
  [[ -f conf.py ]] || { echo "ERROR: conf.py not found at repo root"; exit 1; }

  # Clean build artifacts
  if [[ -f Makefile ]]; then
    make clean
  else
    echo "WARNING: Makefile not found, falling back to rm -rf _build"
    rm -rf _build
  fi

  # Build branch-scoped HTML output
  sphinx-build -b html . "_build/html/${LANG}/${BRANCH}" -D language="${LANG}"
}

deploy_only() {
  REPO_URL="https://token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  latest_branch="$(latest_semver_branch)"

  pages_dir="$(mktemp -d)"
  git clone --branch gh-pages --depth 1 "${REPO_URL}" "${pages_dir}"

  touch "${pages_dir}/.nojekyll"

  mkdir -p "${pages_dir}/${LANG}/${BRANCH}"
  rsync -a --delete "_build/html/${LANG}/${BRANCH}/" "${pages_dir}/${LANG}/${BRANCH}/"

  if [[ -n "${latest_branch}" && "${BRANCH}" == "${latest_branch}" ]]; then
    mkdir -p "${pages_dir}/${LANG}/latest"
    rsync -a --delete "_build/html/${LANG}/${BRANCH}/" "${pages_dir}/${LANG}/latest/"
  fi

  pushd "${pages_dir}"
  git config user.name "${GITHUB_ACTOR}"
  git config user.email "${GITHUB_ACTOR}@users.noreply.github.com"

  git add -A
  git commit -m "Docs: ${BRANCH} @ ${GITHUB_SHA}" || echo "No changes"
  git push origin gh-pages
  popd
}

install_deps

case "${MODE}" in
  build-only)  build_only ;;
  deploy-only) deploy_only ;;
  *) echo "Usage: $0 {build-only|deploy-only}" ; exit 2 ;;
esac
