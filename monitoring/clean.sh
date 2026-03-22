# Uninstall Helm release
helm uninstall kube-prom-stack -n monitoring 2>/dev/null || true

# Delete namespaces (this also removes all PVCs, pods, services)
kubectl delete namespace monitoring --ignore-not-found=true
kubectl delete namespace local-path-storage --ignore-not-found=true

# Delete the StorageClass and RBAC we created
kubectl delete storageclass local-path --ignore-not-found=true
kubectl delete clusterrole local-path-provisioner-role --ignore-not-found=true
kubectl delete clusterrolebinding local-path-provisioner-bind --ignore-not-found=true

# Confirm everything is gone
kubectl get ns | grep -E "monitoring|local-path"
