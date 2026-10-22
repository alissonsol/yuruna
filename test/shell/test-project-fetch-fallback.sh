#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# The Pester driver supplies a redirected production wrapper; every request is local.
unset E_SHA EXEC_SHA256 E_RETRY_SHA EXEC_RETRY_SHA256 EXEC_REQUIRE_SHA256 EXEC_ALLOW_UNVERIFIED \
      E_FB_REPO E_FB_REF E_PROJECT_REPO E_PROJECT_REF EXEC_FALLBACK_REPO EXEC_FALLBACK_REF \
      YURUNA_GITHUB_REPO YURUNA_GITHUB_REF EXEC_BASE_URL EXEC_QUERY_PARAMS YurunaCacheContent \
      GH_TOKEN E_SI E_QI FAE_INVOCATION_SCRIPT YURUNA_STATUS_SERVICE_IP YURUNA_STATUS_SERVICE_PORT \
      YURUNA_CACHING_PROXY_SERVICE_IP
work=$(mktemp -d)
fae_test_mktemp=$(command -v mktemp)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/lib"
cp -- "$1" "$work/wrapper.sh"
cat > "$work/bin/mktemp" <<'MKTEMP'
#!/bin/bash
case "${1:-}" in
    /tmp/yuruna-fae-auth.*)
        [ "${FAE_TEST_AUTH_SETUP:-}" != fail ] || exit 1 ;;
esac
exec "$FAE_TEST_REAL_MKTEMP" "$@"
MKTEMP
cat > "$work/bin/wget" <<'WGET'
#!/bin/bash
out='' config='' url=''
printf '%s\n' '@@REQUEST' >> "$FAE_TEST_CALLS"
for arg in "$@"; do printf '%s\n' "$arg" >> "$FAE_TEST_CALLS"; done
while [ "$#" -gt 0 ]; do
    case "$1" in
        -qO|-O) out="$2"; shift ;;
        --config=*) config="${1#--config=}" ;;
        http://*|https://*) url="$1" ;;
    esac
    shift
done
if [ -n "$config" ]; then
    printf '%s\n' "$config" >> "$FAE_TEST_CONFIGS"
    printf 'CONFIG_MODE=%s\n' "$(stat -c %a "$config" 2>/dev/null || stat -f %Lp "$config")" >> "$FAE_TEST_CALLS"
    if grep -Fq "header = Authorization: Bearer $FAE_TEST_SECRET" "$config"; then
        printf '%s\n' 'AUTH_HEADER_MATCH=1' >> "$FAE_TEST_CALLS"
    fi
fi
case "$url" in
    */livecheck)
        [ "${FAE_TEST_HOST:-absent}" = present ]; exit $? ;;
    */git-mirror/status.json)
        [ "${FAE_TEST_MIRROR:-present}" = present ]; exit $? ;;
    */git-raw/*)
        if [ "${FAE_TEST_MIRROR_RAW:-}" = missing ]; then
            printf '  HTTP/1.1 404 Not found\n' >&2; exit 8
        fi
        if [ "${FAE_TEST_MIRROR_RAW:-}" = mismatch ]; then
            printf '  HTTP/1.1 200 OK\n' >&2
            printf 'echo WRONG_PAYLOAD_RAN\n' > "$out"; exit 0
        fi
        if [ "${FAE_TEST_MIRROR_RAW:-}" = oversized ]; then
            head -c 16777217 /dev/zero > "$out"; exit $?
        fi ;;
esac
if [ "$FAE_TEST_HTTP" != unavailable ]; then
    printf '  HTTP/1.1 %s Fixture response\n' "$FAE_TEST_HTTP" >&2
    printf '  Set-Cookie: private=%s\n' "$FAE_TEST_SECRET" >&2
fi
if [ "$FAE_TEST_WGET_EXIT" != 0 ]; then exit "$FAE_TEST_WGET_EXIT"; fi
case "$url" in
    */guest/ubuntu.server.26/ubuntu.server.26.update.sh|*/guest/ubuntu.server.26/ubuntu.server.26.update.sh?*)
        cat "$FAE_TEST_DIR/nested-parent" > "$out" ;;
    */automation/yuruna-retry.sh|*/automation/yuruna-retry.sh?*)
        cat "$FAE_TEST_DIR/library" > "$out" ;;
    *) cat "$FAE_TEST_DIR/payload" > "$out" ;;
