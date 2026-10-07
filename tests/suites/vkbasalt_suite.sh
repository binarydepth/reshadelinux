#!/bin/bash
# shellcheck disable=SC2317,SC2329  # test functions are invoked indirectly

_create_vkbasalt_test_game() {
    local _game="$1"
    mkdir -p "$_game/ReShade_shaders/Merged/Shaders/effects" \
        "$_game/ReShade_shaders/Merged/Textures" "$_game/presets"
    touch "$_game/ReShade_shaders/Merged/Shaders/Sharpen.fx" \
        "$_game/ReShade_shaders/Merged/Shaders/effects/Clarity.fx"
    cat > "$_game/ReShade.ini" <<'EOF'
[GENERAL]
PresetPath=presets/current.ini
EOF
    cat > "$_game/presets/current.ini" <<'EOF'
[GENERAL]
Techniques=Sharpen@Sharpen.fx,Clarity@effects\Clarity.fx,AnotherSharpen@Sharpen.fx
EOF
}

_generate_vkbasalt_config_capturing_error() {
    local _game="$1" _output="$2"
    generateVkbasaltConfig "$_game" >"$_output" 2>&1
}

_inspect_reshade_parameters_capturing_error() {
    local _path="$1" _output="$2"
    inspectReshadeParameters "$_path" >"$_output" 2>&1
}

test_vkbasalt_config_uses_enabled_effect_files_and_paths() {
    local _game="$TEST_TEMP_DIR/vkbasalt-game" _output _shaders _textures
    _create_vkbasalt_test_game "$_game"
    _output=$(generateVkbasaltConfig "$_game")
    _shaders=$(realpath "$_game/ReShade_shaders/Merged/Shaders")
    _textures=$(realpath "$_game/ReShade_shaders/Merged/Textures")

    [[ $_output == "$_game/vkBasalt.conf" ]]
    grep -Fqx 'effects = reshade_effect_001:reshade_effect_002' "$_output"
    grep -Fqx "reshade_effect_001 = $_shaders/Sharpen.fx" "$_output"
    grep -Fqx "reshade_effect_002 = $_shaders/effects/Clarity.fx" "$_output"
    grep -Fqx "reshadeTexturePath = $_textures" "$_output"
    grep -Fqx "reshadeIncludePath = $_shaders" "$_output"
}

test_vkbasalt_config_refuses_to_overwrite_existing_config() {
    local _game="$TEST_TEMP_DIR/vkbasalt-existing" _output_file="$TEST_TEMP_DIR/vkbasalt-error.log"
    _create_vkbasalt_test_game "$_game"
    printf 'preserve this config\n' > "$_game/vkBasalt.conf"

    assert_fails _generate_vkbasalt_config_capturing_error "$_game" "$_output_file"
    grep -Fq "already exists and is not a ReShadeLinux-generated config" "$_output_file"
    grep -Fqx 'preserve this config' "$_game/vkBasalt.conf"
}

test_vkbasalt_config_updates_only_its_own_generated_config() {
    local _game="$TEST_TEMP_DIR/vkbasalt-update" _custom="$TEST_TEMP_DIR/custom.fx"
    _create_vkbasalt_test_game "$_game"
    generateVkbasaltConfig "$_game" >/dev/null
    printf '// selected replacement\n' > "$_custom"

    generateVkbasaltConfig "$_game" "$_custom" >/dev/null
    grep -Fqx "reshade_effect_001 = $_custom" "$_game/vkBasalt.conf"
    assert_fails grep -Fq 'reshade_effect_002 =' "$_game/vkBasalt.conf"
}

test_vkbasalt_config_requires_active_techniques() {
    local _game="$TEST_TEMP_DIR/vkbasalt-no-techniques" _output_file="$TEST_TEMP_DIR/vkbasalt-error.log"
    _create_vkbasalt_test_game "$_game"
    printf '[GENERAL]\nTechniques=\n' > "$_game/presets/current.ini"

    assert_fails _generate_vkbasalt_config_capturing_error "$_game" "$_output_file"
    grep -Fq "does not list enabled ReShade techniques" "$_output_file"
    [[ ! -e "$_game/vkBasalt.conf" ]]
}

