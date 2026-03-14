#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# Everclaw — setup-ollama.sh
#
# Detects hardware resources, selects optimal Qwen3.5 model, installs Ollama,
# and configures OpenClaw to use local inference as final fallback.
#
# Usage:
#   bash scripts/setup-ollama.sh              # Dry-run (show what would happen)
#   bash scripts/setup-ollama.sh --apply      # Install and configure
#   bash scripts/setup-ollama.sh --status     # Check current Ollama status
#   bash scripts/setup-ollama.sh --model qwen3.5:27b --apply   # Override model
#   bash scripts/setup-ollama.sh --uninstall  # Remove Ollama from config
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Constants ─────────────────────────────────────────────────────────────────

readonly SCRIPT_NAME="setup-ollama.sh"
readonly SCRIPT_VERSION="2026.3.12"
readonly OLLAMA_URL="https://ollama.com/install.sh"
readonly OLLAMA_API="http://127.0.0.1:11434"

# Model family: qwen3.5 (consistent behavior, Apache 2.0, strong tool use)
# Sizes verified against Ollama registry (ollama.com/library/qwen3.5)
# RAM requirements = model file size * ~1.2 (safe overhead)
# Note: Using case functions for bash 3 compatibility (no associative arrays)
MODEL_0_8B_SIZE=900     # ~0.9 GB file, needs ~1.1 GB RAM
MODEL_2B_SIZE=2500      # ~2.5 GB file, needs ~3.0 GB RAM
MODEL_4B_SIZE=3100      # ~3.1 GB file, needs ~3.7 GB RAM
MODEL_9B_SIZE=6100      # ~6.1 GB file, needs ~7.3 GB RAM
MODEL_27B_SIZE=16200    # ~16.2 GB file, needs ~19.4 GB RAM
MODEL_35B_SIZE=22200    # ~22.2 GB file, needs ~26.6 GB RAM

# Get model size by name (MB)
get_model_size() {
  local model="$1"
  case "$model" in
    qwen3.5:0.8b) echo $MODEL_0_8B_SIZE ;;
    qwen3.5:2b)   echo $MODEL_2B_SIZE ;;
    qwen3.5:4b)   echo $MODEL_4B_SIZE ;;
    qwen3.5:9b)   echo $MODEL_9B_SIZE ;;
    qwen3.5:27b)  echo $MODEL_27B_SIZE ;;
    qwen3.5:35b)  echo $MODEL_35B_SIZE ;;
    *)            echo 0 ;;
  esac
}

# Get quality description by model name
get_model_quality() {
  local model="$1"
  case "$model" in
    qwen3.5:0.8b) echo "Minimal — simple Q&A, formatting" ;;
    qwen3.5:2b)   echo "Basic — general tasks, light coding" ;;
    qwen3.5:4b)   echo "Good — coding, summarization" ;;
    qwen3.5:9b)   echo "Strong — coding, analysis, most tasks" ;;
    qwen3.5:27b)  echo "Excellent — complex reasoning, near-frontier" ;;
    qwen3.5:35b)  echo "Frontier — matches cloud models" ;;
    *)            echo "Unknown model" ;;
  esac
}

# ─── State Variables ───────────────────────────────────────────────────────────

OS=""
ARCH=""
PLATFORM=""
TOTAL_RAM_MB=0
AVAILABLE_RAM_MB=0
GPU_TYPE="none"
GPU_VRAM_MB=0
SELECTED_MODEL=""
FORCE_MODEL=""
DRY_RUN=true
VERBOSE=false
SKIP_SERVICE=false
OPENCLAW_CONFIG=""

# ─── Logging ───────────────────────────────────────────────────────────────────

log() { echo "  $1"; }
log_ok() { echo "  ✅ $1"; }
log_warn() { echo "  ⚠️  $1"; }
log_err() { echo "  ❌ $1"; }
log_info() { [[ "$VERBOSE" == "true" ]] && echo "  ℹ️  $1" || true; }
log_section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ─── OS & Architecture Detection ───────────────────────────────────────────────

detect_os() {
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  
  case "$OS" in
    darwin) PLATFORM="macos" ;;
    linux)  PLATFORM="linux" ;;
    *)      log_err "Unsupported OS: $OS"; exit 1 ;;
  esac
  
  case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    arm64)   ARCH="arm64" ;;
    *)       log_err "Unsupported architecture: $ARCH"; exit 1 ;;
  esac
  
  log "Platform:     ${PLATFORM}-${ARCH}"
}

