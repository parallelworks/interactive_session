set -o pipefail
################################################################################
# Interactive Session Controller - Hermes Agent (NousResearch Hermes)
#
# Purpose: install the real Hermes Agent (https://github.com/NousResearch/hermes-agent)
#          on the login node, which has internet. The official installer brings
#          its own uv / Python / Node, so the only hard prerequisites here are
#          curl + python3. Idempotent: the installer preserves an existing
#          install, and we skip it entirely if `hermes` is already on PATH.
# Runs on: cluster login node (scheduler:false)
# Called by: session_runner, after inputs.sh is sourced
#
# Variables from inputs.sh:
#   service_interface     dashboard | chat (dashboard needs the web UI pre-built)
#   service_model         brain model id (as `pw ai models ls` lists it)
#   service_allocation    X-Allocation for org:* models (e.g. "Private LLM Group")
#   service_hermes_version pinned NousResearch/hermes-agent ref (empty -> default below)
################################################################################

# Pin Hermes to a tested release. A plain install pulls the latest main, whose
# behavior has broken this workflow before (the v0.17 auth hardening stopped the
# dashboard binding 0.0.0.0; a 64-char X-Forwarded-Prefix cap blanked long
# session URLs). NousResearch/hermes-agent publishes date-based tags, so we pin
# one for reproducibility; the form can override it (a tag, branch, or commit
# SHA). Update this default only after verifying a newer release.
HERMES_VERSION_DEFAULT="v2026.6.19"

echo "::group::Prerequisites"
for bin in python3 curl bash; do
    command -v "$bin" >/dev/null 2>&1 || { echo "::error title=Missing $bin::$bin is required on this node but was not found"; exit 1; }
done
echo "::notice::python3 $(python3 --version 2>&1)"

# Private Python venv used to run the small resolve_model helper (Hermes itself
# brings its own Python via the installer).
. "${PW_PARENT_JOB_DIR}/tools/utils/agent_env.sh"
agent_python_setup
echo "::endgroup::"

export PATH="${HOME}/.local/bin:${PATH}"

HERMES_VERSION="${service_hermes_version:-$HERMES_VERSION_DEFAULT}"
hermes_repo="${HOME}/.hermes/hermes-agent"
hermes_url="https://github.com/NousResearch/hermes-agent.git"
# Resolve the pin to a commit SHA so the compare-and-install is exact. For a
# tag/branch, ls-remote returns its SHA (peeled to the commit for annotated tags
# via the ^{} ref, which sorts last); for a raw SHA it returns nothing and we
# use the value as-is. We hand the resolved SHA to --commit so the installer
# never has to resolve a ref itself (and a moved tag can't silently change it).
target_sha="$(git ls-remote "${hermes_url}" "${HERMES_VERSION}" "${HERMES_VERSION}^{}" 2>/dev/null | awk 'END{print $1}')"
target="${target_sha:-$HERMES_VERSION}"
installed_commit="$(git -C "${hermes_repo}" rev-parse HEAD 2>/dev/null || true)"
case "${installed_commit}" in
    "${target}"*) at_pin=1 ;;
    *) at_pin=0 ;;
esac

if command -v hermes >/dev/null 2>&1 && [ "${at_pin}" = 1 ]; then
    echo "::notice::Hermes already at pinned ${HERMES_VERSION} (${target}) ($(hermes --version 2>&1 | head -1))"
else
    echo "::group::Install Hermes Agent @ ${HERMES_VERSION} (${target}) (this can take a few minutes)"
    # --commit: pin the checkout (installer git-fetches + checks it out, switching
    # an existing install if the pin changed); --skip-setup: no wizard;
    # --non-interactive: no prompts; --skip-browser: skip the browser-tool download.
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
        | bash -s -- --skip-setup --non-interactive --skip-browser --commit "${target}"
    echo "::endgroup::"
    command -v hermes >/dev/null 2>&1 || { echo "::error title=Install failed::hermes not on PATH after install"; exit 1; }
    new_commit="$(git -C "${hermes_repo}" rev-parse HEAD 2>/dev/null || true)"
    case "${new_commit}" in
        "${target}"*) : ;;
        *) echo "::warning::Hermes HEAD ${new_commit:-unknown} does not match pin ${HERMES_VERSION} (${target}) after install" ;;
    esac
    echo "::notice::Installed: $(hermes --version 2>&1 | head -1)"
fi

# Dashboard interface needs the web UI built once (login node has node/npm via
# the installer). The build lands in hermes_cli/web_dist; start uses --skip-build.
if [ "${service_interface}" = "dashboard" ]; then
    # Raise Hermes' 64-char X-Forwarded-Prefix cap (normalise_prefix() in
    # hermes_cli/dashboard_auth/prefix.py). ACTIVATE session base paths
    # (/me/session/<user>/<workflow>_<run>_<key>) routinely exceed 64 chars; the
    # dashboard then rejects the prefix, leaves __HERMES_BASE_PATH__ empty, and
    # serves absolute /assets URLs that 404 under the session path -> blank page.
    # Raising the cap lets Hermes' own prefix-rewriting (assets, fonts, base
    # path, websockets) work for our long paths. Idempotent; verified per launch.
    prefix_py="$(find "${HOME}/.hermes" -path '*/hermes_cli/dashboard_auth/prefix.py' 2>/dev/null | head -1)"
    if [ -n "${prefix_py}" ] && grep -q 'len(p) > 64' "${prefix_py}"; then
        sed -i 's/len(p) > 64/len(p) > 1024/' "${prefix_py}"
        echo "::notice::Raised Hermes X-Forwarded-Prefix cap 64->1024 (${prefix_py})"
    elif [ -n "${prefix_py}" ] && grep -q 'len(p) > 1024' "${prefix_py}"; then
        echo "::notice::Hermes X-Forwarded-Prefix cap already raised"
    else
        echo "::warning::Could not find Hermes' X-Forwarded-Prefix cap to raise; long session URLs may blank-screen (see ${prefix_py:-prefix.py not found})"
    fi

    web_dist_index="${HOME}/.hermes/hermes-agent/hermes_cli/web_dist/index.html"
    if [ -f "${web_dist_index}" ]; then
        echo "::notice::Dashboard web UI already built"
    else
        echo "::group::Build Hermes dashboard web UI (one-time, a few minutes)"
        build_log="${PW_PARENT_JOB_DIR}/dashboard-build.out"
        # `hermes dashboard` builds the SPA then serves it; we just need the build,
        # so launch it on a throwaway loopback port and stop it once dist exists.
        hermes dashboard --no-open --host 127.0.0.1 --port 19119 > "${build_log}" 2>&1 &
        build_pid=$!
        for _ in $(seq 1 150); do
            [ -f "${web_dist_index}" ] && break
            sleep 2
        done
        pkill -P "${build_pid}" 2>/dev/null || true
        kill "${build_pid}" 2>/dev/null || true
        echo "::endgroup::"
        if [ -f "${web_dist_index}" ]; then
            echo "::notice::Dashboard web UI built"
        else
            echo "::error title=Dashboard build failed::web UI did not build; see ${build_log}"
            exit 1
        fi
    fi
fi

echo "::notice::Hermes ready | interface=${service_interface} | brain=https://${PW_PLATFORM_HOST}/api/openai/v1 | model=${service_model} | allocation=${service_allocation}"
