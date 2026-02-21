#!/bin/bash
# Credential Management Library
# Provides secure credential generation and management

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../../generated"
CREDENTIALS_FILE="${GENERATED_DIR}/.credentials.env"

# Ensure generated directory exists with restricted permissions
mkdir -p "${GENERATED_DIR}"

# Ensure credentials file exists with secure permissions (prevents race condition)
ensure_credentials_file() {
  if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
    (umask 077; touch "${CREDENTIALS_FILE}")
  fi
}

# Validate credentials file contains only safe KEY=VALUE lines
validate_credentials_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  # Allow only comments, blank lines, and KEY=VALUE patterns
  if grep -qvE '^[[:space:]]*(#.*)?$|^[A-Z_][A-Z0-9_]*=.*$' "$file"; then
    echo "ERROR: Credentials file contains invalid content: $file" >&2
    return 1
  fi
  return 0
}

# Safe source: validate before sourcing
safe_source() {
  local file="$1"
  if [[ -f "$file" ]] && validate_credentials_file "$file"; then
    source "$file"
  else
    echo "WARNING: Skipping unsafe or missing credentials file: $file" >&2
    return 1
  fi
}

# Generate random password
generate_password() {
  local length="${1:-32}"
  openssl rand -base64 "$length" | tr -d '/+=' | head -c "$length"
}

# Generate random username
generate_username() {
  local prefix="${1:-admin}"
  echo "${prefix}-$(openssl rand -hex 8)"
}

# Get or generate MinIO credentials
get_minio_credentials() {
  if [[ -f "${CREDENTIALS_FILE}" ]]; then
    safe_source "${CREDENTIALS_FILE}" || true
  fi

  # Generate if not exists
  if [[ -z "${MINIO_ROOT_USER:-}" ]]; then
    export MINIO_ROOT_USER=$(generate_username "minio")
    export MINIO_ROOT_PASSWORD=$(generate_password 32)

    # Save to file (secure from creation)
    ensure_credentials_file
    {
      echo "# MinIO Credentials (auto-generated)"
      echo "MINIO_ROOT_USER=${MINIO_ROOT_USER}"
      echo "MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}"
    } >> "${CREDENTIALS_FILE}"
  fi

  echo "MINIO_ROOT_USER=${MINIO_ROOT_USER}"
  echo "MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}"
}

# Get or generate MySQL credentials
get_mysql_credentials() {
  if [[ -f "${CREDENTIALS_FILE}" ]]; then
    safe_source "${CREDENTIALS_FILE}" || true
  fi

  if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
    export MYSQL_ROOT_PASSWORD=$(generate_password 32)

    # Save to file (secure from creation)
    ensure_credentials_file
    {
      echo "# MySQL Credentials (auto-generated)"
      echo "MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}"
    } >> "${CREDENTIALS_FILE}"
  fi

  echo "MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}"
}

# Load all credentials from file
load_credentials() {
  if [[ -f "${CREDENTIALS_FILE}" ]]; then
    set +H
    safe_source "${CREDENTIALS_FILE}"
    set -H
    return 0
  else
    echo "WARNING: Credentials file not found. Generating new credentials..." >&2
    return 1
  fi
}

# Save credential to file
save_credential() {
  local key="$1"
  local value="$2"

  # Validate key: only uppercase letters and underscores allowed
  if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    echo "ERROR: Invalid credential key format: $key (must match [A-Z_][A-Z0-9_]*)" >&2
    return 1
  fi

  mkdir -p "${GENERATED_DIR}"
  ensure_credentials_file

  # Remove existing entry if present (use | as sed delimiter to avoid injection)
  if [[ -s "${CREDENTIALS_FILE}" ]]; then
    sed -i.bak "/^${key}=/d" "${CREDENTIALS_FILE}"
    rm -f "${CREDENTIALS_FILE}.bak"
  fi

  # Append new value
  echo "${key}=${value}" >> "${CREDENTIALS_FILE}"
}

# Initialize credentials file
init_credentials() {
  if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
    (umask 077; cat > "${CREDENTIALS_FILE}" <<EOF
# =============================================================================
# Kubernetes Multi-Cluster Credentials
# =============================================================================
# This file contains auto-generated credentials for platform services.
# DO NOT commit this file to Git (.gitignore should exclude it).
# Generated: $(date)
# =============================================================================

EOF
    )
    echo "Credentials file initialized: ${CREDENTIALS_FILE}"
  fi
}