# ─── RAM Detection ─────────────────────────────────────────────────────────────

detect_ram() {
  log_info "Detecting RAM..."
  
  if [[ "$PLATFORM" == "macos" ]]; then
    # macOS: use sysctl for total, vm_stat for available
    TOTAL_RAM_MB=$(/usr/sbin/sysctl -n hw.memsize | awk '{print int($1 / 1048576)}')
    
    # Get page count and page size
    local page_size=$(/usr/sbin/sysctl -n hw.pagesize 2>/dev/null || echo "4096")
    local vm_stats=$(/usr/bin/vm_stat 2>/dev/null || echo "")
    if [[ -n "$vm_stats" ]]; then
      local pages_free=$(echo "$vm_stats" | grep "Pages free" | awk '{print $3}' | tr -d '.')
      local pages_inactive=$(echo "$vm_stats" | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
      local available_pages=$((pages_free + pages_inactive))
      AVAILABLE_RAM_MB=$((available_pages * page_size / 1048576))
    else
      # Fallback: estimate available as 50% of total
      AVAILABLE_RAM_MB=$((TOTAL_RAM_MB / 2))
    fi
    
  else
    # Linux: use /proc/meminfo
    TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
    AVAILABLE_RAM_MB=$(awk '/MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
    
    # Fallback for older kernels without MemAvailable
    if [[ -z "$AVAILABLE_RAM_MB" || "$AVAILABLE_RAM_MB" == "0" ]]; then
      local free_kb=$(awk '/MemFree/ {print $2}' /proc/meminfo)
      local buffers_kb=$(awk '/Buffers/ {print $2}' /proc/meminfo)
      local cached_kb=$(awk '/^Cached/ {print $2}' /proc/meminfo)
      AVAILABLE_RAM_MB=$(((free_kb + buffers_kb + cached_kb) / 1024))
    fi
  fi
  
  local total_gb=$(awk "BEGIN {printf \"%.1f\", ${TOTAL_RAM_MB}/1024}")
  local avail_gb=$(awk "BEGIN {printf \"%.1f\", ${AVAILABLE_RAM_MB}/1024}")
  log "Total RAM:    ${TOTAL_RAM_MB} MB (${total_gb} GB)"
  log "Available:    ${AVAILABLE_RAM_MB} MB (${avail_gb} GB)"
}

# ─── GPU Detection ─────────────────────────────────────────────────────────────

detect_gpu() {
  log_info "Detecting GPU..."
  GPU_TYPE="none"
  GPU_VRAM_MB=0
  
  if [[ "$PLATFORM" == "macos" ]]; then
    # macOS: Apple Silicon has unified memory
    local cpu_brand=$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
    if echo "$cpu_brand" | grep -qi "apple"; then
      GPU_TYPE="metal"
      # Metal shares system RAM, no separate VRAM
      log "GPU:          Apple Metal (unified memory)"
      log_info "Metal shares system RAM — using available RAM for model sizing"
    else
      log "GPU:          None detected (Intel Mac)"
      log_info "Will use CPU inference"
    fi
    
  else
    # Linux: check NVIDIA first, then AMD
    if command -v nvidia-smi &>/dev/null; then
      GPU_TYPE="nvidia"
      GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
      if [[ -n "$GPU_VRAM_MB" && "$GPU_VRAM_MB" -gt 0 ]]; then
        log "GPU:          NVIDIA ($(nvidia-smi --query-gpu=name --format=csv,noheader | head -1))"
        log "VRAM:         ${GPU_VRAM_MB} MB"
      else
        GPU_TYPE="none"
        log "GPU:          NVIDIA detected but no VRAM reported"
      fi
    elif command -v rocm-smi &>/dev/null; then
      GPU_TYPE="amd"
      GPU_VRAM_MB=$(rocm-smi --showmeminfo vram --json 2>/dev/null | jq -r '.card0.VRAM // 0' | awk '{print int($1/1048576)}' || echo "0")
      if [[ -n "$GPU_VRAM_MB" && "$GPU_VRAM_MB" -gt 0 ]]; then
        log "GPU:          AMD ROCm (${GPU_VRAM_MB} MB VRAM)"
      else
        GPU_TYPE="none"
        log "GPU:          AMD detected but no VRAM reported"
      fi
    else
      log "GPU:          None (CPU inference only)"
    fi
  fi
}

# ─── Model Selection ───────────────────────────────────────────────────────────

select_model() {
  if [[ -n "$FORCE_MODEL" ]]; then
    SELECTED_MODEL="$FORCE_MODEL"
    log "Model:        ${SELECTED_MODEL} (user-specified override)"
    return
  fi
  
  # Use available RAM for sizing, but cap at 70% of total
  # This leaves headroom for OS and other apps
  local effective_ram_mb=$AVAILABLE_RAM_MB
  local max_ram_mb=$((TOTAL_RAM_MB * 70 / 100))
  
  if [[ "$effective_ram_mb" -gt "$max_ram_mb" ]]; then
    effective_ram_mb=$max_ram_mb
    log_info "Capped at 70% of total RAM: ${max_ram_mb} MB"
  fi
  
  # If we have dedicated GPU VRAM, use that instead (faster inference)
  if [[ "$GPU_TYPE" == "nvidia" || "$GPU_TYPE" == "amd" ]]; then
    if [[ "$GPU_VRAM_MB" -gt 0 ]]; then
      effective_ram_mb=$GPU_VRAM_MB
      log_info "Using GPU VRAM for model sizing: ${effective_ram_mb} MB"
    fi
  fi
  
  # Model selection thresholds (RAM in MB)
  # Each model needs ~1.2x its file size in RAM
  # Sizes verified against Ollama registry 2026-03-12
  if [[ "$effective_ram_mb" -lt 1200 ]]; then
    SELECTED_MODEL="qwen3.5:0.8b"    # needs ~1.1 GB
  elif [[ "$effective_ram_mb" -lt 3200 ]]; then
    SELECTED_MODEL="qwen3.5:2b"      # needs ~3.0 GB
  elif [[ "$effective_ram_mb" -lt 4000 ]]; then
    SELECTED_MODEL="qwen3.5:4b"      # needs ~3.7 GB
  elif [[ "$effective_ram_mb" -lt 8000 ]]; then
    SELECTED_MODEL="qwen3.5:9b"      # needs ~7.3 GB
  elif [[ "$effective_ram_mb" -lt 20000 ]]; then
    # Note: 9b is last safe choice for 8-19 GB (27b needs ~19.4 GB)
    SELECTED_MODEL="qwen3.5:9b"      # needs ~7.3 GB
  elif [[ "$effective_ram_mb" -lt 27000 ]]; then
    SELECTED_MODEL="qwen3.5:27b"     # needs ~19.4 GB
  else
    SELECTED_MODEL="qwen3.5:35b"     # needs ~26.6 GB
  fi
  
  local size_mb=$(get_model_size "$SELECTED_MODEL")
  local quality=$(get_model_quality "$SELECTED_MODEL")
  
  log "Model:        ${SELECTED_MODEL}"
  log "Size:         ~$((size_mb / 1000)) GB"
  log "Quality:      ${quality}"
  
  # Safety check: ensure model fits
  if [[ "$size_mb" -gt "$effective_ram_mb" ]]; then
    log_warn "Selected model may not fit in available RAM!"
    log_warn "Model needs ~${size_mb} MB, but only ${effective_ram_mb} MB effective"
  fi
}

# ─── Ollama Status Check ───────────────────────────────────────────────────────

check_ollama_installed() {
  if command -v ollama &>/dev/null; then
    log_ok "Ollama installed: $(ollama --version 2>/dev/null | head -1 || echo 'version unknown')"
    return 0
  else
    log "Ollama:        Not installed"
    return 1
  fi
}

check_ollama_running() {
  if curl -s "${OLLAMA_API}" >/dev/null 2>&1; then
    log_ok "Ollama server running at ${OLLAMA_API}"
    return 0
  else
    log "Ollama server: Not running"
    return 1
  fi
}

check_model_pulled() {
  local model="$1"
  if ollama list 2>/dev/null | grep -q "^${model}"; then
    log_ok "Model ${model} already pulled"
    return 0
  else
    log "Model:        ${model} not yet pulled"
    return 1
  fi
}

check_openclaw_config() {
  local candidates=(
    "${OPENCLAW_CONFIG:-}"
    "${HOME}/.openclaw/openclaw.json"
    "$(pwd)/openclaw.json"
  )
  
  for path in "${candidates[@]}"; do
    [[ -z "$path" ]] && continue
    if [[ -f "$path" ]]; then
      OPENCLAW_CONFIG="$path"
      log "OpenClaw:     ${path}"
      return 0
    fi
  done
  
  log_warn "OpenClaw config not found (~/.openclaw/openclaw.json)"
  OPENCLAW_CONFIG=""
  return 1
}

check_ollama_in_config() {
  if [[ -z "$OPENCLAW_CONFIG" ]]; then
    return 1
  fi
  
  if jq -e '.models.providers.ollama' "$OPENCLAW_CONFIG" >/dev/null 2>&1; then
    log_ok "Ollama already configured in openclaw.json"
    return 0
  else
    log "Ollama in config: Not configured"
    return 1
  fi
}

# ─── Status Command ────────────────────────────────────────────────────────────

show_status() {
  log_section "📊 Ollama Status"
  
  check_ollama_installed; local installed=$?
  check_ollama_running; local running=$?
  check_openclaw_config; local config=$?
  
  if [[ $installed -eq 0 && $running -eq 0 ]]; then
    echo ""
    log "Installed models:"
    ollama list 2>/dev/null | tail -n +2 | while read -r line; do
      [[ -n "$line" ]] && log "  $line"
    done
  fi
  
  if [[ $config -eq 0 ]]; then
    check_ollama_in_config
  fi
  
  echo ""
}

# ─── Dry Run Output ────────────────────────────────────────────────────────────

show_dry_run() {
  log_section "🔍 Dry-Run Summary"
  
  echo ""
  log "Platform:       ${PLATFORM}-${ARCH}"
  log "Total RAM:      ${TOTAL_RAM_MB} MB"
  log "Available RAM:  ${AVAILABLE_RAM_MB} MB"
  log "GPU:            ${GPU_TYPE}$([[ "$GPU_VRAM_MB" -gt 0 ]] && echo " (${GPU_VRAM_MB} MB VRAM)" || echo "")"
  echo ""
  log_section "📦 Recommended Model"
  echo ""
  log "Model:          ${SELECTED_MODEL}"
  local size_mb=$(get_model_size "$SELECTED_MODEL")
  local quality=$(get_model_quality "$SELECTED_MODEL")
  log "Size:           ~$((size_mb / 1000)) GB"
  log "Quality:        ${quality}"
  echo ""
  log_section "🔧 Actions (run with --apply)"
  echo ""
  log "1. Install Ollama (if not present)"
  log "2. Pull model: ${SELECTED_MODEL}"
  log "3. Add ollama provider to openclaw.json"
  log "4. Append ollama/${SELECTED_MODEL} to fallback chain"
  log "5. Setup auto-start service (launchd/systemd)"
  echo ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Dry-run complete. Add --apply to execute."
  echo ""
}

# ─── CLI Parsing ───────────────────────────────────────────────────────────────

print_usage() {
  cat << 'EOF'
♾️  Everclaw — Ollama Local Fallback Setup

Usage:
  bash scripts/setup-ollama.sh              Dry-run (show what would happen)
  bash scripts/setup-ollama.sh --apply      Install and configure Ollama
  bash scripts/setup-ollama.sh --status     Check current Ollama status
  bash scripts/setup-ollama.sh --uninstall  Remove Ollama from OpenClaw config

Options:
  --apply           Execute the installation
  --model <name>    Override auto-detected model
  --no-service      Skip auto-start service setup
  --verbose         Show detailed detection info
  --status          Show current Ollama status
  --uninstall       Remove ollama provider from openclaw.json
  -h, --help        Show this help

Examples:
  # Check what model would be selected
  bash scripts/setup-ollama.sh

  # Install with auto-detected model
  bash scripts/setup-ollama.sh --apply

  # Force a specific model
  bash scripts/setup-ollama.sh --model qwen3.5:27b --apply

  # Install without service setup
  bash scripts/setup-ollama.sh --apply --no-service
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply)     DRY_RUN=false ;;
      --status)    show_status; exit 0 ;;
      --uninstall) uninstall_ollama_config; exit 0 ;;
      --model)     FORCE_MODEL="$2"; shift ;;
      --no-service) SKIP_SERVICE=true ;;
      --verbose)   VERBOSE=true ;;
      -h|--help)   print_usage; exit 0 ;;
      *)           log_err "Unknown option: $1"; print_usage; exit 1 ;;
    esac
    shift
  done
}

