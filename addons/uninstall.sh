#!/bin/bash
set -euo pipefail

# Usage: addons/uninstall.sh [options] [addon-names...]
# Batch uninstall Kubernetes addons

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi not found at ${GENERATED_DIR}"
  exit 1
fi

# 클러스터 컨텍스트 동적 로드 (clusters.json → 없으면 기본값)
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"
if [[ -f "${CLUSTERS_JSON}" ]]; then
  mapfile -t ALL_CONTEXTS < <(jq -r 'keys[] | "kubernetes-admin@\(.)"' "${CLUSTERS_JSON}")
else
  ALL_CONTEXTS=("kubernetes-admin@mgmt" "kubernetes-admin@app1" "kubernetes-admin@app2")
fi

# Addon별 네임스페이스 및 리소스 정의
declare -A ADDON_NAMESPACES=(
    ["priority-classes"]="_cluster_scoped_"
    ["cilium"]="cilium-system kube-system"
    ["tetragon"]="kube-system"
    ["metallb"]="metallb-system"
    ["gateway-api"]=""
    ["cert-manager"]="cert-manager"
    ["clustermesh"]=""
    ["vault"]="vault"
    ["vault-pki"]=""
    ["eso"]="security"
    ["argocd"]="argocd"
    ["platform-addons"]="trivy-system k8sgpt opencost vpa goldilocks chaos-mesh"
    ["k8sgpt"]="k8sgpt localai"
    ["thanos"]="observability"
    ["prometheus-stack"]="monitoring"
    ["alloy"]="observability"

    ["loki"]="observability"
    ["tempo"]="observability"
    ["istio"]="istio-system"
    ["kiali"]="istio-system"
    ["kyverno"]="security"
    ["falco"]="security"
    ["holmesgpt"]="aiops"
    ["botkube"]="aiops"
    ["minio"]="backup"
    ["velero"]="backup"
)

# Addon별 Helm release 이름
declare -A ADDON_RELEASES=(
    ["priority-classes"]=""
    ["cilium"]="cilium"
    ["tetragon"]="tetragon"
    ["metallb"]="metallb"
    ["gateway-api"]=""
    ["cert-manager"]="cert-manager"
    ["clustermesh"]=""
    ["vault"]="vault"
    ["vault-pki"]=""
    ["eso"]="external-secrets"
    ["argocd"]="argocd"
    ["platform-addons"]="trivy-operator k8sgpt-operator opencost vpa goldilocks chaos-mesh"
    ["k8sgpt"]="k8sgpt-operator"
    ["thanos"]="thanos"
    ["prometheus-stack"]="kube-prometheus-stack"
    ["alloy"]="alloy"

    ["loki"]="loki"
    ["tempo"]="tempo"
    ["istio"]="istiod istio-ingress"
    ["kiali"]="kiali"
    ["kyverno"]="kyverno"
    ["falco"]="falco"
    ["holmesgpt"]="holmesgpt"
    ["botkube"]="botkube"
    ["minio"]="minio"
    ["velero"]="velero"
)

# 삭제 순서 (역순)
UNINSTALL_ORDER=(
    "velero"
    "minio"
    "botkube"
    "holmesgpt"
    "falco"
    "kyverno"
    "kiali"
    "istio"
    "alloy"
    "tempo"
    "loki"
    "prometheus-stack"
    "thanos"
    "k8sgpt"
    "platform-addons"
    "argocd"
    "eso"
    "vault-pki"
    "vault"
    "cert-manager"
    "clustermesh"
    "gateway-api"
    "metallb"
    "tetragon"
    "cilium"
    "priority-classes"
)

usage() {
    cat <<EOF
사용법: $(basename "$0") [옵션] [addon-names...]

옵션:
    --all               모든 addon 삭제
    --namespace <ns>    특정 네임스페이스의 모든 리소스 삭제
    --force             확인 없이 즉시 삭제
    -h, --help          도움말 출력

예시:
    # 모든 addon 삭제
    $(basename "$0") --all

    # 특정 addon만 삭제
    $(basename "$0") vault argocd

    # 네임스페이스 기반 삭제
    $(basename "$0") --namespace monitoring

Available addons:
$(list_addons)
EOF
}

