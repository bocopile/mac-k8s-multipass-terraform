# 운영 런북 (Operations Runbook)

> **버전**: 2.0.0
> **관련 문서**: [아키텍처](ARCHITECTURE.md) | [구현 가이드](IMPLEMENTATION-GUIDE.md)

이 문서는 백업, 복구, 업그레이드, 트러블슈팅 등 운영 절차를 포함합니다.

---

## 목차

1. [일상 운영](#1-일상-운영)
2. [백업 절차](#2-백업-절차)
3. [복구 절차](#3-복구-절차)
4. [업그레이드 절차](#4-업그레이드-절차)
5. [트러블슈팅](#5-트러블슈팅)
6. [긴급 대응](#6-긴급-대응)

---

## 1. 일상 운영

### 1.1 클러스터 상태 확인

```bash
# 모든 클러스터 노드 상태
for ctx in mgmt app1 app2; do
  echo "=== $ctx ==="
  kubectl --context $ctx get nodes
done

# 시스템 Pod 상태
kubectl get pods -n kube-system

# Cilium 상태
cilium status
cilium clustermesh status
```

### 1.2 리소스 사용량 확인

```bash
# 노드 리소스
kubectl top nodes

# Pod 리소스
kubectl top pods -A --sort-by=memory | head -20

# PVC 사용량
kubectl get pvc -A
```

### 1.3 인증서 만료 확인

```bash
# cert-manager 인증서 상태
kubectl get certificates -A

# 만료 임박 인증서 확인 (30일 이내)
kubectl get certificates -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.notAfter}{"\n"}{end}'
```

---

## 2. 백업 절차

### 2.1 etcd 스냅샷 백업

```bash
#!/bin/bash
# scripts/backup/etcd-snapshot.sh

SNAPSHOT_DIR="/var/backups/etcd"
SNAPSHOT_NAME="etcd-snapshot-$(date +%Y%m%d-%H%M%S).db"

mkdir -p ${SNAPSHOT_DIR}

# etcd 스냅샷 생성
ETCDCTL_API=3 etcdctl snapshot save "${SNAPSHOT_DIR}/${SNAPSHOT_NAME}" \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 스냅샷 검증
ETCDCTL_API=3 etcdctl snapshot status "${SNAPSHOT_DIR}/${SNAPSHOT_NAME}" --write-out=table

# 7일 이상 된 스냅샷 삭제
find ${SNAPSHOT_DIR} -name "etcd-snapshot-*.db" -mtime +7 -delete

echo "etcd 스냅샷 완료: ${SNAPSHOT_NAME}"
```

### 2.2 Velero 백업

```bash
# 네임스페이스 백업
velero backup create ns-backup-$(date +%Y%m%d) \
  --include-namespaces default,app \
  --ttl 168h

# 전체 클러스터 백업
velero backup create full-backup-$(date +%Y%m%d) \
  --exclude-namespaces kube-system \
  --ttl 168h

# 백업 상태 확인
velero backup get
velero backup describe <backup-name>
```

### 2.3 백업 스케줄 설정

```yaml
# velero-schedule.yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-backup
  namespace: velero
spec:
  schedule: "0 2 * * *"  # 매일 02:00
  template:
    ttl: 168h  # 7일 보존
    includedNamespaces:
      - default
      - app
    storageLocation: default
```

---

## 3. 복구 절차

### 3.1 etcd 복구

> ⚠️ **주의**: etcd 복구는 클러스터 전체에 영향을 미칩니다.

**사전 체크리스트**:
- [ ] 백업 스냅샷 파일 존재 확인
- [ ] 스냅샷 무결성 검증
- [ ] 다른 관리자에게 통보

```bash
#!/bin/bash
# scripts/backup/etcd-restore.sh

SNAPSHOT_FILE="${1:-}"
ETCD_DATA_DIR="/var/lib/etcd"

if [ -z "$SNAPSHOT_FILE" ]; then
  echo "Usage: $0 <snapshot-file>"
  exit 1
fi

echo "=== etcd 복구 시작 ==="

# 1. 스냅샷 무결성 검증
ETCDCTL_API=3 etcdctl snapshot status "$SNAPSHOT_FILE" --write-out=table

# 2. API 서버 중지
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 10

# 3. 기존 데이터 백업
sudo mv $ETCD_DATA_DIR /var/lib/etcd-backup-$(date +%Y%m%d-%H%M%S)

# 4. 스냅샷 복원
ETCDCTL_API=3 etcdctl snapshot restore "$SNAPSHOT_FILE" \
  --data-dir=$ETCD_DATA_DIR \
  --name=$(hostname) \
  --initial-cluster=$(hostname)=https://$(hostname):2380 \
  --initial-advertise-peer-urls=https://$(hostname):2380

# 5. 권한 설정
sudo chown -R etcd:etcd $ETCD_DATA_DIR

# 6. API 서버 재시작
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/

echo "=== 복구 완료 ==="
echo "kubectl get nodes 로 확인하세요"
```

### 3.2 Velero 복구

```bash
# 백업 목록 확인
velero backup get

# 복구 실행
velero restore create --from-backup <backup-name>

# 특정 네임스페이스만 복구
velero restore create --from-backup <backup-name> \
  --include-namespaces app

# 복구 상태 확인
velero restore get
velero restore describe <restore-name>
```

### 3.3 전체 클러스터 재구축

```bash
#!/bin/bash
# scripts/disaster-recovery.sh

echo "=== 재해 복구 시작 ==="

# 1. Terraform으로 VM 재생성
cd terraform
terraform destroy -auto-approve
terraform apply -auto-approve
cd ..

# 2. 클러스터 초기화
./scripts/init-cluster.sh mgmt
./scripts/init-cluster.sh app1
./scripts/init-cluster.sh app2

# 3. 플랫폼 서비스 설치
./scripts/install-platform.sh

# 4. Velero로 워크로드 복구
velero restore create --from-backup <latest-backup>

echo "=== 재해 복구 완료 ==="
```

---

## 4. 업그레이드 절차

### 4.1 Kubernetes 버전 업그레이드

**사전 체크리스트**:
- [ ] 현재 버전 확인
- [ ] 업그레이드 경로 확인 (마이너 버전은 순차적으로)
- [ ] etcd 백업 완료
- [ ] PDB 설정 확인

```bash
#!/bin/bash
# scripts/upgrade/k8s-upgrade.sh

TARGET_VERSION="${1:-1.35.1}"

echo "=== Kubernetes 업그레이드: $TARGET_VERSION ==="

# 1. 현재 버전 확인
kubectl version

# 2. kubeadm 업그레이드
sudo apt-get update
sudo apt-get install -y kubeadm=${TARGET_VERSION}-00

# 3. 업그레이드 계획 확인
sudo kubeadm upgrade plan

# 4. Control Plane 업그레이드
sudo kubeadm upgrade apply v${TARGET_VERSION}

# 5. kubelet 업그레이드
sudo apt-get install -y kubelet=${TARGET_VERSION}-00 kubectl=${TARGET_VERSION}-00
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# 6. Worker 노드 업그레이드 (각 노드에서)
# kubectl drain <node-name> --ignore-daemonsets
# sudo kubeadm upgrade node
# kubectl uncordon <node-name>

echo "=== 업그레이드 완료 ==="
kubectl get nodes
```

### 4.2 Helm 차트 업그레이드

```bash
# 차트 버전 확인
helm list -A

# 저장소 업데이트
helm repo update

# 차트 업그레이드
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values values-prometheus.yaml

# 롤백 (문제 발생 시)
helm rollback prometheus 1 -n monitoring
```

### 4.3 Cilium 업그레이드

```bash
# 현재 버전 확인
cilium version

# 업그레이드
cilium upgrade --version 1.16.0

# 상태 확인
cilium status
```

---

## 5. 트러블슈팅

### 5.1 Pod가 시작되지 않음

```bash
# Pod 상태 확인
kubectl describe pod <pod-name> -n <namespace>

# 이벤트 확인
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# 로그 확인
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous  # 이전 컨테이너
```

### 5.2 네트워크 문제

```bash
# Cilium 연결성 테스트
cilium connectivity test

# 엔드포인트 상태
kubectl get ciliumendpoints -A

# Hubble로 트래픽 확인
hubble observe --namespace <namespace>
```

### 5.3 스토리지 문제

```bash
# PVC 상태
kubectl get pvc -A

# PV 상태
kubectl get pv

# 볼륨 마운트 오류
kubectl describe pod <pod-name> | grep -A5 "Volumes:"
```

### 5.4 인증서 문제

```bash
# 인증서 상태 확인
kubectl get certificates -A
kubectl describe certificate <cert-name> -n <namespace>

# 인증서 재발급
kubectl delete certificate <cert-name> -n <namespace>
# cert-manager가 자동으로 재발급
```

### 5.5 Vault 문제

```bash
# Vault 상태
kubectl exec -it vault-0 -n vault -- vault status

# Vault 봉인 해제
kubectl exec -it vault-0 -n vault -- vault operator unseal <key>

# External Secrets 동기화 상태
kubectl get externalsecrets -A
```

---

## 6. 긴급 대응

### 6.1 클러스터 접근 불가

```bash
# 1. VM 상태 확인
multipass list

# 2. VM 재시작
multipass restart mgmt-cp

# 3. kubelet 상태 확인 (VM 내부)
multipass exec mgmt-cp -- sudo systemctl status kubelet

# 4. API 서버 로그
multipass exec mgmt-cp -- sudo journalctl -u kubelet -f
```

### 6.2 디스크 용량 부족

```bash
# 1. 디스크 사용량 확인
df -h

# 2. 오래된 이미지 정리
crictl rmi --prune

# 3. 오래된 로그 정리
sudo journalctl --vacuum-time=3d

# 4. 사용하지 않는 PV 확인
kubectl get pv | grep Released
```

### 6.3 메모리 부족 (OOM)

```bash
# 1. 메모리 사용량 확인
kubectl top nodes
kubectl top pods -A --sort-by=memory

# 2. OOMKilled Pod 확인
kubectl get pods -A | grep OOMKilled

# 3. 리소스 제한 조정
kubectl edit deployment <name> -n <namespace>
```

### 6.4 긴급 연락처

| 상황 | 담당 | 연락처 |
|-----|-----|--------|
| 클러스터 장애 | Platform Team | - |
| 보안 인시던트 | Security Team | - |
| 외부 서비스 장애 | Infra Team | - |

---

## 부록: 유용한 명령어

```bash
# 컨텍스트 전환
kubectl config use-context mgmt

# 모든 리소스 조회
kubectl get all -A

# YAML로 리소스 내보내기
kubectl get deployment <name> -o yaml > backup.yaml

# 강제 삭제
kubectl delete pod <name> --force --grace-period=0

# 로그 스트리밍
kubectl logs -f deployment/<name> -n <namespace>

# 리소스 사용량 모니터링
watch kubectl top pods -A
```
