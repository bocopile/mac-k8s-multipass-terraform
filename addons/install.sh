#!/bin/bash
set -eo pipefail

# Usage: addons/install.sh [options] [addon-names...]
# Batch install Kubernetes addons

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADDON_SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# Addon 카테고리 정의
declare -A CATEGORIES
CATEGORIES[infrastructure]="cilium tetragon metallb gateway-api cert-manager clustermesh"
CATEGORIES[secrets]="vault vault-pki eso"
CATEGORIES[gitops]="argocd"
CATEGORIES[observability]="prometheus-stack thanos prometheus-agent loki tempo otel-collector"
CATEGORIES[servicemesh]="istio kiali"
CATEGORIES[security]="kyverno falco platform-addons"
CATEGORIES[aiops]="k8sgpt holmesgpt botkube"
CATEGORIES[backup]="minio velero"

set -u

# Addon 설치 순서 (의존성 기반)
INSTALL_ORDER=(
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
    "platform-addons"
    "k8sgpt"
    "thanos"
    "prometheus-stack"
    "prometheus-agent"
    "loki"
    "tempo"
    "otel-collector"
    "istio"
    "kiali"
    "kyverno"
    "falco"
    "holmesgpt"
    "botkube"
    "minio"
    "velero"
)

# 사용법 출력
usage() {
    cat <<EOF
사용법: $(basename "$0") [옵션] [addon-names...]

옵션:
    --all               모든 addon 설치 (botkube 제외)
    --category <name>   카테고리별 설치 (secrets, gitops, observability, servicemesh, security, aiops, backup)
    --list              설치 가능한 addon 목록 출력
    -h, --help          도움말 출력

예시:
    # 모든 addon 설치
    $(basename "$0") --all

    # 특정 카테고리 설치
    $(basename "$0") --category observability

    # 특정 addon만 설치
    $(basename "$0") vault argocd prometheus-stack

    # 여러 addon 설치
    $(basename "$0") vault eso argocd

카테고리:
    infrastructure  - Cilium CNI, Tetragon, MetalLB, Gateway API, cert-manager, Cluster Mesh
    secrets         - Vault, Vault PKI, External Secrets Operator
    gitops          - ArgoCD
    observability   - Prometheus, Thanos, Loki, Tempo, OpenTelemetry
    servicemesh     - Istio, Kiali
    security        - Kyverno, Falco, Platform Addons (Trivy, K8sGPT Operator, etc.)
    aiops           - K8sGPT, HolmesGPT, Botkube
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
    for category in "${!CATEGORIES[@]}"; do
        echo ""
        echo "[$category]"
        local addons="${CATEGORIES[$category]}"
        for addon in $addons; do
            local script="${ADDON_SCRIPTS_DIR}/install-${addon}.sh"
            # setup-* 스크립트 특수 처리
            if [[ "$addon" == "clustermesh" ]]; then
                script="${ADDON_SCRIPTS_DIR}/setup-clustermesh.sh"
            elif [[ "$addon" == "vault-pki" ]]; then
                script="${ADDON_SCRIPTS_DIR}/setup-vault-pki.sh"
            fi

            if [[ -f "$script" ]]; then
                echo "  ✓ $addon"
            else
                echo "  ✗ $addon (script not found: $script)"
            fi
        done
    done
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Addon 설치
install_addon() {
    local addon=$1
    local script="${ADDON_SCRIPTS_DIR}/install-${addon}.sh"

    # setup-* 스크립트 특수 처리
    if [[ "$addon" == "clustermesh" ]]; then
        script="${ADDON_SCRIPTS_DIR}/setup-clustermesh.sh"
    elif [[ "$addon" == "vault-pki" ]]; then
        script="${ADDON_SCRIPTS_DIR}/setup-vault-pki.sh"
    fi

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

    # 인자 파싱
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)
                # 모든 addon 설치 (botkube는 수동 설치 필요하므로 제외)
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
                category=$2
                if [[ ! -v CATEGORIES[$category] ]]; then
                    echo "ERROR: Unknown category: $category"
                    usage
                    exit 1
                fi
                for addon in ${CATEGORIES[$category]}; do
                    addons_to_install+=("$addon")
                done
                shift 2
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

    # Addon이 지정되지 않은 경우
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

    # 설치 시작
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

    read -p "Proceed with installation? [y/N] " -n 1 -r
    echo
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