esac
WGET
cat > "$work/bin/timeout" <<'TIMEOUT'
#!/bin/bash
# Suppress only the unrelated provenance probe; payload execution stays real.
for arg in "$@"; do [ "$arg" != guest_evidence_provenance ] || exit 0; done
exec "$FAE_TEST_REAL_TIMEOUT" "$@"
TIMEOUT
printf '#!/bin/bash\nexit 0\n' > "$work/bin/clear"
printf '#!/bin/bash\nprintf "1 eth0 inet 192.0.2.20/24\\n"\n' > "$work/bin/ip"
printf '#!/bin/bash\nexit 0\n' > "$work/bin/sleep"
printf '#!/bin/bash\nexec "$@"\n' > "$work/bin/sudo"
chmod +x "$work/bin/"*
# shellcheck disable=SC2016
printf 'echo PAYLOAD_RAN\nexit "${FAE_TEST_PAYLOAD_EXIT:-0}"\n' > "$work/payload"
cat > "$work/nested-parent" <<'NESTED'
echo PARENT_DELEGATING
export E_SHA="$FAE_TEST_CHILD_SHA"
exec bash "$FAE_TEST_DIR/wrapper.sh" 'guest/shared/update.sh?nocache=child'
NESTED
printf '# framework retry library fixture\n' > "$work/library"
good=$( (sha256sum "$work/payload" 2>/dev/null || shasum -a 256 "$work/payload") | awk '{print $1}')
nestedgood=$( (sha256sum "$work/nested-parent" 2>/dev/null || shasum -a 256 "$work/nested-parent") | awk '{print $1}')
libgood=$( (sha256sum "$work/library" 2>/dev/null || shasum -a 256 "$work/library") | awk '{print $1}')
framework_ref=1111111111111111111111111111111111111111
project_ref=2222222222222222222222222222222222222222
secret=fixture-project-token-that-must-not-appear

scenario() {
    local name="$1" path="$2" library="$3" rc=0 config remaining=0 field
    shift 3
    : > "$work/calls"
    : > "$work/configs"
    rm -f "$work/lib/yuruna-retry.sh"
    [ "$library" != present ] || : > "$work/lib/yuruna-retry.sh"
    printf '# Yuruna fetch-and-execute log\n# script: old/success.sh\n# stepInvocationId: old-step\n# sequenceInvocationId: old-sequence\n# ---\nOLD_SUCCESS_SENTINEL\n# exit code: 0\n' > "$work/log"
    env PATH="$work/bin:$PATH" EXEC_PROFILE=0 EXEC_RECORDER=0 EXEC_KEEP_PROFILE=0 \
        FAE_TEST_DIR="$work" FAE_TEST_CALLS="$work/calls" FAE_TEST_CONFIGS="$work/configs" \
        FAE_TEST_REAL_MKTEMP="$fae_test_mktemp" \
        FAE_TEST_REAL_TIMEOUT="$(command -v timeout)" \
        FAE_TEST_SECRET="$secret" FAE_TEST_HTTP=200 FAE_TEST_WGET_EXIT=0 FAE_TEST_PAYLOAD_EXIT=0 FAE_TEST_CHILD_SHA="$good" \
        E_FB_REPO=framework/repository E_FB_REF="$framework_ref" \
        E_PROJECT_REPO=private/project E_PROJECT_REF="$project_ref" \
        E_SHA="$good" E_RETRY_SHA="$libgood" EXEC_REQUIRE_SHA256=1 \
        E_SI="step-$name" E_QI=sequence-current "$@" \
        bash "$work/wrapper.sh" "$path" </dev/null > "$work/out" 2> "$work/err" || rc=$?
    while IFS= read -r config; do
        [ ! -e "$config" ] || remaining=$((remaining + 1))
    done < "$work/configs"
    printf '@@CASE %s %s %s\n' "$name" "$rc" "$remaining"
    for field in out err log calls; do
        printf '%s=' "$field"
        base64 < "$work/$field" | tr -d '\r\n'
        printf '\n'
    done
    printf '%s\n' '@@END'
}