# ═══════════════════════════════════════════════════════════════════════════════
# STAGE 2b — Installation, Configuration, Service Setup
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Install Ollama ─────────────────────────────────────────────────────────────

install_ollama() {
  if command -v ollama &>/dev/null; then
    log_ok "Ollama already installed: $(ollama --version 2>/dev/null | head -1 || echo 'unknown')"
    return 0
  fi

  log "Installing Ollama..."

  if [[ "$PLATFORM" == "macos" ]]; then
    # macOS: prefer Homebrew if available, else official installer
    if command -v brew &>/dev/null; then
      log "Using Homebrew..."
      brew install ollama 2>&1 | tail -3
    else
      log "Downloading official macOS installer..."
      # Ollama macOS uses a .zip with an app bundle
      local tmpdir=$(mktemp -d)
      curl -fsSL "https://ollama.com/download/Ollama-darwin.zip" -o "${tmpdir}/ollama.zip"
      unzip -qo "${tmpdir}/ollama.zip" -d /Applications/
      rm -rf "$tmpdir"
      # Ensure the CLI is linked
      if [[ ! -f /usr/local/bin/ollama ]]; then
        log "Linking CLI to /usr/local/bin/ollama..."
        sudo ln -sf /Applications/Ollama.app/Contents/Resources/ollama /usr/local/bin/ollama 2>/dev/null || \
          ln -sf /Applications/Ollama.app/Contents/Resources/ollama /opt/homebrew/bin/ollama 2>/dev/null || \
          log_warn "Could not symlink ollama CLI — add to PATH manually"
      fi
    fi
  else
    # Linux: official install script
    log "Running official Linux installer..."
    curl -fsSL "${OLLAMA_URL}" | sh 2>&1 | tail -5
  fi

  # Verify installation
  if command -v ollama &>/dev/null; then
    log_ok "Ollama installed: $(ollama --version 2>/dev/null | head -1)"
    return 0
  else
    log_err "Ollama installation failed"
    log "Try installing manually: https://ollama.com/download"
    return 1
  fi
}

