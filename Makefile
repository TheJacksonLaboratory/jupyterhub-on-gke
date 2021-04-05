SHELL=/bin/bash

# Export variables
PROJECT_ID=$(shell gcloud config get-value core/project)
CLUSTER_NAME=jupyterhub-gke
ZONE=us-east1-b
REGION=us-east1
KUBE_NAMESPACE=jupyterhub
HELM_RELEASE=jhub
INSTANCE_TYPE=e2-medium
NUM_NODES=4
JUPYTERHUB_VERSION=0.10.6
NETWORK="projects/${PROJECT_ID}/global/networks/default" #(note this can be a shared VPC network. this applies to subnet as well)
SUBNETWORK="projects/${PROJECT_ID}/regions/${REGION}/subnetworks/default"
GCR_BUCKET=gs://artifacts.${PROJECT_ID}.appspot.com #(if us.gcr.io, use us.artifacts)
NETWORK_TAG="jupyterhub"
CONNECT_ONPREM=false
GCP_NODES_SVC=gke-nodes
GCP_WI_SVC="jupyterhub-workload-sa"
KUBE_WI_SVC="jupyterhub-workload-k8s-sa"

# colors
BLUE := $(shell tput -Txterm setaf 6)
GREEN := $(shell tput -Txterm setaf 2)
RESET := $(shell tput -Txterm sgr0)

# if you need to connect to on-prem, override the network policy
ifeq ($(CONNECT_ONPREM),true)
  libs = --values override.yaml
else
  libs = 
endif

deploy: vars connect-cluster create-namespace enable-wi install-jupyterhub enable-apparmor enable-psp restart get-ip ## connect to cluster, enable workload identity, install jupyterhub, enable apparmor and psp, restart Jupyterhub 
restart:  install-jupyterhub ## restart Jupyterhub after configuration changes
connect-onprem: vars connect-cluster enable-apparmor enable-psp apply-ip-masq-agent install-jupyterhub get-ip
retry: install-jupyterhub enable-apparmor enable-psp restart get-ip ## retry installing jupyterhub

vars: # Display variables
	@echo "PROJECT ID: $(PROJECT_ID)"
	@echo "CLUSTER ID: $(CLUSTER_NAME)"
	@echo "ZONE: $(ZONE)"
	@echo "REGION: $(REGION)"
	@echo "INSTANCE TYPE: $(INSTANCE_TYPE)"
	@echo "NUM NODES: $(NUM_NODES)"
	@echo "NAMESPACE: $(KUBE_NAMESPACE)"
	@echo "HELM RELEASE: $(HELM_RELEASE)"

create-cluster: create-gcp-nodes-svc ## Create a GKE Cluster
	@echo ""
	@echo "Create GKE Cluster"
	gcloud beta container clusters create ${CLUSTER_NAME} \
	  --project ${PROJECT_ID} \
	  --zone ${ZONE} \
	  --machine-type ${INSTANCE_TYPE} \
	  --num-nodes ${NUM_NODES} \
	  --workload-pool=${PROJECT_ID}.svc.id.goog \
	  --network ${NETWORK} \
	  --subnetwork ${SUBNETWORK} \
	  --node-locations ${ZONE} \
	  --tags ${NETWORK_TAG} \
	  --service-account "${GCP_NODES_SVC}@${PROJECT_ID}.iam.gserviceaccount.com" \
	  --release-channel regular \
	  --enable-ip-alias \
	  --default-max-pods-per-node "110" \
	  --disk-size "100" \
	  --cluster-secondary-range-name "pods" \
	  --services-secondary-range-name "services" \
	  --addons HorizontalPodAutoscaling,HttpLoadBalancing \
	  --enable-autoupgrade \
	  --enable-autorepair \
	  --enable-stackdriver-kubernetes \
	  --enable-network-policy \
	  --metadata disable-legacy-endpoints=true \
	  --enable-shielded-nodes \
	  --image-type "COS" \
	  --no-enable-basic-auth

