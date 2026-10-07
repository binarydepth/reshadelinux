# shellcheck shell=bash
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck disable=SC2154  # _shaderRepo* are set by parseShaderRepoEntry in shader_registry.sh

function printUsage() {
    printf 'Usage: %s [options]\n' "$0"
    printf '  --update-all              Re-link ReShade for all previously installed games.\n'
    printf '  --cli                     Force the plain CLI backend.\n'
    printf '  --ui-backend=<backend>    Force auto, yad, whiptail, dialog, or cli.\n'
    printf '  --game-path=<path>        Use an explicit game directory or .exe path.\n'
    printf '  --app-id=<appid>          Select a detected Steam game by App ID, or persist it with --game-path.\n'
    printf '  --dll-override=<name>     Use an explicit ReShade DLL override, e.g. dxgi or d3d9.\n'
    printf '  --shader-repos=<value>    Use all, none, or a comma-separated repo list. With --update-all, override the tracked repos for every game in the batch.\n'
    printf '  --list-shader-repos       Print the configured shader repo names and labels.\n'
    printf '  --json                    With --list-shader-repos, print registry data as JSON.\n'
    printf '  --generate-vkbasalt-config=<game-dir> Generate vkBasalt.conf from the active ReShade preset.\n'
    printf '  --inspect-reshade-parameters=<game-dir|ReShade.ini> Report enabled effects, preset values, and source uniforms.\n'
    printf '  --version, -V             Show the script version.\n'
    printf '  --help, -h                Show this help message.\n'
}

function printCliVersion() {
    printf '%s\n' "${SCRIPT_VERSION:-unknown}"
}

function printAvailableShaderRepos() {
    local _entry _label

    printf 'Configured shader repositories:\n'
    while IFS= read -r _entry || [[ -n $_entry ]]; do
        parseShaderRepoEntry "$_entry"
        _label=$(formatShaderRepoDisplayLabel "$_shaderRepoUri" "$_shaderRepoTitle" "$_shaderRepoDesc")
        printf '  %s\t%s\n' "$_shaderRepoName" "$_label"
    done < <(listConfiguredShaderRepoEntries)
}

