#!/bin/bash
set -euo pipefail
set -x

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

MODE="${1:-}"
BRANCH="${GITHUB_REF_NAME:-}"
DOC_LANG="en"

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

# Return all remote branch names we consider "published"
active_branches() {
  git fetch --all --prune
  git for-each-ref '--format=%(refname:lstrip=-1)' refs/remotes/origin/ | grep -viE '^(HEAD|gh-pages)$' || true
}

latest_semver_branch() {
  versions="$(active_branches | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V || true)"
  echo "$versions" | tail -n 1 || true
}

cleanup_gh_pages() {
  local pages_dir="$1"
  local latest_branch="$2"

  mkdir -p "${pages_dir}/${DOC_LANG}"

  # Build a fast lookup set of active branches
  declare -A alive=()
  while IFS= read -r b; do
    [[ -n "$b" ]] && alive["$b"]=1
  done < <(active_branches)

  # Remove stale branch directories (keep 'latest')
  if [[ -d "${pages_dir}/${DOC_LANG}" ]]; then
    for d in "${pages_dir}/${DOC_LANG}"/*; do
      [[ -d "$d" ]] || continue
      name="$(basename "$d")"

      # never delete the alias dir
      if [[ "$name" == "latest" ]]; then
        continue
      fi

      # if it isn't an active branch, remove it
      if [[ -z "${alive[$name]+x}" ]]; then
        echo "INFO: Removing stale docs directory: ${DOC_LANG}/${name}"
        rm -rf "$d"
      fi
    done
  fi

  # Keep latest alias correct (best effort)
  if [[ -n "${latest_branch}" && -d "${pages_dir}/${DOC_LANG}/${latest_branch}" ]]; then
    echo "INFO: Refreshing alias ${DOC_LANG}/latest from ${latest_branch}"
    mkdir -p "${pages_dir}/${DOC_LANG}/latest"
    rsync -a --delete \
      "${pages_dir}/${DOC_LANG}/${latest_branch}/" \
      "${pages_dir}/${DOC_LANG}/latest/"
  fi
}

build_only() {
  [[ -f conf.py ]] || { echo "ERROR: conf.py not found at repo root"; exit 1; }

  if [[ -f Makefile ]]; then
    make clean
  else
    echo "WARNING: Makefile not found, falling back to rm -rf _build"
    rm -rf _build
  fi

  sphinx-build -b html . "_build/html/${DOC_LANG}/${BRANCH}" -D language="${DOC_LANG}"
}

deploy_only() {
  : "${GITHUB_TOKEN:?GITHUB_TOKEN is required for deploy-only}"
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required for deploy-only}"

  REPO_URL="https://token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  latest_branch="$(latest_semver_branch)"

  pages_dir="$(mktemp -d)"
  git clone --branch gh-pages --depth 1 "${REPO_URL}" "${pages_dir}"

  touch "${pages_dir}/.nojekyll"

  # Copy only this branch subtree
  mkdir -p "${pages_dir}/${DOC_LANG}/${BRANCH}"
  rsync -a --delete "_build/html/${DOC_LANG}/${BRANCH}/" "${pages_dir}/${DOC_LANG}/${BRANCH}/"

  # If current branch is latest semver, update latest alias from build output
  if [[ -n "${latest_branch}" && "${BRANCH}" == "${latest_branch}" ]]; then
    mkdir -p "${pages_dir}/${DOC_LANG}/latest"
    rsync -a --delete "_build/html/${DOC_LANG}/${BRANCH}/" "${pages_dir}/${DOC_LANG}/latest/"
  fi

  # Always cleanup stale branches (and best-effort fix latest alias)
  cleanup_gh_pages "${pages_dir}" "${latest_branch}"

  pushd "${pages_dir}"
  git config user.name "${GITHUB_ACTOR}"
  git config user.email "${GITHUB_ACTOR}@users.noreply.github.com"

  git add -A
  git commit -m "Docs: ${BRANCH} @ ${GITHUB_SHA}" || echo "No changes"
  git push origin gh-pages
  popd
}

cleanup_only() {
  : "${GITHUB_TOKEN:?GITHUB_TOKEN is required for cleanup-only}"
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required for cleanup-only}"

  REPO_URL="https://token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  latest_branch="$(latest_semver_branch)"

  pages_dir="$(mktemp -d)"
  git clone --branch gh-pages --depth 1 "${REPO_URL}" "${pages_dir}"
  touch "${pages_dir}/.nojekyll"

  cleanup_gh_pages "${pages_dir}" "${latest_branch}"

  pushd "${pages_dir}"
  git config user.name "${GITHUB_ACTOR}"
  git config user.email "${GITHUB_ACTOR}@users.noreply.github.com"

  git add -A
  git commit -m "Docs: cleanup stale branches" || echo "No changes"
  git push origin gh-pages
  popd
}

install_deps

case "${MODE}" in
  build-only)    build_only ;;
  deploy-only)   deploy_only ;;
  cleanup-only)  cleanup_only ;;
  *) echo "Usage: $0 {build-only|deploy-only|cleanup-only}" ; exit 2 ;;
esac