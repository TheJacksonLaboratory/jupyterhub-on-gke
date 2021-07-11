# jupyterhub-on-gke
Script to setup a secure Jupyterhub on Google Kubernetes Engine

The script creates a Kubernetes Cluster and runs the Jupyterhub helm chart (0.10.6). 

An example Dockerfile for the Jupyterlab single user with gcloud can be [obtained here](https://github.com/snamburi3/gcloud-jupyterhub).

## Steps to build the cluster and install jupyterhub
```
# authenticate to Google Cloud
gcloud auth login

# set project
gcloud config set project {PROJECT_ID}

# gcloud components update to get the latest version (including beta versions)
gcloud components update

# Install helm (The minimum supported version of Helm in Z2JH is 3.2.0.)
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# add the JupyterHub Helm chart repository 
helm repo add jupyterhub https://jupyterhub.github.io/helm-chart/
helm repo update

# modify the singularity.image.name in the config.yaml to a custom image. here is the [Example Dockerfile](https://github.com/snamburi3/gcloud-jupyterhub). The config pulls the image from Dockerhub

# change parameters in the config.yaml and Makefile according to your deployment
1. make sure "serviceAccountName" in config.yaml matches "KUBE_SVC" in Makefile

# To get help:
make help

# create a Kubernetes Cluster, Kubernetes namespace, and install Jupyterhub. 
# make changes to the parameters in the Makefile
make create-cluster

# create Kubernetes namespace, and install Jupyterhub.
make deploy

# use a https load balancer to connect to jupyterhub proxy (backend) on port 30080 (Node Port). you can also create Kubernetes Ingress object on "proxy-public". Make sure you create https load balancer

# Delete the cluster
make delete
```

## Deploying for workshops
```
# this is the same command as the `make deploy`, but it does not enable workload identity (as it is not required).
make deploy-workshops
```

## Connection back to onprem
For connection back to onprem, do the following:
1. In the config file, change the CONNECT_ONPREM to `true`.

2. Specify the shared VPC network and subnet (VPN) for the following fields (see example below):
```
NETWORK="projects/my-sharedvpc-project/global/networks/my-sharedvpc-us-east-1"
SUBNETWORK="projects/my-sharedvpc-project/regions/us-east1/subnetworks/my-sharedvpc-subnet"
```

3. Also, make sure you specify the following in the "create-cluster" command:
```
--cluster-secondary-range-name "pods" \
--services-secondary-range-name "services" \
```

4. Once the cluster and jupyterhub is installed, run the [IP masquerade agent](https://cloud.google.com/kubernetes-engine/docs/how-to/ip-masquerade-agent) by running the following command `make apply-ip-masq-agent`


## Individual make commands to build the cluster, install jupyterhub, and debug
```
apply-ip-masq-agent            apply an IP masq agent for connection back to onprem
cleanup-namespace              clean the workloads in the namespace
connect-cluster                connect to cluster
create-cluster                 Create a GKE Cluster
create-gcp-nodes-svc           create a service account for GCP compute / GKE nodes
create-namespace               create cluster namespace
delete-cluster                 delete the cluster
delete-release                 delete the delete
deploy                         connect to cluster, enable workload identity, install jupyterhub, enable apparmor and psp, restart Jupyterhub 
disable-psp                    disable the pod security policy
enable-apparmor                enable the apparmor loader
enable-netpol                  enable network policy
enable-psp                     enable the pod security policy and update the cluster config
enable-wi                      enable the workload identity for the cluster
get-ip                         get the intenal (if NodePort) or external (if Load Balancer) IP address for public proxy
get-namespaces                 get namespaces
get-pods-by-release            get the pods by the helm chart release
get-pods                       show pods in the namespace 
get-roles                      show rolebinding in the cluster
get-status                     get status of the deployments
helm-get-values                show helm chart values
help                           use make help to show help
install-jupyterhub             install jupyterhub
restart                        restart Jupyterhub after configuration changes
retry-install                  retry installing jupyterhub
```

## available main commands 
```
# deploy:
	vars connect-cluster create-namespace create-gcp-nodes-svc enable-wi install-jupyterhub enable-apparmor enable-psp restart get-ip
# restart:  
	install-jupyterhub 
# connect-onprem
	vars connect-cluster enable-apparmor enable-psp apply-ip-masq-agent install-jupyterhub get-ip
# retry-install: 
	install-jupyterhub enable-apparmor enable-psp restart get-ip
```