function printAvailableShaderReposJson() {
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'Python 3 is required for JSON output.\n' >&2
        return 1
    fi

    {
        local _entry
        while IFS= read -r _entry || [[ -n $_entry ]]; do
            parseShaderRepoEntry "$_entry"
            printf '%s\0' \
                "$_shaderRepoName" \
                "$_shaderRepoUri" \
                "$_shaderRepoBranch" \
                "$_shaderRepoTitle" \
                "$_shaderRepoDesc" \
                "$_shaderRepoRequires"
        done < <(listConfiguredShaderRepoEntries)
    } | python3 -c '
import json
import sys

fields = sys.stdin.buffer.read().decode("utf-8").split("\0")
if fields[-1] == "":
    fields.pop()
if len(fields) % 6:
    raise SystemExit("Could not serialize the shader repository registry.")

repos = []
for index in range(0, len(fields), 6):
    name, uri, branch, title, description, requires = fields[index:index + 6]
    repos.append({
        "name": name,
        "uri": uri,
        "branch": branch,
        "title": title,
        "description": description,
        "requires": [item.strip() for item in requires.split(",") if item.strip()],
    })
json.dump(repos, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
'
}

function handleCliInfoArgs() {
    if [[ ${CLI_GENERATE_VKBASALT_SET:-0} -eq 1 ]]; then
        generateVkbasaltConfig "$CLI_GENERATE_VKBASALT_PATH" || exit $?
        exit 0
    fi

    if [[ ${CLI_INSPECT_RESHADE_PARAMETERS_SET:-0} -eq 1 ]]; then
        inspectReshadeParameters "$CLI_INSPECT_RESHADE_PARAMETERS_PATH" || exit $?
        exit 0
    fi

    if [[ ${CLI_LIST_SHADER_REPOS:-0} -eq 1 ]]; then
        if [[ ${CLI_JSON:-0} -eq 1 ]]; then
            printAvailableShaderReposJson || exit $?
        else
            printAvailableShaderRepos
        fi
        exit 0
    fi
}

function parseCliArgs() {
    _BATCH_UPDATE=0
    CLI_FORCE_CLI_SET=0
    CLI_UI_BACKEND_SET=0
    CLI_GAME_PATH=""
    CLI_GAME_PATH_SET=0
    CLI_APP_ID=""
    CLI_APP_ID_SET=0
    CLI_DLL_OVERRIDE=""
    CLI_DLL_OVERRIDE_SET=0
    CLI_SHADER_REPOS=""
    CLI_SHADER_REPOS_SET=0
    CLI_LIST_SHADER_REPOS=0
    CLI_JSON=0
    CLI_GENERATE_VKBASALT_PATH=""
    CLI_GENERATE_VKBASALT_SET=0
    CLI_INSPECT_RESHADE_PARAMETERS_PATH=""
    CLI_INSPECT_RESHADE_PARAMETERS_SET=0

    local _arg
    for _arg in "$@"; do
        case "$_arg" in
            --update-all)
                _BATCH_UPDATE=1
                ;;
            --cli)
                UI_BACKEND=cli
                CLI_FORCE_CLI_SET=1
                ;;
            --ui-backend=*)
                UI_BACKEND="$(_trim_cli_value "${_arg#*=}")"
                UI_BACKEND="${UI_BACKEND,,}"
                CLI_UI_BACKEND_SET=1
                ;;
            --game-path=*)
                CLI_GAME_PATH="${_arg#*=}"
                CLI_GAME_PATH_SET=1
                ;;
            --app-id=*)
                CLI_APP_ID="${_arg#*=}"
                CLI_APP_ID_SET=1
                ;;
            --dll-override=*)
                CLI_DLL_OVERRIDE="${_arg#*=}"
                CLI_DLL_OVERRIDE_SET=1
                ;;
            --shader-repos=*)
                CLI_SHADER_REPOS="${_arg#*=}"
                CLI_SHADER_REPOS_SET=1
                ;;
            --list-shader-repos)
                CLI_LIST_SHADER_REPOS=1
                ;;
            --json)
                CLI_JSON=1
                ;;
            --generate-vkbasalt-config=*)
                CLI_GENERATE_VKBASALT_PATH="${_arg#*=}"
                CLI_GENERATE_VKBASALT_SET=1
                ;;
            --inspect-reshade-parameters=*)
                CLI_INSPECT_RESHADE_PARAMETERS_PATH="${_arg#*=}"
                CLI_INSPECT_RESHADE_PARAMETERS_SET=1
                ;;
            --version|-V)
                printCliVersion
                exit 0
                ;;
            --help|-h)
                printUsage
                exit 0
                ;;
            *)
                printf 'Unknown argument: %s\n\n' "$_arg" >&2
                printUsage >&2
                exit 1
                ;;
        esac
    done
}

