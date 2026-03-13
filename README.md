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
# some commands: kubectl get endpoints fastapi-service

Before running kubectl apply -f deployment.yaml install aws cli and docker.io

Run:

aws configure

It will ask:

AWS Access Key ID:
AWS Secret Access Key:
Default region name:
Default output format:

aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin xxxxxxxxxxxxxx.dkr.ecr.ap-south-1.amazonaws.com

kubectl create secret docker-registry ecr-pull-secret \
  --docker-server=XXXXXXXXXXXX.dkr.ecr.ap-south-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$(aws ecr get-login-password --region ap-south-1)

if the images are pushed to aws ecr which is private you will need access key

kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
kubectl apply -f ingress.yaml

      if you are seeing error like : Error from server (InternalError): error when creating "ingress.yaml": Internal error occurred: failed calling webhook "validate.nginx.ingress.kubernetes.io": failed to call webhook: Post "https://ingress-nginx-controller-admission.ingress-nginx.svc:443/networking/v1/ingresses?timeout=10s": context deadline exceeded

      then do this : kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission

                     kubectl apply -f ingress.yaml

WorkerNodeIP:30080
http://<worker-node-ip>:30080


```


```
Delete the Deployment first (optional but cleaner)
kubectl delete deployment fastapi

This stops Kubernetes from recreating pods while you make changes.

If you also want to remove the Service:

kubectl delete svc fastapi-service

If you have Ingress:

kubectl delete ingress fastapi-ingress
```

```
Create AWS Load Balancer

Now create an AWS ALB.

Listener:

HTTP : 80

Target group:

Instance type

Target:

WorkerNodeIP : 30080

Health check path:

/

```
