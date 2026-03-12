# Kubernetes

```
1- 2 ec2 2instance one as master node and one as worker node

Create at least 2 instances.

Node	Instance Type	Example Name
Master Node	t2.medium	k8s-master
Worker Node	t2.medium	k8s-worker1

===============================================================

2- Kubernetes Master Node Security Group Rules
Port	Protocol	Purpose	Source
22	TCP	SSH access	Your IP (e.g. your-public-ip/32)
6443	TCP	Kubernetes API Server	Worker Node Security Group
2379-2380	TCP	etcd server client API	Master Node Security Group
10250	TCP	Kubelet API	Worker Node Security Group
10257	TCP	kube-controller-manager	Master Node Security Group
10259	TCP	kube-scheduler	Master Node Security Group

```


```
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f ingress.yaml
```
