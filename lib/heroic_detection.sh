# shellcheck shell=bash
# SPDX-License-Identifier: GPL-2.0-or-later

# Read installed Windows-game records from Heroic's bundled store metadata.
function loadHeroicInstalledGames() {
    local _installed="$1" _store="$2"
    [[ -f $_installed ]] || return 0
    command -v python3 &>/dev/null || return 0
    local _errFile _status
    _errFile=$(mktemp) || _errFile=/dev/null
    python3 - "$_installed" "$_store" 2>"$_errFile" <<'PYEOF'
import json
import os
import sys

try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        records = json.load(stream)
except (OSError, ValueError) as error:
    print(f"Could not read Heroic installed-games metadata: {error}", file=sys.stderr)
    sys.exit(1)

store = sys.argv[2]
if store == 'sideload':
    records = records.get('games', []) if isinstance(records, dict) else []
    entries = enumerate(records) if isinstance(records, list) else []
elif isinstance(records, dict) and isinstance(records.get('installed'), list):
    records = records['installed']
    entries = enumerate(records)
elif isinstance(records, dict):
    entries = records.items()
elif isinstance(records, list):
    entries = enumerate(records)
else:
    sys.exit(0)

for key, game in entries:
    if not isinstance(game, dict):
        continue
    if store == 'sideload':
        install = game.get('install')
        executable = str(install.get('executable') or '') if isinstance(install, dict) else ''
        executable = os.path.expanduser(executable)
        if game.get('is_installed') is not True or game.get('runner') != 'sideload':
            continue
        if not executable or not executable.lower().endswith('.exe') or not os.path.isfile(executable):
            continue
        install_path = os.path.dirname(executable)
        app_name = str(game.get('app_name') or key)
        title = str(game.get('title') or app_name)
        fields = (store, app_name, title, install_path, executable)
        print('\t'.join(value.replace('\t', ' ').replace('\n', ' ') for value in fields))
        continue
    app_name = str(game.get('app_name') or game.get('appName') or key)
    title = str(game.get('title') or game.get('app_name') or game.get('appName') or app_name)
    install_path = os.path.expanduser(str(game.get('install_path') or ''))
    executable = str(game.get('executable') or '')
    if not app_name or not install_path:
        continue
    fields = (store, app_name, title, install_path, executable)
    print('\t'.join(value.replace('\t', ' ').replace('\n', ' ') for value in fields))
PYEOF
    _status=$?
    _logPythonErrors loadHeroicInstalledGames "$_errFile"
    return $_status
}

# Resolve the install folder/executable for one Heroic game record.
function _processHeroicInstalledGame() {
    local _store="$1" _appName="$2" _name="$3" _root="$4" _exePath="$5"
    local _bestIdxByPathName="$6" _bestIdxByAppIdName="$7"
    local _appId="heroic-${_store}-$_appName" _path _exe _resolved _icon=""

    [[ $_store == legendary || $_store == gog || $_store == sideload ]] || return
    [[ $_appName =~ ^[A-Za-z0-9._-]+$ && $_appName != "." && $_appName != ".." ]] || return
    [[ -d $_root ]] || return

    _path="$_root"
    _exe=""
    if [[ -n $_exePath ]]; then
        if [[ $_exePath == /* ]]; then
            _resolved=$_exePath
        else
            _resolved="$_root/$_exePath"
        fi
        if [[ -f $_resolved && ${_resolved,,} == *.exe ]]; then
            _path=$(dirname "$_resolved")
            _exe=$(basename "$_resolved")
        fi
    fi

    if [[ -z $_exe ]]; then
        _resolved=$(resolveGameInstallDir "$_root" "$_appId")
        _path=${_resolved%%|*}
        _exe=$(pickBestExeInDir "$_path")
    fi
    [[ -n $_exe ]] || return

    _path=$(realpath "$_path" 2>/dev/null || printf '%s' "$_path")
    _path=${_path%/}
    [[ -d $_path ]] || return
    [[ -n $_name ]] || _name=$_appName
    _upsertDetectedSteamGame "$_appId" "$_name" "$_path" "$_exe" "$_icon" heroic \
        "$_bestIdxByPathName" "$_bestIdxByAppIdName"
}

# Add installed Epic and GOG games from each native or Flatpak Heroic profile.
function detectHeroicGames() {
    local _pathMapName="$1" _appIdMapName="$2"
    local _heroicDir _installedFile _store _record _recordStore
    local _appName _name _root _exe

    while IFS= read -r _heroicDir; do
        for _store in legendary gog sideload; do
            if [[ $_store == legendary ]]; then
                _installedFile="$_heroicDir/legendaryConfig/legendary/installed.json"
            elif [[ $_store == gog ]]; then
                _installedFile="$_heroicDir/gog_store/installed.json"
            else
                _installedFile="$_heroicDir/sideload_apps/library.json"
            fi
            [[ -f $_installedFile ]] || continue
            while IFS= read -r _record; do
                IFS=$'\t' read -r _recordStore _appName _name _root _exe <<< "$_record"
                _processHeroicInstalledGame "$_recordStore" "$_appName" "$_name" "$_root" "$_exe" \
                    "$_pathMapName" "$_appIdMapName"
            done < <(loadHeroicInstalledGames "$_installedFile" "$_store")
        done
    done < <(listHeroicConfigDirs)
}

# Read a game's configured WINEPREFIX from Heroic's GamesConfig JSON.
function getHeroicWinePrefix() {
    local _gameConfig="$1"
    [[ -f $_gameConfig ]] || return 0
    command -v python3 &>/dev/null || return 0
    local _errFile _status
    _errFile=$(mktemp) || _errFile=/dev/null
    python3 - "$_gameConfig" 2>"$_errFile" <<'PYEOF'
import json
import sys

try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        config = json.load(stream)
except (OSError, ValueError) as error:
    print(f"Could not read Heroic game settings: {error}", file=sys.stderr)
    sys.exit(1)

if isinstance(config, dict):
    candidates = [config, *config.values()]
    for candidate in candidates:
        if isinstance(candidate, dict) and candidate.get('winePrefix'):
            print(candidate['winePrefix'])
            break
PYEOF
    _status=$?
    _logPythonErrors getHeroicWinePrefix "$_errFile"
    return $_status
}
