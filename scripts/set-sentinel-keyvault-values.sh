#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
values_file="${script_dir}/../kubernetes/keyvault-values.yaml"
key_vault_name=""
subscription_id=""
dry_run=false
allow_placeholders=false

usage() {
  cat <<'EOF'
Usage:
  ./scripts/set-sentinel-keyvault-values.sh [options]

Options:
  --values-file PATH         YAML file containing the secrets and config maps
  --key-vault-name NAME      Override azure.keyVaultName from the YAML file
  --subscription-id ID       Override azure.subscriptionId from the YAML file
  --dry-run                  Validate and show names without changing Azure
  --allow-placeholders       Permit values beginning with REPLACE_ME_
  -h, --help                 Show this help

Requirements:
  curl or wget. The script installs Azure CLI, jq, and mikefarah/yq v4
  when they are missing. Installing Azure CLI requires sudo on Ubuntu/Debian.
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

download_file() {
  (($# == 2)) || fail "download_file requires a URL and destination path."
  local url="${1}"
  local destination="${2}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" "$url"
  else
    fail "curl or wget is required to download dependencies."
  fi
}

install_azure_cli() {
  if command -v az >/dev/null 2>&1; then
    return
  fi

  [[ -r /etc/os-release ]] ||
    fail "Azure CLI is missing and the operating system could not be detected."

  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)
      ;;
    *)
      fail "Automatic Azure CLI installation supports Ubuntu/Debian only. Install Azure CLI manually."
      ;;
  esac

  command -v sudo >/dev/null 2>&1 ||
    fail "Azure CLI is missing. Automatic installation requires sudo on Ubuntu/Debian."

  installer_file="$(mktemp)"
  echo "Azure CLI was not found; installing it with Microsoft's Ubuntu/Debian installer..."
  download_file "https://aka.ms/InstallAzureCLIDeb" "$installer_file"
  sudo bash "$installer_file"
  rm -f -- "$installer_file"
  hash -r

  command -v az >/dev/null 2>&1 ||
    fail "Azure CLI installation completed but 'az' is still unavailable."
}

install_jq() {
  if command -v jq >/dev/null 2>&1; then
    return
  fi

  case "$(uname -m)" in
    x86_64)
      jq_arch="amd64"
      ;;
    aarch64|arm64)
      jq_arch="arm64"
      ;;
    *)
      fail "Unsupported architecture for automatic jq installation: $(uname -m)"
      ;;
  esac

  echo "jq was not found; installing it to ${HOME}/.local/bin/jq..."
  mkdir -p "${HOME}/.local/bin"
  download_file "https://github.com/jqlang/jq/releases/latest/download/jq-linux-${jq_arch}" "${HOME}/.local/bin/jq"
  chmod +x "${HOME}/.local/bin/jq"
  hash -r

  command -v jq >/dev/null 2>&1 ||
    fail "jq installation completed but 'jq' is still unavailable."
}

install_yq() {
  yq_version="$(yq --version 2>&1 || true)"
  if [[ "$yq_version" == *"mikefarah"* && "$yq_version" == *"version v4."* ]]; then
    return
  fi

  case "$(uname -m)" in
    x86_64)
      yq_arch="amd64"
      ;;
    aarch64|arm64)
      yq_arch="arm64"
      ;;
    *)
      fail "Unsupported architecture for automatic yq installation: $(uname -m)"
      ;;
  esac

  echo "Compatible yq v4 was not found; installing it to ${HOME}/.local/bin/yq..."
  mkdir -p "${HOME}/.local/bin"
  download_file "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" "${HOME}/.local/bin/yq"
  chmod +x "${HOME}/.local/bin/yq"
  hash -r

  yq_version="$(yq --version 2>&1 || true)"
  [[ "$yq_version" == *"mikefarah"* && "$yq_version" == *"version v4."* ]] ||
    fail "mikefarah/yq v4 installation failed. Found: $yq_version"
}

ensure_azure_login() {
  if az account show --only-show-errors --output none >/dev/null 2>&1; then
    return
  fi

  echo "No Azure CLI session found; attempting managed identity login..."
  if az login --identity --only-show-errors --output none >/dev/null 2>&1; then
    return
  fi

  fail "Azure authentication failed. Run 'az login', or assign a managed identity to this VM."
}