scenario host project/example/workload.sh present EXEC_BASE_URL=http://host.invalid/yuruna-repo/ E_PROJECT_REPO= E_PROJECT_REF=
scenario base project/example/workload.sh present EXEC_BASE_URL=https://manual.invalid/source/ E_PROJECT_REPO= E_PROJECT_REF=
scenario project project/example/workload.sh present
scenario authenticated project/example/workload.sh present GH_TOKEN="$secret"
scenario missing project/example/workload.sh present E_PROJECT_REPO= E_PROJECT_REF=
scenario partial project/example/workload.sh present E_PROJECT_REF=
scenario invalid project/example/workload.sh present E_PROJECT_REF=main
scenario unauthenticated project/example/workload.sh present FAE_TEST_HTTP=404 FAE_TEST_WGET_EXIT=8
scenario denied project/example/workload.sh present GH_TOKEN="$secret" FAE_TEST_HTTP=401 FAE_TEST_WGET_EXIT=8
scenario auth_setup project/example/workload.sh present GH_TOKEN="$secret" FAE_TEST_AUTH_SETUP=fail
scenario library project/example/workload.sh absent
scenario mismatch project/example/workload.sh present E_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
scenario server_error project/example/workload.sh present FAE_TEST_HTTP=503 FAE_TEST_WGET_EXIT=8
scenario transport project/example/workload.sh present FAE_TEST_HTTP=unavailable FAE_TEST_WGET_EXIT=4
scenario framework guest/workload.sh present E_PROJECT_REPO= E_PROJECT_REF=
scenario framework_missing guest/workload.sh present E_FB_REPO= E_FB_REF=
scenario payload_failure project/example/workload.sh present FAE_TEST_PAYLOAD_EXIT=7
scenario sensitive_url project/example/workload.sh present EXEC_BASE_URL="http://operator:$secret@host.invalid/source/?token=$secret&path="
scenario host_query 'project/example/workload.sh?nocache=path-source' present EXEC_BASE_URL=http://host.invalid/yuruna-repo/ 'EXEC_QUERY_PARAMS=?extra=override'
scenario base_query 'project/example/workload.sh?nocache=path-source' present EXEC_BASE_URL=https://manual.invalid/source/ 'EXEC_QUERY_PARAMS=&extra=override'
scenario base_existing_query 'project/example/workload.sh?nocache=path-source' present 'EXEC_BASE_URL=https://manual.invalid/source/?path=' 'EXEC_QUERY_PARAMS=?extra=override'
scenario project_query 'project/example/workload.sh?nocache=path-source' present 'EXEC_QUERY_PARAMS=?extra=override'
scenario authenticated_query 'project/example/workload.sh?nocache=path-source' present GH_TOKEN="$secret" 'EXEC_QUERY_PARAMS=?extra=override'
scenario nested guest/ubuntu.server.26/ubuntu.server.26.update.sh present E_SHA="$nestedgood"
scenario invalid_identity project/example/workload.sh present FAE_INVOCATION_SCRIPT=../forged.sh
scenario mirror guest/workload.sh present YURUNA_CACHING_PROXY_SERVICE_IP=mirror.invalid GH_TOKEN="$secret"
scenario mirror_project project/example/workload.sh present YURUNA_CACHING_PROXY_SERVICE_IP=mirror.invalid
scenario mirror_library guest/workload.sh absent YURUNA_CACHING_PROXY_SERVICE_IP=mirror.invalid
scenario mirror_mismatch guest/workload.sh present YURUNA_CACHING_PROXY_SERVICE_IP=mirror.invalid FAE_TEST_MIRROR_RAW=mismatch
scenario mirror_missing guest/workload.sh present YURUNA_CACHING_PROXY_SERVICE_IP=mirror.invalid FAE_TEST_MIRROR_RAW=missing GH_TOKEN="$secret"
scenario mirror_old guest/workload.sh present YURUNA_CACHING_PROXY_SERVICE_IP=mirror.invalid FAE_TEST_MIRROR=absent
scenario mirror_unpinned guest/workload.sh present YURUNA_CACHING_PROXY_SERVICE_IP=mirror.invalid E_FB_REF=main
scenario mirror_host guest/workload.sh present YURUNA_CACHING_PROXY_SERVICE_IP=mirror.invalid YURUNA_STATUS_SERVICE_IP=host.invalid YURUNA_STATUS_SERVICE_PORT=8080 FAE_TEST_HOST=present
scenario mirror_oversized guest/workload.sh present YURUNA_CACHING_PROXY_SERVICE_IP=mirror.invalid FAE_TEST_MIRROR_RAW=oversized
