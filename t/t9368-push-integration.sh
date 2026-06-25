#!/bin/bash

# Integration test for the PUSH-side hardening: a fresh bulk push to a REAL wiki
# must complete with 0 transient retries and 0 deadlocks, and the DRY_RUN /
# PROFILE run-time toggles must behave. Unlike t9367 (which mocks the API), this
# drives the live git-remote-mediawiki client against an external wiki.
#
# GATED: skips unless a target wiki is provided. The deadlock it guards against is
# specific to a heavy MWCD-style wiki under the dist-encrypted load-guards
# (LinksUpdate/searchindex concurrency); point this at such a wiki, RELAXED, to
# exercise the real scenario. Against a vanilla wiki it still proves a clean push
# (all pages pushed, no retries).
#
# Required env:
#   GMW_IT_URL    action-API base, e.g. https://old.whonix.org/w
#   GMW_IT_USER   push login (a bot password login, e.g. Admin@gitmw)
#   GMW_IT_PASS   push password
# Optional env:
#   GMW_IT_CA          CA bundle for the wiki's TLS (PERL_LWP_SSL_CA_FILE + curl --cacert)
#   GMW_IT_ADMIN_USER  delete-capable login used ONLY to clean up the test pages
#   GMW_IT_ADMIN_PASS  its password (falls back to GMW_IT_USER/PASS)
#   GMW_IT_PAGES       how many sample pages to push (default 12)

set -o errexit
set -o nounset
set -o pipefail

self_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
gmw_helper="${self_dir}/.."
prefix="Gmw_IT_$$"
fail=0

note() { printf '# %s\n' "$*"; }
ok()   { printf 'ok - %s\n' "$1"; }
notok(){ printf 'not ok - %s\n' "$1"; fail=1; }
assert_eq() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1 (= $3)"; else notok "$1 (expected $2, got $3)"; fi
}

if [ -z "${GMW_IT_URL:-}" ] || [ -z "${GMW_IT_USER:-}" ] || [ -z "${GMW_IT_PASS:-}" ]; then
  printf '1..0 # SKIP set GMW_IT_URL, GMW_IT_USER, GMW_IT_PASS to run the push integration test\n'
  exit 0
fi

api="${GMW_IT_URL}"
ca="${GMW_IT_CA:-}"
npages="${GMW_IT_PAGES:-12}"
curl_ca=(); [ -z "${ca}" ] || curl_ca=(--cacert "${ca}")
[ -z "${ca}" ] || export PERL_LWP_SSL_CA_FILE="${ca}"

gmw="${GIT_MEDIAWIKI_PATCHED:-${HOME}/.local/bin/git-mediawiki-patched}"
if ! [ -x "${gmw}" ]; then gmw=(git --exec-path="${gmw_helper}"); else gmw=("${gmw}"); fi

work="$(mktemp -d)"
cleanup_repo() { rm -rf "${work}"; }
trap cleanup_repo EXIT

setup_repo() { # prefix -> N .mw pages of real-ish content with links
  local p="$1" i k shared unique
  rm -rf "${work}/r"; mkdir -p "${work}/r"; git -C "${work}/r" init -q
  git -C "${work}/r" symbolic-ref HEAD refs/heads/master
  git -C "${work}/r" config remote.t.url "mediawiki::${api}"
  git -C "${work}/r" config remote.t.mwLogin "${GMW_IT_USER}"
  git -C "${work}/r" config remote.t.mwPassword "${GMW_IT_PASS}"
  git -C "${work}/r" config remote.t.dumbPush true
  # Link-HEAVY content: 10 SHARED external links (every page references the same
  # URLs, so LinksUpdate writes contend on the same externallinks rows -- the
  # deadlock-prone path the load-guards fix) plus 20 unique ones. This stresses the
  # externallinks/LinksUpdate write path the guards protect; a guarded push must
  # complete with 0 retries / 0 deadlocks. NB: the deadlock is a concurrency race
  # that reliably manifests at full-push SCALE (thousands of pages), so a small
  # sample validates the guarded INVARIANT rather than forcing the race.
  shared=""
  for k in $(seq 1 10); do shared="${shared}* [https://shared.example/r${k} shared ${k}]"$'\n'; done
  for i in $(seq 1 "${npages}"); do
    unique=""
    for k in $(seq 1 20); do unique="${unique}* [https://uniq.example/${p}/${i}/u${k} u${k}]"$'\n'; done
    printf '%s' "== ${p} ${i} ==
[[Main Page]] and [[${p}$(( i % 3 + 1 ))|a sibling]].
${shared}${unique}" > "${work}/r/${p}${i}.mw"
  done
  git -C "${work}/r" add -A && git -C "${work}/r" -c user.email=t@t -c user.name=t commit -q -m "${p}"
}