test_vkbasalt_cli_generates_config_and_exits_before_install_flow() {
    local _game="$TEST_TEMP_DIR/vkbasalt-cli" _output
    _create_vkbasalt_test_game "$_game"

    _output=$( (
        parseCliArgs "--generate-vkbasalt-config=$_game"
        init_runtime_config
        validateCliArgs
        handleCliInfoArgs
    ) 2>&1 )

    [[ $_output == "$_game/vkBasalt.conf" ]]
    [[ -f $_game/vkBasalt.conf ]]
}

test_reshade_parameter_inspector_reports_presets_uniforms_and_defaults() {
    local _game="$TEST_TEMP_DIR/parameter-inspector" _output
    _create_vkbasalt_test_game "$_game"
    cat > "$_game/ReShade_shaders/Merged/Shaders/Sharpen.fx" <<'EOF'
uniform float Amount
<
    ui_label = "Strength";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
> = 0.75;
uniform float Unchanged = 1.25;
EOF
    cat > "$_game/presets/current.ini" <<'EOF'
[GENERAL]
Techniques=Sharpen@Sharpen.fx

[Sharpen.fx]
Amount=1.5
EOF

    _output=$(inspectReshadeParameters "$_game")
    [[ $_output == *"Technique: Sharpen"* ]]
    [[ $_output == *"Amount (float,"* ]]
    [[ $_output == *"Label: Strength"* ]]
    [[ $_output == *"UI: min=0.0, max=2.0"* ]]
    [[ $_output == *"Source default: 0.75"* ]]
    [[ $_output == *"Preset value: 1.5"* ]]
    [[ $_output == *"Unchanged (float,"* ]]
    [[ $_output == *"Preset value: <not saved; source default applies>"* ]]
    [[ $_output == *"vkBasalt may not expose or honor them"* ]]
    [[ ! -e "$_game/vkBasalt.conf" ]]
}

test_reshade_parameter_inspector_finds_custom_preset_without_presetpath() {
    local _game="$TEST_TEMP_DIR/custom-preset-game" _output
    _create_vkbasalt_test_game "$_game"
    cat > "$_game/ReShade.ini" <<'EOF'
[GENERAL]
EffectSearchPaths=.\ReShade_shaders\Merged\Shaders\**
EOF
    cat > "$_game/Diablo IV - Gameplay.ini" <<'EOF'
[GENERAL]
Techniques=Sharpen@Sharpen.fx

[Sharpen.fx]
Amount=1.25
EOF
    printf 'uniform float Amount = 0.5;\n' > "$_game/ReShade_shaders/Merged/Shaders/Sharpen.fx"

    _output=$(inspectReshadeParameters "$_game/ReShade.ini")
    [[ $_output == *"Preset: $_game/Diablo IV - Gameplay.ini"* ]]
    [[ $_output == *"Preset value: 1.25"* ]]
}

test_reshade_parameter_inspector_reports_multiple_candidate_presets() {
    local _game="$TEST_TEMP_DIR/ambiguous-preset-game" _output_file="$TEST_TEMP_DIR/ambiguous-preset-error.log"
    _create_vkbasalt_test_game "$_game"
    cat > "$_game/ReShade.ini" <<'EOF'
[GENERAL]
EffectSearchPaths=.\ReShade_shaders\Merged\Shaders\**
EOF
    printf '[GENERAL]\nTechniques=Sharpen@Sharpen.fx\n' > "$_game/Diablo IV A.ini"
    printf '[GENERAL]\nTechniques=Sharpen@Sharpen.fx\n' > "$_game/Diablo IV B.ini"

    assert_fails _inspect_reshade_parameters_capturing_error "$_game/ReShade.ini" "$_output_file"
    grep -Fq "Multiple preset candidates found" "$_output_file"
    grep -Fq "Diablo IV A.ini" "$_output_file"
    grep -Fq "Diablo IV B.ini" "$_output_file"
}

test_reshade_parameter_inspector_offers_installed_effects_without_preset() {
    local _game="$TEST_TEMP_DIR/no-preset-game" _output _shaders
    _create_vkbasalt_test_game "$_game"
    rm "$_game/presets/current.ini"
    mkdir -p "$_game/user-effects"
    printf '// Custom installed effect\n' > "$_game/user-effects/Custom.fx"
    printf '[GENERAL]\nEffectSearchPaths=.\\ReShade_shaders\\Merged\\Shaders\\**,.\\user-effects\\**\n' > "$_game/ReShade.ini"
    _shaders=$(realpath "$_game/ReShade_shaders/Merged/Shaders")
    _UI_BACKEND=yad
    ui_checklist() { printf '1 2 3\n'; }

    _output=$(inspectReshadeParameters "$_game/ReShade.ini")
    [[ $_output == "$_game/vkBasalt.conf" ]]
    grep -Fqx "reshade_effect_001 = $_shaders/Sharpen.fx" "$_game/vkBasalt.conf"
    grep -Fqx "reshade_effect_002 = $_shaders/effects/Clarity.fx" "$_game/vkBasalt.conf"
    grep -Fqx "reshade_effect_003 = $_game/user-effects/Custom.fx" "$_game/vkBasalt.conf"
    grep -Fqx "reshadeIncludePath = $_game" "$_game/vkBasalt.conf"
}