create-gcp-nodes-svc: ## create a service account for GCP compute / GKE nodes
	$(eval ALREADY_PRESENT := $(shell gcloud iam service-accounts list --filter='name:'$(GCP_NODES_SVC)'' --format='value(name)'))
	if [ -n "$(ALREADY_PRESENT)" ]; then \
            echo "Service account ${GCP_NODES_SVC} already exists"; \
        else \
            gcloud iam service-accounts create ${GCP_NODES_SVC} --display-name=${GCP_NODES_SVC}; \
        fi
	gcloud projects add-iam-policy-binding ${PROJECT_ID} \
	  --member "serviceAccount:${GCP_NODES_SVC}@${PROJECT_ID}.iam.gserviceaccount.com" \
	  --role roles/logging.logWriter
	
	gcloud projects add-iam-policy-binding ${PROJECT_ID} \
	  --member "serviceAccount:${GCP_NODES_SVC}@${PROJECT_ID}.iam.gserviceaccount.com" \
	  --role roles/monitoring.metricWriter
	
	gcloud projects add-iam-policy-binding ${PROJECT_ID} \
	  --member "serviceAccount:${GCP_NODES_SVC}@${PROJECT_ID}.iam.gserviceaccount.com" \
	  --role roles/monitoring.viewer
	
	gcloud projects add-iam-policy-binding ${PROJECT_ID} \
	  --member "serviceAccount:${GCP_NODES_SVC}@${PROJECT_ID}.iam.gserviceaccount.com" \
	  --role roles/stackdriver.resourceMetadata.writer
	# give objectViewer access to that the nodes can access the container registry
	gsutil iam ch \
	  serviceAccount:${GCP_NODES_SVC}@${PROJECT_ID}.iam.gserviceaccount.com:objectViewer \
	  ${GCR_BUCKET}

connect-cluster: ## connect to cluster
	@echo ""
	@echo "Connect to Cluster"
	gcloud container clusters get-credentials ${CLUSTER_NAME} --zone=${ZONE} --project ${PROJECT_ID}

create-namespace: ## create cluster namespace
	@echo ""
	@echo "# Create Namespace"
	echo -e "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: ${KUBE_NAMESPACE}" | kubectl apply -f - 

install-jupyterhub: ## install jupyterhub
	@echo "" 
	@echo "# Install Jupyterhub"
	helm upgrade --cleanup-on-fail \
	  --install ${HELM_RELEASE} \
	  jupyterhub/jupyterhub \
	  --namespace ${KUBE_NAMESPACE} \
	  --version=${JUPYTERHUB_VERSION} \
	  --values config.yaml \
	  --create-namespace \
	  --wait --timeout 1000s \
	  ${libs}

get-ip: ## get the intenal (if NodePort) or external (if Load Balancer) IP address for public proxy
	@echo "Get IP"
	@echo "You can find the public IP of the JupyterHub by doing. The hub and IP address might take a few minutes to be provisioned"
	kubectl --namespace=${KUBE_NAMESPACE} get svc proxy-public

apply-ip-masq-agent: ## apply an IP masq agent for connection back to onprem
	# Adding a ConfigMap to your cluster (IP masquerade agent) for connection back to onprem
	cd manifests/networking && \
	kubectl create configmap ip-masq-agent --from-file config --namespace kube-system

enable-psp: ## enable the pod security policy and update the cluster config
	kubectl apply -f  manifests/security/psp.yaml --namespace ${KUBE_NAMESPACE}
	gcloud beta container clusters update ${CLUSTER_NAME}  --zone ${ZONE} --enable-pod-security-policy

enable-netpol: ## enable network policy
	kubectl apply -f  manifests/networking/netpol-default.yaml --namespace ${KUBE_NAMESPACE}
	kubectl apply -f  manifests/networking/netpol-singleuser.yaml --namespace ${KUBE_NAMESPACE}
	kubectl apply -f  manifests/networking/netpol-hub.yaml --namespace ${KUBE_NAMESPACE}