list_addons() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for addon in "${UNINSTALL_ORDER[@]}"; do
        echo "  - $addon (namespace: ${ADDON_NAMESPACES[$addon]:-unknown})"
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

uninstall_addon() {
    local addon=$1
    local namespaces="${ADDON_NAMESPACES[$addon]:-}"
    local releases="${ADDON_RELEASES[$addon]:-}"

    # Cluster-scoped 리소스 처리 (네임스페이스 없음)
    if [[ "$namespaces" == "_cluster_scoped_" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Uninstalling: $addon (cluster-scoped)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for context in "${ALL_CONTEXTS[@]}"; do
            echo "Deleting PriorityClasses on ${context}..."
            kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$context" \
                delete priorityclass platform-critical platform-normal --ignore-not-found || true
        done
        echo "✅ $addon uninstalled"
        return 0
    fi

    if [[ -z "$namespaces" ]]; then
        echo "WARNING: No namespace defined for addon: $addon"
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Uninstalling: $addon"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Helm release 삭제
    if [[ -n "$releases" ]]; then
        for release in $releases; do
            for ns in $namespaces; do
                echo "Checking Helm release: $release in namespace: $ns"
                for context in "${ALL_CONTEXTS[@]}"; do
                    if helm list --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$context" -n "$ns" 2>/dev/null | grep -q "^${release}"; then
                        echo "Uninstalling Helm release: $release (context: $context, namespace: $ns)"
                        helm uninstall "$release" --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$context" -n "$ns" || true
                    fi
                done
            done
        done
    fi

    # 네임스페이스 삭제
    for ns in $namespaces; do
        echo "Checking namespace: $ns"
        for context in "${ALL_CONTEXTS[@]}"; do
            if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$context" get namespace "$ns" &>/dev/null; then
                echo "Deleting namespace: $ns (context: $context)"
                kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$context" delete namespace "$ns" --timeout=60s || true
            fi
        done
    done

    echo "✅ $addon uninstalled"
}

main() {
    local addons_to_uninstall=()
    local force=false

    # 인자 파싱
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)
                addons_to_uninstall=("${UNINSTALL_ORDER[@]}")
                shift
                ;;
            --namespace)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --namespace requires a namespace name"
                    exit 1
                fi
                ns=$2
                echo "Deleting all resources in namespace: $ns"
                for context in "${ALL_CONTEXTS[@]}"; do
                    kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$context" delete namespace "$ns" --timeout=60s 2>/dev/null || true
                done
                exit 0
                ;;
            --force)
                force=true
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
                addons_to_uninstall+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#addons_to_uninstall[@]} -eq 0 ]]; then
        echo "ERROR: No addons specified"
        usage
        exit 1
    fi

    # 확인
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Addon Uninstallation Plan"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Addons to uninstall (${#addons_to_uninstall[@]}):"
    for addon in "${addons_to_uninstall[@]}"; do
        echo "    - $addon (namespace: ${ADDON_NAMESPACES[$addon]:-unknown})"
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "⚠️  WARNING: This will permanently delete the above addons and their data!"
    echo ""

    if [[ "$force" != "true" ]]; then
        read -p "Proceed with uninstallation? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Uninstallation cancelled."
            exit 0
        fi
    fi

    # 삭제 실행
    for addon in "${addons_to_uninstall[@]}"; do
        uninstall_addon "$addon"
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Uninstallation Complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "✅ All specified addons have been uninstalled."
    echo ""
    echo "NOTE: /etc/hosts 정리가 필요한 경우:"
    echo "  sudo sed -i '' '/# Kubernetes Multi-Cluster Services/,/# ========================================\$/d' /etc/hosts"
}

main "$@"