while (($# > 0)); do
  case "$1" in
    --values-file)
      (($# >= 2)) || fail "--values-file requires a path"
      values_file="$2"
      shift 2
      ;;
    --key-vault-name)
      (($# >= 2)) || fail "--key-vault-name requires a value"
      key_vault_name="$2"
      shift 2
      ;;
    --subscription-id)
      (($# >= 2)) || fail "--subscription-id requires a value"
      subscription_id="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --allow-placeholders)
      allow_placeholders=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

export PATH="${HOME}/.local/bin:${PATH}"

install_azure_cli
install_jq
install_yq

[[ -f "$values_file" ]] || fail "Values file not found: $values_file"

if [[ -z "$key_vault_name" ]]; then
  key_vault_name="$(yq -r '.azure.keyVaultName // ""' "$values_file")"
fi
if [[ -z "$subscription_id" ]]; then
  subscription_id="$(yq -r '.azure.subscriptionId // ""' "$values_file")"
fi

[[ -n "$key_vault_name" ]] ||
  fail "Set azure.keyVaultName in the YAML file or pass --key-vault-name."
[[ -n "$subscription_id" ]] ||
  fail "Set azure.subscriptionId in the YAML file or pass --subscription-id."

if [[ "$allow_placeholders" == false ]]; then
  [[ "$key_vault_name" != REPLACE_ME_* ]] ||
    fail "Replace the azure.keyVaultName placeholder, or pass --allow-placeholders."
  [[ "$subscription_id" != REPLACE_ME_* ]] ||
    fail "Replace the azure.subscriptionId placeholder, or pass --allow-placeholders."
fi

entries_file="$(mktemp)"
value_file=""
cleanup() {
  rm -f -- "$entries_file"
  if [[ -n "$value_file" ]]; then
    rm -f -- "$value_file"
  fi
}
trap cleanup EXIT

yq -o=json -I=0 '
  ["secrets", "config"][] as $category |
  (.[$category] // {}) |
  to_entries[] |
  {
    "category": $category,
    "name": .key,
    "value": (.value | tostring)
  }
' "$values_file" >"$entries_file"

[[ -s "$entries_file" ]] || fail "No entries were found under 'secrets' or 'config'."

duplicate_names="$(
  jq -r '.name' "$entries_file" |
    sort |
    uniq -d |
    paste -sd ',' -
)"
[[ -z "$duplicate_names" ]] ||
  fail "Key Vault names must be unique across both sections. Duplicates: $duplicate_names"

entry_count=0
while IFS= read -r entry; do
  name="$(jq -r '.name' <<<"$entry")"
  value="$(jq -r '.value' <<<"$entry")"

  [[ "$name" =~ ^[0-9A-Za-z-]{1,127}$ ]] ||
    fail "Invalid Key Vault secret name '$name'. Use only letters, numbers, and hyphens."

  if [[ "$allow_placeholders" == false && "$value" == REPLACE_ME_* ]]; then
    fail "Replace the placeholder value for '$name', or pass --allow-placeholders."
  fi

  ((entry_count += 1))
done <"$entries_file"

if [[ "$dry_run" == false ]]; then
  ensure_azure_login
  az account set --subscription "$subscription_id"
fi

completed=0
while IFS= read -r entry; do
  category="$(jq -r '.category' <<<"$entry")"
  name="$(jq -r '.name' <<<"$entry")"
  value="$(jq -r '.value' <<<"$entry")"

  if [[ "$dry_run" == true ]]; then
    echo "Would set [$category] $name"
    continue
  fi

  value_file="$(mktemp)"
  printf '%s' "$value" >"$value_file"

  az_args=(
    keyvault secret set
    --vault-name "$key_vault_name"
    --name "$name"
    --file "$value_file"
    --tags
    "sentinel-category=$category"
    "managed-by=set-sentinel-keyvault-values.sh"
    --only-show-errors
    --output none
  )
  az "${az_args[@]}"

  rm -f -- "$value_file"
  value_file=""
  ((completed += 1))
  echo "Set [$category] $name"
done <"$entries_file"

if [[ "$dry_run" == true ]]; then
  echo "Dry run complete. Validated $entry_count values for Key Vault '$key_vault_name'."
else
  echo "Completed. Uploaded $completed values to Key Vault '$key_vault_name'."
fi