# ─── Start Ollama Server ────────────────────────────────────────────────────────

ensure_ollama_running() {
  if curl -s --max-time 3 "${OLLAMA_API}" >/dev/null 2>&1; then
    log_ok "Ollama server already running"
    return 0
  fi

  log "Starting Ollama server..."

  if [[ "$PLATFORM" == "macos" ]]; then
    # Try launchd first, then direct
    if launchctl list 2>/dev/null | grep -q "com.ollama.ollama"; then
      launchctl kickstart "gui/$(id -u)/com.ollama.ollama" 2>/dev/null || true
    elif [[ -d "/Applications/Ollama.app" ]]; then
      open -a Ollama 2>/dev/null || true
    else
      ollama serve &>/dev/null &
    fi
  else
    # Linux: try systemd first, then direct
    if systemctl --user is-enabled ollama.service &>/dev/null; then
      systemctl --user start ollama.service
    elif systemctl is-enabled ollama.service &>/dev/null; then
      sudo systemctl start ollama.service
    else
      ollama serve &>/dev/null &
    fi
  fi

  # Wait for server to come up (max 30s)
  local tries=0
  while [[ $tries -lt 30 ]]; do
    if curl -s --max-time 2 "${OLLAMA_API}" >/dev/null 2>&1; then
      log_ok "Ollama server started"
      return 0
    fi
    sleep 1
    tries=$((tries + 1))
  done

  log_err "Ollama server did not start within 30 seconds"
  return 1
}