function _trim_cli_value() {
    local _value="$1"
    _value="${_value#"${_value%%[![:space:]]*}"}"
    _value="${_value%"${_value##*[![:space:]]}"}"
    printf '%s\n' "$_value"
}

function validateCliArgs() {
    if [[ ${CLI_INSPECT_RESHADE_PARAMETERS_SET:-0} -eq 1 ]]; then
        CLI_INSPECT_RESHADE_PARAMETERS_PATH=$(_trim_cli_value "$CLI_INSPECT_RESHADE_PARAMETERS_PATH")
        [[ -n $CLI_INSPECT_RESHADE_PARAMETERS_PATH ]] || printErr "--inspect-reshade-parameters requires a game directory."
        if [[ ${CLI_GENERATE_VKBASALT_SET:-0} -eq 1 ||
            ${CLI_LIST_SHADER_REPOS:-0} -eq 1 || ${CLI_JSON:-0} -eq 1 ||
            ${_BATCH_UPDATE:-0} -eq 1 || ${CLI_GAME_PATH_SET:-0} -eq 1 ||
            ${CLI_APP_ID_SET:-0} -eq 1 || ${CLI_DLL_OVERRIDE_SET:-0} -eq 1 ||
            ${CLI_SHADER_REPOS_SET:-0} -eq 1 ]]; then
            printErr "--inspect-reshade-parameters cannot be combined with install, update, or other inspection options."
        fi
    fi

    if [[ ${CLI_GENERATE_VKBASALT_SET:-0} -eq 1 ]]; then
        CLI_GENERATE_VKBASALT_PATH=$(_trim_cli_value "$CLI_GENERATE_VKBASALT_PATH")
        [[ -n $CLI_GENERATE_VKBASALT_PATH ]] || printErr "--generate-vkbasalt-config requires a game directory."
        if [[ ${CLI_LIST_SHADER_REPOS:-0} -eq 1 || ${CLI_JSON:-0} -eq 1 ||
            ${_BATCH_UPDATE:-0} -eq 1 || ${CLI_GAME_PATH_SET:-0} -eq 1 ||
            ${CLI_APP_ID_SET:-0} -eq 1 || ${CLI_DLL_OVERRIDE_SET:-0} -eq 1 ||
            ${CLI_SHADER_REPOS_SET:-0} -eq 1 ]]; then
            printErr "--generate-vkbasalt-config cannot be combined with install, update, or shader-list options."
        fi
    fi

    if [[ ${CLI_JSON:-0} -eq 1 && ${CLI_LIST_SHADER_REPOS:-0} -ne 1 ]]; then
        printErr "--json requires --list-shader-repos."
    fi

    if [[ ${CLI_FORCE_CLI_SET:-0} -eq 1 && ${CLI_UI_BACKEND_SET:-0} -eq 1 ]]; then
        printErr "Use either --cli or --ui-backend=<backend>, not both."
    fi

    if [[ $_BATCH_UPDATE -eq 1 ]]; then
        if [[ ${CLI_GAME_PATH_SET:-0} -eq 1 || ${CLI_APP_ID_SET:-0} -eq 1 || ${CLI_DLL_OVERRIDE_SET:-0} -eq 1 ]]; then
            printErr "--update-all cannot be combined with --game-path, --app-id, or --dll-override. Use --shader-repos if you need to override shader selection for every tracked game."
        fi
    fi

    if [[ ${CLI_GAME_PATH_SET:-0} -eq 1 ]]; then
        CLI_GAME_PATH="$(_trim_cli_value "$CLI_GAME_PATH")"
    fi

    if [[ ${CLI_APP_ID_SET:-0} -eq 1 ]]; then
        CLI_APP_ID="$(_trim_cli_value "$CLI_APP_ID")"
        [[ $CLI_APP_ID =~ ^[0-9]+$ ]] || printErr "The App ID supplied via --app-id must be numeric."
    fi

    if [[ ${CLI_DLL_OVERRIDE_SET:-0} -eq 1 ]]; then
        CLI_DLL_OVERRIDE="$(_trim_cli_value "$CLI_DLL_OVERRIDE")"
        CLI_DLL_OVERRIDE="${CLI_DLL_OVERRIDE,,}"
        CLI_DLL_OVERRIDE="${CLI_DLL_OVERRIDE%.dll}"
        isKnownDllOverride "$CLI_DLL_OVERRIDE" || printErr "Unknown DLL override '$CLI_DLL_OVERRIDE'. Expected one of: $COMMON_OVERRIDES"
    fi

    if [[ ${CLI_SHADER_REPOS_SET:-0} -eq 1 ]]; then
        CLI_SHADER_REPOS=$(normalizeRequestedShaderRepos "$CLI_SHADER_REPOS") || printErr "Invalid value supplied via --shader-repos. Use all, none, or a comma-separated list of configured repo names."
    fi
}
