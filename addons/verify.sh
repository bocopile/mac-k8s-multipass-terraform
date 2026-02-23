#!/bin/bash
set -euo pipefail

# Usage: addons/verify.sh [addon-names...]
# Verify addon installation status

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi not found at ${GENERATED_DIR}"
  exit 1
fi

# Addon별 검증 설정
declare -A ADDON_CHECK=(
    # Format: "context:namespace:deployment|statefulset|daemonset:name"
    # priority-classes: cluster-scoped 리소스이므로 verify.sh에서 별도 확인
    ["cilium"]="mgmt:kube-system:daemonset:cilium"
    ["tetragon"]="mgmt:kube-system:daemonset:tetragon"
    ["metallb"]="mgmt:metallb-system:deployment:metallb-controller"
    ["cert-manager"]="mgmt:cert-manager:deployment:cert-manager"
    ["vault"]="mgmt:vault:statefulset:vault"
    ["eso"]="mgmt:security:deployment:external-secrets"
    ["argocd"]="mgmt:argocd:deployment:argocd-server"
    ["k8sgpt"]="mgmt:k8sgpt:deployment:k8sgpt-operator-controller-manager"
    ["thanos"]="mgmt:observability:statefulset:thanos-receive"
    ["prometheus-stack"]="mgmt:monitoring:statefulset:prometheus-kube-prometheus-stack-prometheus"
    ["alloy"]="mgmt:observability:daemonset:alloy"
    ["alloy-app1"]="app1:observability:daemonset:alloy"
    ["opensearch"]="mgmt:observability:statefulset:opensearch"
    ["loki"]="mgmt:observability:statefulset:loki"
    ["tempo"]="mgmt:observability:deployment:tempo"
    ["istio"]="mgmt:istio-system:deployment:istiod"
    ["kiali"]="mgmt:istio-system:deployment:kiali"
    ["kyverno"]="app1:security:deployment:kyverno-admission-controller"
    ["falco"]="app1:security:daemonset:falco"
    ["holmesgpt"]="mgmt:aiops:deployment:robusta-runner"
    ["botkube"]="mgmt:aiops:deployment:botkube"
    ["minio"]="mgmt:backup:statefulset:minio"
    ["velero"]="mgmt:backup:deployment:velero"
)

usage() {
    cat <<EOF
사용법: $(basename "$0") [addon-names...]

옵션:
    --all               모든 addon 검증
    --summary           요약만 출력
    -h, --help          도움말 출력

예시:
    # 모든 addon 검증
    $(basename "$0") --all

    # 특정 addon만 검증
    $(basename "$0") vault argocd prometheus-stack

    # 요약 출력
    $(basename "$0") --all --summary

Available addons:
$(list_addons)
EOF
}

list_addons() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for addon in "${!ADDON_CHECK[@]}"; do
        echo "  - $addon"
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

verify_addon() {
    local addon=$1
    local check_config="${ADDON_CHECK[$addon]:-}"

    if [[ -z "$check_config" ]]; then
        echo "  ⚠️  $addon - No verification config defined"
        return 2
    fi

    IFS=':' read -r context namespace kind name <<< "$check_config"
    local kube_context="kubernetes-admin@${context}"

    # 네임스페이스 확인
    if ! kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" get namespace "$namespace" &>/dev/null; then
        echo "  ❌ $addon - Namespace not found: $namespace"
        return 1
    fi

    # 리소스 확인
    local ready=false
    case "$kind" in
        deployment)
            if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                -n "$namespace" get deployment "$name" &>/dev/null; then
                local replicas_ready
                local replicas_desired
                replicas_ready=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                    -n "$namespace" get deployment "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
                replicas_desired=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                    -n "$namespace" get deployment "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

                if [[ "$replicas_ready" == "$replicas_desired" ]] && [[ "$replicas_ready" -gt 0 ]]; then
                    ready=true
                fi
            fi
            ;;
        statefulset)
            if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                -n "$namespace" get statefulset "$name" &>/dev/null; then
                local replicas_ready
                local replicas_desired
                replicas_ready=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                    -n "$namespace" get statefulset "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
                replicas_desired=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                    -n "$namespace" get statefulset "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

                if [[ "$replicas_ready" == "$replicas_desired" ]] && [[ "$replicas_ready" -gt 0 ]]; then
                    ready=true
                fi
            fi
            ;;
        daemonset)
            if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                -n "$namespace" get daemonset "$name" &>/dev/null; then
                local number_ready
                local desired_number
                number_ready=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                    -n "$namespace" get daemonset "$name" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
                desired_number=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "$kube_context" \
                    -n "$namespace" get daemonset "$name" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "1")

                if [[ "$number_ready" == "$desired_number" ]] && [[ "$number_ready" -gt 0 ]]; then
                    ready=true
                fi
            fi
            ;;
    esac

    if $ready; then
        echo "  ✅ $addon - Running ($kind/$name in $namespace @ $context)"
        return 0
    else
        echo "  ❌ $addon - Not ready ($kind/$name in $namespace @ $context)"
        return 1
    fi
}

main() {
    local addons_to_verify=()

    # 인자 파싱
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)
                addons_to_verify=("${!ADDON_CHECK[@]}")
                shift
                ;;
            --summary)
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
                addons_to_verify+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#addons_to_verify[@]} -eq 0 ]]; then
        echo "ERROR: No addons specified"
        usage
        exit 1
    fi

    # 검증 실행
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Addon Verification"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local total=0
    local success=0
    local failed=0
    local skipped=0

    for addon in "${addons_to_verify[@]}"; do
        ((total++)) || true
        verify_addon "$addon"
        local ret=$?
        case $ret in
            0) ((success++)) || true ;;
            2) ((skipped++)) || true ;;
            *) ((failed++)) || true ;;
        esac
    done

    # 결과 출력
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Verification Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Total:   $total"
    echo "  Success: $success"
    echo "  Failed:  $failed"
    echo "  Skipped: $skipped"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ $failed -gt 0 ]]; then
        echo "❌ Some addons are not ready"
        exit 1
    else
        echo "✅ All verified addons are running"
        exit 0
    fi
}

main "$@"