page_state() { # title -> EXISTS|MISSING
  curl -s "${curl_ca[@]}" "${api}/api.php?action=query&titles=$1&format=json" \
    | python3 -c 'import json,sys;p=list(json.load(sys.stdin)["query"]["pages"].values())[0];print("MISSING" if "missing" in p else "EXISTS")'
}

printf '1..6\n'

# 1-3: a real bulk push is clean -- all pages land, no retries, no deadlocks.
setup_repo "${prefix}"
push_log="${work}/push.log"
"${gmw[@]}" -C "${work}/r" push t "+refs/heads/master:refs/heads/master" >"${push_log}" 2>&1 || true
pushed="$(grep -c 'Pushed file' "${push_log}" || true)"
retries="$(grep -cE 'Transient failure to|giving up' "${push_log}" || true)"
deadlocks="$(grep -ciE 'deadlock' "${push_log}" || true)"
assert_eq "all ${npages} sample pages pushed" "${npages}" "${pushed}"
assert_eq "0 transient retries on a guarded push" "0" "${retries}"
assert_eq "0 deadlocks on a guarded push" "0" "${deadlocks}"

# 4-5: DRY_RUN walks but mutates nothing.
setup_repo "${prefix}D"
dry_log="${work}/dry.log"
GIT_MEDIAWIKI_DRY_RUN=1 "${gmw[@]}" -C "${work}/r" push t "+refs/heads/master:refs/heads/master" >"${dry_log}" 2>&1 || true
dry_lines="$(grep -c 'DRY-RUN: would push' "${dry_log}" || true)"
assert_eq "dry-run logged all ${npages} would-be pushes" "${npages}" "${dry_lines}"
assert_eq "dry-run created NO page" "MISSING" "$(page_state "${prefix}D1")"

# 6: PROFILE prints a per-push summary.
setup_repo "${prefix}P"
prof_log="${work}/prof.log"
GIT_MEDIAWIKI_PROFILE=1 "${gmw[@]}" -C "${work}/r" push t "+refs/heads/master:refs/heads/master" >"${prof_log}" 2>&1 || true
if grep -qE "profile: ${npages} edits, total" "${prof_log}"; then
  ok "profile summary printed for ${npages} edits"
else
  notok "profile summary printed"; sed -n '$p' "${prof_log}"
fi

# Best-effort cleanup of the pages this test created.
del_user="${GMW_IT_ADMIN_USER:-${GMW_IT_USER}}"
del_pass="${GMW_IT_ADMIN_PASS:-${GMW_IT_PASS}}"
cj="$(mktemp)"
lt="$(curl -s "${curl_ca[@]}" -c "${cj}" "${api}/api.php?action=query&meta=tokens&type=login&format=json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["query"]["tokens"]["logintoken"])')"
curl -s "${curl_ca[@]}" -b "${cj}" -c "${cj}" "${api}/api.php" --data-urlencode action=login --data-urlencode "lgname=${del_user}" --data-urlencode "lgpassword=${del_pass}" --data-urlencode "lgtoken=${lt}" --data-urlencode format=json >/dev/null || true
ct="$(curl -s "${curl_ca[@]}" -b "${cj}" "${api}/api.php?action=query&meta=tokens&type=csrf&format=json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["query"]["tokens"]["csrftoken"])')"
for sub in "${prefix}" "${prefix}D" "${prefix}P"; do
  for t in $(curl -s "${curl_ca[@]}" "${api}/api.php?action=query&list=allpages&apprefix=${sub}&aplimit=500&format=json" | python3 -c 'import json,sys;[print(p["title"]) for p in json.load(sys.stdin)["query"]["allpages"]]' 2>/dev/null); do
    curl -s "${curl_ca[@]}" -b "${cj}" "${api}/api.php" --data-urlencode action=delete --data-urlencode "title=${t}" --data-urlencode "token=${ct}" --data-urlencode format=json >/dev/null || true
  done
done
rm -f "${cj}"

note "push integration: $([ "${fail}" -eq 0 ] && echo PASS || echo FAIL)"
exit "${fail}"
