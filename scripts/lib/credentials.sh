#!/bin/bash
# Credential Management Library
# Provides secure credential generation and management

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../../generated"
CREDENTIALS_FILE="${GENERATED_DIR}/.credentials.env"

# Ensure generated directory exists
mkdir -p "${GENERATED_DIR}"

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
    # Load existing credentials
    source "${CREDENTIALS_FILE}"
  fi

  # Generate if not exists
  if [[ -z "${MINIO_ROOT_USER:-}" ]]; then
    export MINIO_ROOT_USER=$(generate_username "minio")
    export MINIO_ROOT_PASSWORD=$(generate_password 32)

    # Save to file
    {
      echo "# MinIO Credentials (auto-generated)"
      echo "MINIO_ROOT_USER=${MINIO_ROOT_USER}"
      echo "MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}"
    } >> "${CREDENTIALS_FILE}"

    chmod 600 "${CREDENTIALS_FILE}"
  fi

  echo "MINIO_ROOT_USER=${MINIO_ROOT_USER}"
  echo "MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}"
}

# Get or generate MySQL credentials
get_mysql_credentials() {
  if [[ -f "${CREDENTIALS_FILE}" ]]; then
    source "${CREDENTIALS_FILE}"
  fi

  if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
    export MYSQL_ROOT_PASSWORD=$(generate_password 32)

    {
      echo "# MySQL Credentials (auto-generated)"
      echo "MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}"
    } >> "${CREDENTIALS_FILE}"

    chmod 600 "${CREDENTIALS_FILE}"
  fi

  echo "MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}"
}

# Load all credentials from file
load_credentials() {
  if [[ -f "${CREDENTIALS_FILE}" ]]; then
    # Disable history for security
    set +H
    source "${CREDENTIALS_FILE}"
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

  mkdir -p "${GENERATED_DIR}"

  # Remove existing entry if present
  if [[ -f "${CREDENTIALS_FILE}" ]]; then
    sed -i.bak "/^${key}=/d" "${CREDENTIALS_FILE}"
    rm -f "${CREDENTIALS_FILE}.bak"
  fi

  # Append new value
  echo "${key}=${value}" >> "${CREDENTIALS_FILE}"
  chmod 600 "${CREDENTIALS_FILE}"
}

# Initialize credentials file
init_credentials() {
  if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
    cat > "${CREDENTIALS_FILE}" <<'EOF'
# =============================================================================
# Kubernetes Multi-Cluster Credentials
# =============================================================================
# This file contains auto-generated credentials for platform services.
# DO NOT commit this file to Git (.gitignore should exclude it).
# Generated: $(date)
# =============================================================================

EOF
    chmod 600 "${CREDENTIALS_FILE}"
    echo "Credentials file initialized: ${CREDENTIALS_FILE}"
  fi
}