test_vkbasalt_export_offers_installed_effects_without_preset() {
    local _game="$TEST_TEMP_DIR/vkbasalt-no-preset" _output _shaders
    _create_vkbasalt_test_game "$_game"
    rm "$_game/presets/current.ini"
    printf '[GENERAL]\nEffectSearchPaths=.\\ReShade_shaders\\Merged\\Shaders\\**\n' > "$_game/ReShade.ini"
    _shaders=$(realpath "$_game/ReShade_shaders/Merged/Shaders")
    _UI_BACKEND=yad
    ui_checklist() { printf '1\n'; }

    _output=$(generateVkbasaltConfig "$_game")
    [[ $_output == "$_game/vkBasalt.conf" ]]
    grep -Fqx "reshade_effect_001 = $_shaders/Sharpen.fx" "$_game/vkBasalt.conf"
}

test_reshade_parameter_inspector_cancel_does_not_create_vkbasalt_config() {
    local _game="$TEST_TEMP_DIR/no-preset-cancel-game" _output_file="$TEST_TEMP_DIR/no-preset-cancel.log"
    _create_vkbasalt_test_game "$_game"
    rm "$_game/presets/current.ini"
    printf '[GENERAL]\nEffectSearchPaths=.\\ReShade_shaders\\Merged\\Shaders\\**\n' > "$_game/ReShade.ini"
    _UI_BACKEND=yad
    ui_checklist() { printf '\n'; }

    assert_fails _inspect_reshade_parameters_capturing_error "$_game" "$_output_file"
    grep -Fq "No effects selected" "$_output_file"
    [[ ! -e "$_game/vkBasalt.conf" ]]
}

test_reshade_parameter_inspector_cli_exits_without_install_flow() {
    local _game="$TEST_TEMP_DIR/parameter-inspector-cli" _output
    _create_vkbasalt_test_game "$_game"
    cat > "$_game/ReShade_shaders/Merged/Shaders/Sharpen.fx" <<'EOF'
uniform float Strength = 1.0;
EOF
    cat > "$_game/presets/current.ini" <<'EOF'
[GENERAL]
Techniques=Sharpen@Sharpen.fx
[Sharpen.fx]
Strength=1.75
EOF

    _output=$( (
        parseCliArgs "--inspect-reshade-parameters=$_game/ReShade.ini"
        init_runtime_config
        validateCliArgs
        handleCliInfoArgs
    ) 2>&1 )

    [[ $_output == *"Preset value: 1.75"* ]]
}

test_custom_local_shader_source_is_a_valid_explicit_selection() {
    export SHADER_REPOS="https://example.com/alpha|alpha"
    local _selected
    _selected=$(normalizeRequestedShaderRepos "gshade-local,alpha")
    [[ $_selected == "alpha,custom-local" ]]
}

test_custom_local_shader_source_is_merged_only_when_selected() {
    local _game="$TEST_TEMP_DIR/local-custom-game" _custom="$TEST_TEMP_DIR/downloaded-custom-pack"
    mkdir -p "$_custom/Shaders/Nested" "$_custom/Textures/LUTs"
    printf '// Custom effect\n' > "$_custom/Shaders/Nested/Custom.fx"
    printf '// Custom include\n' > "$_custom/Shaders/Nested/Custom.fxh"
    printf 'texture\n' > "$_custom/Textures/LUTs/Grade.png"
    CUSTOM_SHADER_PATH="$_custom"

    buildGameShaderDir "custom-selected" "custom-local"
    [[ -L "$MAIN_PATH/game-shaders/custom-selected/Merged/Shaders/Nested/Custom.fx" ]]
    [[ -L "$MAIN_PATH/game-shaders/custom-selected/Merged/Textures/LUTs/Grade.png" ]]
    [[ -L "$MAIN_PATH/game-shaders/custom-selected/Merged/Shaders/Custom.fxh" ]]

    buildGameShaderDir "custom-not-selected" ""
    [[ ! -e "$MAIN_PATH/game-shaders/custom-not-selected/Merged/Shaders/Nested/Custom.fx" ]]
}

