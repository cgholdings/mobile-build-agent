#!/bin/bash
# Runs INSIDE the ephemeral Tart VM. Checks out the repo at the job's ref, then runs the
# mobile-app Makefile — which owns the ENTIRE build + publish (fastlane, flavors, signing, stores).
# The agent only does: git checkout -> make init -> make <make_target>.
# Vault-rendered creds are exported as env so the repo's make/fastlane can authenticate.
# Emits "@@STATUS {json}" lines on stdout — the host forwards them to RabbitMQ.
set -uo pipefail

MOUNT="/Volumes/My Shared Files/io"
CTX="$MOUNT/in/context.json"
OUT="$MOUNT/out"
WORK="$HOME/build"          # build on the VM's local disk (fast), not the virtio-fs share
mkdir -p "$OUT" "$WORK"
BUILD_LOG="$OUT/build.log"

# Toolchain env — this script runs under a NON-login bash, so the base image's ~/.zprofile (brew,
# pub-cache, Android SDK, rbenv) isn't sourced. Set it explicitly so make/fvm/melos/gradle resolve.
# rbenv shims MUST come first so ruby/bundle/pod use the app's pinned Ruby (app/.ruby-version),
# not macOS system Ruby 2.6 — otherwise `bundle` can't find the Gemfile.lock's bundler.
# ~/fvm/default/bin provides bare `dart`/`flutter` — the Fastfile's `melos run gen` shim calls bare
# `dart` (not `fvm exec`), so it must be on PATH.
export PATH="$HOME/.rbenv/shims:$HOME/.rbenv/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/fvm/default/bin:$HOME/.pub-cache/bin:$PATH"
export ANDROID_SDK_ROOT="/opt/homebrew/share/android-commandlinetools"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
# UTF-8 locale — fastlane/Ruby otherwise default to US-ASCII and throw "invalid byte sequence"
# on non-ASCII in the Fastfile. (make init sets these inline; deploy-* steps rely on the env.)
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 RUBYOPT=-EUTF-8

# ---- helpers ----------------------------------------------------------------
get() { # get <dotted.path> [default]
  python3 - "$CTX" "$1" "${2-}" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); dflt=sys.argv[3] if len(sys.argv)>3 else ""
cur=d
for p in sys.argv[2].split("."):
    cur = cur.get(p) if isinstance(cur,dict) else None
    if cur is None: break
print(dflt if cur is None else (json.dumps(cur) if isinstance(cur,(list,dict)) else cur))
PY
}
emit() { # emit <state> <phase> <progress> <message...>
  local st="$1" ph="$2" pr="$3"; shift 3
  python3 - "$st" "$ph" "$pr" "$*" <<'PY'
import json,sys
st,ph,pr,msg=sys.argv[1:5]
print("@@STATUS "+json.dumps({"state":st,"phase":ph,"progress":float(pr),"message":msg}))
PY
}
fail() { # fail <phase> <progress> <message...>
  local ph="$1" pr="$2"; shift 2
  python3 - "$OUT/result.json" "$ph" "$pr" "$*" <<'PY'
import json,sys
json.dump({"status":"failed","phase":sys.argv[2],"progress":float(sys.argv[3]),
           "message":sys.argv[4]}, open(sys.argv[1],"w"))
PY
  emit failed "$ph" "$pr" "$@"
  # include the log tail for the host to attach to the status
  tail -c 4000 "$BUILD_LOG" 2>/dev/null
  exit 1
}
# tee to stdout AND the file: stdout is what the host SSH captures and streams to Argo (line-level
# logs), build.log is kept in the VM's out/ (host-side shared dir) for the failure tail. pipefail
# (set above) makes the pipeline return the command's exit, not tee's, so `run x || fail` still works.
run() { echo "\$ $*" | tee -a "$BUILD_LOG"; "$@" 2>&1 | tee -a "$BUILD_LOG"; }

# ---- job --------------------------------------------------------------------
REPO=$(get repo)
REF=$(get ref main)
MAKE_TARGET=$(get make_target)
GITHUB_TOKEN=$(get github_token)      # short-lived GitHub App installation token, minted by the workflow
[ -z "$MAKE_TARGET" ] && fail parse 0.0 "job has no make_target"
echo "=== job $(get job_id): $REPO @ $REF -> make $MAKE_TARGET ===" >"$BUILD_LOG"

# ---- credentials -------------------------------------------------------------
# The mobile-app Fastfiles pull all signing/publish creds from Vault themselves
# (before_all -> load_vault_secrets). The agent only provides Vault access + the GitHub App token.
export VAULT_ADDR=$(get vault_addr https://vault.tech.cgholdings.internal)
export VAULT_TOKEN=$(get vault_token)   # short-lived Vault Agent token, injected by the host
export GITHUB_TOKEN=$(get github_token)
GIT_KEY=$(get _creds.git_ssh_key)       # optional SSH fallback if no github_token
[ -z "$VAULT_TOKEN" ] && fail creds 0.05 "no vault_token in job context (host injects it)"

# ---- checkout ---------------------------------------------------------------
emit building checkout 0.10 "cloning $REPO @ $REF"
rm -rf "$WORK/src"
if [ -n "$GITHUB_TOKEN" ]; then
  # GitHub App installation token (preferred). Set it globally for github.com so the clone AND
  # anything make/fastlane pulls from GitHub (pub git deps, submodules, match certs repo) is
  # authenticated. Via header (not URL) so it isn't in remote configs; VM is torn down after.
  AUTH="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
  git config --global "http.https://github.com/.extraheader" "$AUTH"
  run git clone "$REPO" "$WORK/src" || fail checkout 0.10 "git clone failed (bad/expired GitHub App token?)"
elif [ -n "$GIT_KEY" ]; then
  export GIT_SSH_COMMAND="ssh -i '$GIT_KEY' -o StrictHostKeyChecking=no"
  run git clone "$REPO" "$WORK/src" || fail checkout 0.10 "git clone failed (ssh key)"
else
  run git clone "$REPO" "$WORK/src" || fail checkout 0.10 "git clone failed (private repo needs auth)"
fi
cd "$WORK/src" || fail checkout 0.10 "repo dir missing"
run git checkout "$REF" || fail checkout 0.10 "git checkout $REF failed"

# ---- ensure the repo's pinned toolchain is present (make init assumes it; instant when baked) ----
emit building init 0.25 "fvm install (pinned Flutter)"
run fvm install || run bash -c "cd app 2>/dev/null && fvm install" || true
# app/.ruby-version pins Ruby for pod install / fastlane (rbenv). -s = skip if already installed.
run bash -c "cd '$WORK/src/app' 2>/dev/null && rbenv install -s" || run rbenv install -s || true

# ---- make init (FVM/Melos bootstrap, codegen, pods, fastlane gems) -----------
emit building init 0.30 "make init"
run make init || fail init 0.30 "make init failed"

# ---- make <target> (build + publish; fastlane under the hood) ---------------
emit publishing "$MAKE_TARGET" 0.60 "make $MAKE_TARGET"
run make "$MAKE_TARGET" || fail "$MAKE_TARGET" 0.60 "make $MAKE_TARGET failed"

# ---- done -------------------------------------------------------------------
python3 -c "import json;json.dump({'status':'succeeded','phase':'done','progress':1.0},open('$OUT/result.json','w'))"
emit succeeded done 1.0 "make $MAKE_TARGET complete"
