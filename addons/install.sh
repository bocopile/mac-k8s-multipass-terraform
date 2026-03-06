#!/bin/bash
set -eo pipefail

# Usage: addons/install.sh [options] [addon-names...]
# Batch install Kubernetes addons

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADDON_SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# Addon 카테고리 정의 (bash 3.2 호환 — 연관 배열 미사용)
CATEGORY_NAMES="infrastructure secrets gitops observability servicemesh security backup"

get_category_addons() {
    case "$1" in
        infrastructure) echo "priority-classes local-path-provisioner cilium tetragon metallb gateway-api cert-manager clustermesh" ;;
        secrets)        echo "vault vault-pki eso" ;;
        gitops)         echo "argocd" ;;
        observability)  echo "thanos prometheus-stack prometheus-agent loki tempo alloy otel-collector" ;;
        servicemesh)    echo "istio kiali" ;;
        security)       echo "kyverno falco" ;;
        backup)         echo "minio velero" ;;
        *)              return 1 ;;
    esac
}

# addon 이름 → 카테고리(서브디렉토리) 역매핑
get_addon_category() {
    local addon="$1"
    local category
    for category in ${CATEGORY_NAMES}; do
        local addons
        addons=$(get_category_addons "$category")
        local a
        for a in $addons; do
            if [[ "$a" == "$addon" ]]; then
                echo "$category"
                return 0
            fi
        done
    done
    return 1
}

# addon 이름 → 스크립트 경로
get_addon_script() {
    local addon="$1"
    local category
    category=$(get_addon_category "$addon") || { echo ""; return 1; }

    # setup-* 스크립트 특수 처리
    case "$addon" in
        clustermesh) echo "${ADDON_SCRIPTS_DIR}/${category}/setup-clustermesh.sh" ;;
        vault-pki)   echo "${ADDON_SCRIPTS_DIR}/${category}/setup-vault-pki.sh" ;;
        *)           echo "${ADDON_SCRIPTS_DIR}/${category}/install-${addon}.sh" ;;
    esac
}

set -u

# Addon 설치 순서 (의존성 기반)
INSTALL_ORDER=(
    "priority-classes"
    "local-path-provisioner"
    "cilium"
    "tetragon"
    "metallb"
    "gateway-api"
    "clustermesh"
    "cert-manager"
    "vault"
    "vault-pki"
    "eso"
    "argocd"
    "minio"          # thanos/loki/tempo가 MinIO 자격증명 필요 → 먼저 설치
    "velero"         # MinIO 버킷 의존
    "prometheus-stack" # ServiceMonitor CRD 제공 → thanos보다 먼저 설치
    "thanos"         # MinIO remote_write 엔드포인트 + ServiceMonitor CRD 의존
    "loki"
    "tempo"
    "alloy"
    "istio"
    "kiali"
    "falco"
    "kyverno"    # Kyverno webhook이 후속 설치를 차단하지 않도록 맨 마지막
)

# 사용법 출력
usage() {
    cat <<EOF
사용법: $(basename "$0") [옵션] [addon-names...]

옵션:
    --all               모든 addon 설치 (botkube 제외)
    --category <name>   카테고리별 설치
    --yes               확인 프롬프트 없이 즉시 설치 (CI/자동화 환경용)
    --list              설치 가능한 addon 목록 출력
    -h, --help          도움말 출력

예시:
    $(basename "$0") --all
    $(basename "$0") --all --yes
    $(basename "$0") --category observability
    $(basename "$0") vault argocd prometheus-stack

카테고리:
    infrastructure  - Cilium CNI, Tetragon, MetalLB, Gateway API, cert-manager, Cluster Mesh
    secrets         - Vault, Vault PKI, External Secrets Operator
    gitops          - ArgoCD
    observability   - Prometheus, Thanos, Loki, Tempo, Grafana Alloy
    servicemesh     - Istio, Kiali
    security        - Kyverno, Falco
    backup          - MinIO, Velero

Available addons:
$(list_addons)
EOF
}

# Addon 목록 출력
list_addons() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Available Addons"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for category in ${CATEGORY_NAMES}; do
        echo ""
        echo "[$category]"
        local addons
        addons=$(get_category_addons "$category")
        for addon in $addons; do
            local script
            script=$(get_addon_script "$addon")
            if [[ -f "$script" ]]; then
                echo "  ✓ $addon"
            else
                echo "  ✗ $addon (script not found)"
            fi
        done
    done
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Addon 설치
install_addon() {
    local addon=$1
    local script
    script=$(get_addon_script "$addon") || {
        echo "ERROR: Unknown addon: $addon"
        return 1
    }

    if [[ ! -f "$script" ]]; then
        echo "ERROR: Addon script not found: $script"
        return 1
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Installing: $addon"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if bash "$script"; then
        echo ""
        echo "✅ $addon installed successfully"
        return 0
    else
        echo ""
        echo "❌ $addon installation failed"
        return 1
    fi
}

# Main
main() {
    local addons_to_install=()
    local yes_flag=false

    # 인자 파싱
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)
                for addon in "${INSTALL_ORDER[@]}"; do
                    if [[ "$addon" != "botkube" ]]; then
                        addons_to_install+=("$addon")
                    fi
                done
                shift
                ;;
            --category)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --category requires a category name"
                    usage
                    exit 1
                fi
                local category=$2
                local category_addons
                category_addons=$(get_category_addons "$category" 2>/dev/null) || {
                    echo "ERROR: Unknown category: $category"
                    usage
                    exit 1
                }
                for addon in ${category_addons}; do
                    addons_to_install+=("$addon")
                done
                shift 2
                ;;
            --yes)
                yes_flag=true
                shift
                ;;
            --list)
                list_addons
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                echo "ERROR: Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                addons_to_install+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#addons_to_install[@]} -eq 0 ]]; then
        echo "ERROR: No addons specified"
        usage
        exit 1
    fi

    # 설치 순서대로 정렬
    local sorted_addons=()
    for addon in "${INSTALL_ORDER[@]}"; do
        for selected in "${addons_to_install[@]}"; do
            if [[ "$addon" == "$selected" ]]; then
                sorted_addons+=("$addon")
            fi
        done
    done

    # 설치 계획 출력
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Addon Installation Plan"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Addons to install (${#sorted_addons[@]}):"
    for addon in "${sorted_addons[@]}"; do
        echo "    - $addon"
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ "${yes_flag}" == true ]]; then
        echo "Proceeding without confirmation (--yes flag set)."
        REPLY="y"
    else
        read -p "Proceed with installation? [y/N] " -n 1 -r
        echo
    fi
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi

    # Addon 설치
    local failed_addons=()
    for addon in "${sorted_addons[@]}"; do
        if ! install_addon "$addon"; then
            failed_addons+=("$addon")
        fi
    done

    # 결과 출력
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Installation Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Total: ${#sorted_addons[@]}"
    echo "  Success: $((${#sorted_addons[@]} - ${#failed_addons[@]}))"
    echo "  Failed: ${#failed_addons[@]}"

    if [[ ${#failed_addons[@]} -gt 0 ]]; then
        echo ""
        echo "  Failed addons:"
        for addon in "${failed_addons[@]}"; do
            echo "    ❌ $addon"
        done
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 1
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "✅ All addons installed successfully!"
        exit 0
    fi
}

main "$@"
