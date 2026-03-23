# 1. Uninstall Helm releases
helm uninstall loki -n monitoring 2>/dev/null && echo "loki removed" || echo "loki not found"
helm uninstall promtail -n monitoring 2>/dev/null && echo "promtail removed" || echo "promtail not found"

# 2. Delete PVCs created by loki
kubectl delete pvc -n monitoring \
  -l "app.kubernetes.io/name=loki" --ignore-not-found=true

# 3. Delete the Grafana datasource ConfigMap
kubectl delete configmap loki-datasource -n monitoring --ignore-not-found=true

# 4. Delete any stuck pods left behind
kubectl delete pod -n monitoring \
  -l "app.kubernetes.io/name=loki" --ignore-not-found=true --force --grace-period=0
kubectl delete pod -n monitoring \
  -l "app.kubernetes.io/name=promtail" --ignore-not-found=true --force --grace-period=0

# 5. Confirm everything is gone
echo "=== Remaining pods ===" && kubectl get pods -n monitoring
echo "=== Remaining PVCs ===" && kubectl get pvc -n monitoring
echo "=== Helm releases ===" && helm list -n monitoring