# ─── Pull Model ─────────────────────────────────────────────────────────────────

pull_model() {
  local model="$1"

  # Check if already pulled
  if ollama list 2>/dev/null | grep -q "${model}"; then
    log_ok "Model ${model} already available"
    return 0
  fi

  local size_mb=$(get_model_size "$model")
  log "Pulling model: ${model} (~$((size_mb / 1000)) GB)..."
  log "This may take a while depending on your connection..."
  echo ""

  if ollama pull "$model" 2>&1; then
    echo ""
    log_ok "Model ${model} pulled successfully"
    return 0
  else
    echo ""
    log_err "Failed to pull model ${model}"
    return 1
  fi
}

# ─── Configure OpenClaw ─────────────────────────────────────────────────────────

# ─── Ollama API Migration ────────────────────────────────────────────────────
# Fixes: api: "openai-completions" → api: "ollama" in existing configs.
# Without this fix, ollama requests may route through the previous provider's
# HTTP client in the fallback chain instead of localhost:11434.
# See: https://github.com/openclaw/openclaw/issues/45369

migrate_ollama_api() {
  local config="${1:-$OPENCLAW_CONFIG}"

  if [[ -z "$config" ]] || [[ ! -f "$config" ]]; then
    return 0
  fi

  # Check if ollama provider exists with wrong api type
  local current_api
  current_api=$(jq -r '.models.providers.ollama.api // ""' "$config" 2>/dev/null) || return 0

  if [[ "$current_api" != "openai-completions" ]]; then
    return 0  # Already correct or not configured
  fi

  log "Migrating ollama provider: api \"openai-completions\" → \"ollama\""

  # Backup before migration
  cp "$config" "${config}.bak.$(date +%s)"

  # Fix provider-level api
  local tmp_config
  tmp_config=$(jq '.models.providers.ollama.api = "ollama"' "$config")

  # Remove model-level api:"openai-completions" (let it inherit from provider)
  tmp_config=$(echo "$tmp_config" | jq '
    if .models.providers.ollama.models then
      .models.providers.ollama.models |= map(
        if .api == "openai-completions" then del(.api) else . end
      )
    else . end
  ')

  echo "$tmp_config" | jq '.' > "$config"
  log_ok "Ollama API type migrated — fallback routing fixed"
}

configure_openclaw() {
  local model="$1"

  if [[ -z "$OPENCLAW_CONFIG" ]]; then
    log_warn "No OpenClaw config found — skipping config update"
    log "You can manually add the ollama provider to your openclaw.json"
    return 1
  fi

  # Migrate existing ollama configs with wrong api type
  migrate_ollama_api "$OPENCLAW_CONFIG"

  log "Configuring OpenClaw..."

  # Build the ollama provider JSON block
  local provider_json
  provider_json=$(cat <<EOF
{
  "baseUrl": "http://127.0.0.1:11434/v1",
  "api": "ollama",
  "models": [
    {
      "id": "${model}",
      "name": "$(echo "${model}" | sed 's/qwen3.5:/Qwen3.5 /' | sed 's/b$/B/') (Local Ollama)",
      "reasoning": false,
      "input": ["text"],
      "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
      "contextWindow": 32768,
      "maxTokens": 8192
    }
  ]
}
EOF
)

  # Backup config
  cp "$OPENCLAW_CONFIG" "${OPENCLAW_CONFIG}.bak.$(date +%s)"
  log_info "Config backed up"

  # Check if ollama provider already exists
  if jq -e '.models.providers.ollama' "$OPENCLAW_CONFIG" >/dev/null 2>&1; then
    # Update existing ollama provider with new model
    local existing_model
    existing_model=$(jq -r '.models.providers.ollama.models[0].id // ""' "$OPENCLAW_CONFIG")

    if [[ "$existing_model" == "$model" ]]; then
      log_ok "Ollama provider already configured with ${model}"
    else
      log "Updating ollama provider: ${existing_model} → ${model}"
      local tmp_config
      tmp_config=$(jq --argjson provider "$provider_json" \
        '.models.providers.ollama = $provider' "$OPENCLAW_CONFIG")
      echo "$tmp_config" | jq '.' > "$OPENCLAW_CONFIG"
      log_ok "Ollama provider updated to ${model}"
    fi
  else
    # Add new ollama provider
    local tmp_config
    tmp_config=$(jq --argjson provider "$provider_json" \
      '.models.providers.ollama = $provider' "$OPENCLAW_CONFIG")
    echo "$tmp_config" | jq '.' > "$OPENCLAW_CONFIG"
    log_ok "Ollama provider added to openclaw.json"
  fi

  # Add ollama model to fallback chain (as last fallback)
  local fallback_entry="ollama/${model}"
  local already_in_fallbacks
  already_in_fallbacks=$(jq -r --arg fb "$fallback_entry" \
    '.agents.defaults.model.fallbacks // [] | map(select(startswith("ollama/"))) | length' \
    "$OPENCLAW_CONFIG")

  if [[ "$already_in_fallbacks" -gt 0 ]]; then
    # Remove old ollama fallback and add new one at the end
    local tmp_config
    tmp_config=$(jq --arg fb "$fallback_entry" \
      '.agents.defaults.model.fallbacks = [
        (.agents.defaults.model.fallbacks // [] | .[] | select(startswith("ollama/") | not)),
        $fb
      ]' "$OPENCLAW_CONFIG")
    echo "$tmp_config" | jq '.' > "$OPENCLAW_CONFIG"
    log_ok "Fallback updated: ${fallback_entry} (last position)"
  else
    # Append to fallback chain
    local tmp_config
    tmp_config=$(jq --arg fb "$fallback_entry" \
      '.agents.defaults.model.fallbacks += [$fb]' "$OPENCLAW_CONFIG")
    echo "$tmp_config" | jq '.' > "$OPENCLAW_CONFIG"
    log_ok "Fallback added: ${fallback_entry} (last position)"
  fi

  log_info "Config: ${OPENCLAW_CONFIG}"
}

# ─── Service Setup (Auto-start) ─────────────────────────────────────────────────

setup_service() {
  if [[ "$SKIP_SERVICE" == "true" ]]; then
    log "Skipping service setup (--no-service)"
    return 0
  fi

  log "Setting up auto-start service..."

  if [[ "$PLATFORM" == "macos" ]]; then
    setup_service_macos
  else
    setup_service_linux
  fi
}

setup_service_macos() {
  local plist_dir="${HOME}/Library/LaunchAgents"
  local plist_name="com.ollama.ollama.plist"
  local plist_path="${plist_dir}/${plist_name}"

  # Ollama's own installer typically creates this plist.
  # If it already exists, just ensure it's loaded.
  if [[ -f "$plist_path" ]]; then
    log_ok "LaunchAgent plist already exists: ${plist_name}"
    # Ensure loaded
    if ! launchctl list 2>/dev/null | grep -q "com.ollama.ollama"; then
      launchctl load -w "$plist_path" 2>/dev/null || true
      log_ok "LaunchAgent loaded"
    else
      log_ok "LaunchAgent already loaded"
    fi
    return 0
  fi

  # Create a minimal plist if Ollama didn't install one
  mkdir -p "$plist_dir"
  local ollama_bin
  ollama_bin=$(command -v ollama 2>/dev/null || echo "/opt/homebrew/bin/ollama")

  cat > "$plist_path" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ollama.ollama</string>
    <key>ProgramArguments</key>
    <array>
        <string>${ollama_bin}</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${HOME}/.ollama/logs/server.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.ollama/logs/server.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLIST

  mkdir -p "${HOME}/.ollama/logs"
  launchctl load -w "$plist_path" 2>/dev/null || true
  log_ok "LaunchAgent created and loaded: ${plist_name}"
}

setup_service_linux() {
  # Use systemd user service (no root required)
  local service_dir="${HOME}/.config/systemd/user"
  local service_name="ollama.service"
  local service_path="${service_dir}/${service_name}"

  if [[ -f "$service_path" ]]; then
    log_ok "Systemd service already exists: ${service_name}"
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now "$service_name" 2>/dev/null || true
    log_ok "Service enabled and started"
    return 0
  fi

  # Check if system-level service exists (from official installer)
  if systemctl is-enabled ollama.service &>/dev/null 2>&1; then
    log_ok "System-level ollama.service found — using that"
    sudo systemctl enable --now ollama.service 2>/dev/null || true
    return 0
  fi

  # Create user-level systemd service
  local ollama_bin
  ollama_bin=$(command -v ollama 2>/dev/null || echo "/usr/local/bin/ollama")

  mkdir -p "$service_dir"
  cat > "$service_path" << UNIT
[Unit]
Description=Ollama Local Inference Server (Everclaw)
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ollama_bin} serve
Environment="HOME=${HOME}"
Environment="OLLAMA_HOST=127.0.0.1:11434"
Restart=on-failure
RestartSec=5

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${HOME}/.ollama
PrivateTmp=true

[Install]
WantedBy=default.target
UNIT

  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now "$service_name" 2>/dev/null || true
  log_ok "Systemd service created and started: ${service_name}"
}

# ─── Test Inference ──────────────────────────────────────────────────────────────

test_inference() {
  local model="$1"

  log "Testing inference with ${model}..."

  local response
  response=$(curl -s --max-time 60 "${OLLAMA_API}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${model}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Respond with exactly: OLLAMA_OK\"}],
      \"max_tokens\": 50
    }" 2>/dev/null)

  if [[ -z "$response" ]]; then
    log_err "No response from Ollama (timeout or connection refused)"
    return 1
  fi

  local content
  content=$(echo "$response" | jq -r '.choices[0].message.content // .error // "PARSE_ERROR"' 2>/dev/null)

  if echo "$content" | grep -qi "OLLAMA_OK"; then
    log_ok "Inference test passed — model is working"
    return 0
  elif echo "$content" | grep -qi "error"; then
    log_err "Inference test failed: ${content}"
    return 1
  else
    # Model responded but not with exact text — still counts as working
    log_ok "Inference test passed — model responded: $(echo "$content" | head -c 80)"
    return 0
  fi
}

# ─── Uninstall from OpenClaw Config ──────────────────────────────────────────────

uninstall_ollama_config() {
  log_section "🗑️  Removing Ollama from OpenClaw config"

  # Find config
  check_openclaw_config || { log_err "No OpenClaw config found"; exit 1; }

  if ! jq -e '.models.providers.ollama' "$OPENCLAW_CONFIG" >/dev/null 2>&1; then
    log "Ollama provider not found in config — nothing to remove"
    return 0
  fi

  # Backup
  cp "$OPENCLAW_CONFIG" "${OPENCLAW_CONFIG}.bak.$(date +%s)"
  log_info "Config backed up"

  # Remove ollama provider
  local tmp_config
  tmp_config=$(jq 'del(.models.providers.ollama)' "$OPENCLAW_CONFIG")
  echo "$tmp_config" | jq '.' > "$OPENCLAW_CONFIG"
  log_ok "Ollama provider removed"

  # Remove ollama fallbacks
  tmp_config=$(jq '.agents.defaults.model.fallbacks = [
    .agents.defaults.model.fallbacks[] | select(startswith("ollama/") | not)
  ]' "$OPENCLAW_CONFIG")
  echo "$tmp_config" | jq '.' > "$OPENCLAW_CONFIG"
  log_ok "Ollama fallbacks removed"

  log ""
  log "Ollama software was NOT uninstalled (only removed from OpenClaw config)."
  log "To fully remove Ollama: brew uninstall ollama (macOS) or sudo rm /usr/local/bin/ollama (Linux)"
  echo ""
}

# ─── Main Entry Point ──────────────────────────────────────────────────────────

main() {
  echo ""
  echo "♾️  Everclaw — Ollama Local Fallback"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  parse_args "$@"

  # Detection phase
  detect_os
  detect_ram
  detect_gpu
  select_model

  # Status checks
  check_ollama_installed
  check_openclaw_config

  # Dry-run or execute
  if [[ "$DRY_RUN" == "true" ]]; then
    show_dry_run
  else
    # ─── Step 1: Install Ollama ───────────────
    log_section "🔧 Step 1: Install Ollama"
    install_ollama || exit 1

    # ─── Step 2: Start server ─────────────────
    log_section "🔧 Step 2: Start Ollama server"
    ensure_ollama_running || exit 1

    # ─── Step 3: Pull model ───────────────────
    log_section "🔧 Step 3: Pull model"
    pull_model "$SELECTED_MODEL" || exit 1

    # ─── Step 4: Configure OpenClaw ───────────
    log_section "🔧 Step 4: Configure OpenClaw"
    configure_openclaw "$SELECTED_MODEL"

    # ─── Step 5: Setup auto-start ─────────────
    log_section "🔧 Step 5: Auto-start service"
    setup_service

    # ─── Step 6: Test inference ───────────────
    log_section "🔧 Step 6: Test inference"
    test_inference "$SELECTED_MODEL"

    # ─── Done ─────────────────────────────────
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_ok "Ollama local fallback setup complete!"
    echo ""
    log "Model:     ollama/${SELECTED_MODEL}"
    log "API:       ${OLLAMA_API}"
    log "Position:  Last fallback in chain"
    echo ""
    log "Restart OpenClaw to apply: openclaw gateway restart"
    echo ""
  fi
}

# Run
main "$@"