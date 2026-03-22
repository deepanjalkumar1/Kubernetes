
# 1. From your local machine (kubectl must be configured)
chmod +x deploy-monitoring.sh
./deploy-monitoring.sh

# 2. From the master node (SSH in first)
scp fix-controlplane-metrics.sh ubuntu@<master-ip>:~/
ssh ubuntu@<master-ip>
sudo bash fix-controlplane-metrics.sh

# 3. Health check (from local machine)
./check-monitoring.sh