helm-get-values: ## show helm chart values
	helm get values --namespace ${KUBE_NAMESPACE} ${HELM_RELEASE}

enable-apparmor: ## enable the apparmor loader
	kubectl apply -f  manifests/security/apparmor-loader.yaml

get-pods: ## show pods in the namespace 
	kubectl --namespace=${KUBE_NAMESPACE} get pod

get-namespaces: ## get namespaces
	kubectl get deployments -o wide --namespace ${KUBE_NAMESPACE}

get-pods-by-release: ## get the pods by the helm chart release
	kubectl get pods -l release=${HELM_RELEASE} -n ${KUBE_NAMESPACE} -o jsonpath="{range .items[*]}{.metadata.name}{'\n'}{range .spec.containers[*]}{.name}{'\t'}{.image}{'\n\n'}{end}{'\n'}{end}{'\n'}"

get-status: ## get status of the deployments
	kubectl get pod,svc,deployments,pv,pvc,ingress -n ${KUBE_NAMESPACE}

delete-release: ## delete the delete
	helm delete ${HELM_RELEASE} --namespace ${KUBE_NAMESPACE}

cleanup-namespace: ## clean the workloads in the namespace
	kubectl delete all --all --namespace ${KUBE_NAMESPACE}

disable-psp: ## disable the pod security policy
	kubectl delete psp restrictive-psp
	gcloud beta container clusters update ${CLUSTER_NAME}  --zone ${ZONE} --no-enable-pod-security-policy

delete-cluster: ## delete the cluster
	@echo ""
	@echo "Delete GKE Cluster"
	gcloud container clusters delete ${CLUSTER_NAME} --project ${PROJECT_ID} --zone=${ZONE}

get-roles: ## show rolebinding in the cluster
	kubectl get rolebindings,clusterrolebindings --namespace ${KUBE_NAMESPACE}
	kubectl describe role --namespace ${KUBE_NAMESPACE}

enable-wi: ## enable the workload identity for the cluster
	$(eval ALREADY_PRESENT := $(shell gcloud iam service-accounts list --filter='name:'$(GCP_WI_SVC)'' --format='value(name)'))
	echo ${ALREADY_PRESENT}
	if [ -n "$(ALREADY_PRESENT)" ]; then \
            echo "Service account ${GCP_WI_SVC} already exists"; \
        else \
            gcloud iam service-accounts create ${GCP_WI_SVC} --display-name=${GCP_WI_SVC}; \
        fi
	## create a service account for our k8s namespace
	kubectl create serviceaccount "jupyterhub-workload-k8s-sa" -n jupyterhub --dry-run=client -o yaml | kubectl apply -f -
	## bind GCP SA(GSA) with k8s SA (KSA)
	gcloud iam service-accounts add-iam-policy-binding \
	  --role=roles/iam.workloadIdentityUser \
	  --member=serviceAccount:${PROJECT_ID}.svc.id.goog[${KUBE_NAMESPACE}/${KUBE_WI_SVC}] \
	  ${GCP_WI_SVC}@${PROJECT_ID}.iam.gserviceaccount.com
	## Annotate the kubernetes service account (KSA)
	kubectl annotate serviceaccount \
	  --overwrite \
	  --namespace ${KUBE_NAMESPACE} ${KUBE_WI_SVC} iam.gke.io/gcp-service-account=${GCP_WI_SVC}@${PROJECT_ID}.iam.gserviceaccount.com

help: ## use make help to show help
	@echo ""
	@echo "            ${GREEN}Secure Jupyterhub Setup${GREEN}"
	@echo ""
	@grep -E '^[a-zA-Z_0-9%-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "${BLUE}%-30s${RESET} %s\n", $$1, $$2}'

