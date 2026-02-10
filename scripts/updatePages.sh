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
# IMPORTANT: do NOT rely on locally-fetched refs in CI (often shallow/single-branch).
active_branches() {
  # origin must exist (actions/checkout sets it)
  git remote get-url origin >/dev/null 2>&1 || { echo "ERROR: remote 'origin' not found"; exit 1; }

  # List remote heads, strip refs/heads/, filter out gh-pages + HEAD
  git ls-remote --heads origin \
    | awk '{print $2}' \
    | sed -E 's#^refs/heads/##' \
    | grep -viE '^(HEAD|gh-pages)$' \
    || true
}

latest_semver_branch() {
  versions="$(active_branches | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V || true)"
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

  echo "DEBUG: active_branches returned ${#alive[@]} branches:"
  for k in "${!alive[@]}"; do
    echo "  - $k"
  done | sort

  # Safety: if branch discovery fails, do NOT delete anything.
  # Tune the threshold if needed, but 1 is already safer than “oops, nuked everything”.
  if [[ "${#alive[@]}" -lt 1 ]]; then
    echo "ERROR: active_branches returned 0 branches; refusing to delete anything from gh-pages."
    return 1
  fi

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
  # If latest_branch exists in gh-pages, mirror it into /latest.
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

write_versions_json() {
  local pages_dir="$1"
  local lang="$2"

  # IMPORTANT:
  # Your public URLs are /docs/en/<version>/...
  # So this manifest should be served at /docs/versions.json
  # Which corresponds to gh-pages repo root: ${pages_dir}/versions.json
  local out="${pages_dir}/versions.json"

  python3 - <<'PY' "${pages_dir}" "${lang}" "${out}"
import json, os, re, sys

pages_dir, lang, out = sys.argv[1], sys.argv[2], sys.argv[3]

lang_dir = os.path.join(pages_dir, lang)
if not os.path.isdir(lang_dir):
    # Nothing to publish yet; write empty but valid JSON.
    with open(out, "w") as f:
        json.dump({"versions": []}, f)
    sys.exit(0)

# Collect version directories like 2.9, 3.0, 4.5, 4.5.3 (whatever you use)
semver_re = re.compile(r"^\d+\.\d+(\.\d+)?$")
entries = []
for name in os.listdir(lang_dir):
    p = os.path.join(lang_dir, name)
    if not os.path.isdir(p):
        continue
    if semver_re.match(name):
        entries.append(name)

# Sort semver-ish using tuple numeric ordering
def ver_key(v):
    return tuple(int(x) for x in v.split("."))

entries.sort(key=ver_key)

versions = [{"id": v, "title": v, "url": f"/docs/{lang}/{v}/"} for v in entries]

# Add "latest" if it exists
if os.path.isdir(os.path.join(lang_dir, "latest")):
    versions.append({"id": "latest", "title": "latest", "url": f"/docs/{lang}/latest/"})

os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w") as f:
    json.dump({"versions": versions}, f, indent=2)
PY
}

deploy_only() {
  : "${GITHUB_TOKEN:?GITHUB_TOKEN is required for deploy-only}"
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required for deploy-only}"

  REPO_URL="https://token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  latest_branch="$(latest_semver_branch)"
  echo "INFO: latest resolves to ${latest_branch}"

  pages_dir="$(mktemp -d)"
  git clone --branch gh-pages --depth 1 "${REPO_URL}" "${pages_dir}"

  touch "${pages_dir}/.nojekyll"

  # Copy only this branch subtree (safe to use --delete because it's scoped)
  mkdir -p "${pages_dir}/${DOC_LANG}/${BRANCH}"
  rsync -a --delete "_build/html/${DOC_LANG}/${BRANCH}/" "${pages_dir}/${DOC_LANG}/${BRANCH}/"

  # If current branch is latest semver, update latest alias from build output
  if [[ -n "${latest_branch}" && "${BRANCH}" == "${latest_branch}" ]]; then
    mkdir -p "${pages_dir}/${DOC_LANG}/latest"
    rsync -a --delete "_build/html/${DOC_LANG}/${BRANCH}/" "${pages_dir}/${DOC_LANG}/latest/"
  fi

  # Enforce rule: keep dirs for existing branches; delete dirs for non-existent branches
  cleanup_gh_pages "${pages_dir}" "${latest_branch}"

  # NEW: regenerate the global version manifest on every deploy
  write_versions_json "${pages_dir}" "${DOC_LANG}"

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