test_custom_local_shader_directory_is_prompted_and_saved() {
    local _custom="$TEST_TEMP_DIR/manual-custom-pack"
    mkdir -p "$_custom/Shaders" "$_custom/Textures"
    _UI_BACKEND=yad
    CUSTOM_SHADER_PATH=""
    ui_directorybox() { printf '%s\n' "$_custom"; }

    ensureCustomShaderPath
    [[ $CUSTOM_SHADER_PATH == "$(realpath "$_custom")" ]]
    grep -Fqx "$CUSTOM_SHADER_PATH" "$MAIN_PATH/custom-shader-source-path"
}

test_custom_shader_selection_validates_and_prepares_source() {
    local _custom="$TEST_TEMP_DIR/selected-custom-pack"
    mkdir -p "$_custom/Shaders"
    export SHADER_REPOS=""
    CUSTOM_SHADER_PATH=""
    _UI_BACKEND=yad
    ui_directorybox() { printf '%s\n' "$_custom"; }

    ensureSelectedShaderRepos "custom-local"
    [[ $CUSTOM_SHADER_PATH == "$(realpath "$_custom")" ]]
    [[ -z $_failedRepos ]]
}

test_legacy_gshade_path_and_repo_selection_are_compatible() {
    local _custom="$TEST_TEMP_DIR/legacy-GShade"
    mkdir -p "$_custom/Shaders"
    printf '%s\n' "$_custom" > "$MAIN_PATH/gshade-source-path"
    CUSTOM_SHADER_PATH=""

    ensureCustomShaderPath
    [[ $CUSTOM_SHADER_PATH == "$(realpath "$_custom")" ]]
    grep -Fqx "$CUSTOM_SHADER_PATH" "$MAIN_PATH/custom-shader-source-path"
    repoIsSelected "gshade-local" "custom-local"
}

run_vkbasalt_tests() {
    echo -e "${BLUE}vkBasalt Export Tests${NC}"
    run_test "vkBasalt config uses enabled effects and merged paths" test_vkbasalt_config_uses_enabled_effect_files_and_paths
    run_test "vkBasalt export preserves an existing config" test_vkbasalt_config_refuses_to_overwrite_existing_config
    run_test "vkBasalt export updates only generated configs" test_vkbasalt_config_updates_only_its_own_generated_config
    run_test "vkBasalt export requires active techniques" test_vkbasalt_config_requires_active_techniques
    run_test "vkBasalt CLI export exits before install flow" test_vkbasalt_cli_generates_config_and_exits_before_install_flow
    run_test "ReShade inspector reports preset values, uniforms, and defaults" test_reshade_parameter_inspector_reports_presets_uniforms_and_defaults
    run_test "ReShade inspector detects a custom preset" test_reshade_parameter_inspector_finds_custom_preset_without_presetpath
    run_test "ReShade inspector reports ambiguous preset candidates" test_reshade_parameter_inspector_reports_multiple_candidate_presets
    run_test "ReShade inspector offers effects without a preset" test_reshade_parameter_inspector_offers_installed_effects_without_preset
    run_test "vkBasalt export offers effects without a preset" test_vkbasalt_export_offers_installed_effects_without_preset
    run_test "ReShade inspector cancellation leaves config unchanged" test_reshade_parameter_inspector_cancel_does_not_create_vkbasalt_config
    run_test "ReShade inspector CLI exits before install flow" test_reshade_parameter_inspector_cli_exits_without_install_flow
    run_test "custom local shader source can be explicitly selected" test_custom_local_shader_source_is_a_valid_explicit_selection
    run_test "custom local shader files merge only when selected" test_custom_local_shader_source_is_merged_only_when_selected
    run_test "custom shader directory is requested and saved" test_custom_local_shader_directory_is_prompted_and_saved
    run_test "custom shader selection validates and prepares its source" test_custom_shader_selection_validates_and_prepares_source
    run_test "legacy GShade path and selection remain compatible" test_legacy_gshade_path_and_repo_selection_are_compatible
    echo ""
}
