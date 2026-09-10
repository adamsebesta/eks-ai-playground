.PHONY: local-up local-down local-inference local-chat eks-up eks-down kubeconfig ollama-secret ollama-secret-dev storageclass bootstrap argocd argocd-apps argocd-password argocd-ui grafana-password grafana-ui gpu-plugin vllm vllm-chat dra-driver dra-inspect dra-vllm dra-claims dra-down fmt validate

CLUSTER_NAME ?= eks-ai-playground
AWS_REGION   ?= eu-central-1

## ----- Local (kind) -----

local-up:
	kind create cluster --name ai-playground --config local/kind-config.yaml

local-down:
	kind delete cluster --name ai-playground

local-inference:
	kubectl apply -f local/manifests/ollama.yaml
	@echo "Waiting for Ollama to be ready..."
	kubectl -n inference wait --for=condition=available deploy/ollama --timeout=300s
	@echo "Pulling model (first time takes a few minutes)..."
	kubectl -n inference exec deploy/ollama -- ollama pull qwen2.5:0.5b

local-chat:
	@echo "Port-forwarding Ollama on :11434 — Ctrl+C to stop"
	@echo 'Try: curl localhost:11434/api/generate -d '"'"'{"model":"qwen2.5:0.5b","prompt":"Why is the sky blue?","stream":false}'"'"''
	kubectl -n inference port-forward svc/ollama 11434:11434

## ----- EKS -----

eks-up:
	cd terraform && terraform init && terraform plan -out=tfplan && terraform apply tfplan

eks-down:
	cd terraform && terraform destroy

kubeconfig:
	aws eks update-kubeconfig --name $(CLUSTER_NAME) --region $(AWS_REGION)

# alb-controller now installed via Terraform's helm_release (main.tf) —
# needs real Terraform-computed values (VPC ID, IRSA ARN), which a Makefile
# target or Argo CD Application has no clean way to fetch. `make eks-up`
# handles it now.

ollama-secret:
	kubectl create namespace inference --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic ollama-secret -n inference --from-literal=dummy-api-key=sk-test-12345 --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/ollama-pvc.yaml

storageclass:
	kubectl apply -f k8s/storageclass-gp3.yaml

argocd:
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update
	helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
		-f helm-values/argocd/values.yaml
	kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
	kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=180s

ollama-secret-dev:
	kubectl create namespace inference-dev --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic ollama-secret -n inference-dev --from-literal=dummy-api-key=sk-test-12345 --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/ollama-pvc-dev.yaml

# One object — Argo CD takes it from here. Adding a 4th app later means
# dropping a new file in k8s/argocd-apps/ and pushing, not touching this
# Makefile or running kubectl by hand.
argocd-apps: ollama-secret-dev
	kubectl apply -f k8s/root-app.yaml

argocd-password:
	kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
	@echo ""

argocd-ui:
	@echo "Login at https://localhost:8080 — user: admin, password: run 'make argocd-password'"
	kubectl port-forward -n argocd svc/argocd-server 8080:443

# karpenter (the controller) now installed via Terraform's helm_release
# (main.tf), same reasoning as alb-controller above. `make eks-up` handles
# it. The NodePool/EC2NodeClass objects are now Argo CD-managed too
# (k8s/argocd-apps/karpenter-resources.yaml) — the node role name became
# static (pinned in main.tf) so no terraform output/sed step is needed
# anymore, and nothing here couples to how/where `terraform apply` runs.

# monitoring now an Argo CD Application (k8s/argocd-apps/monitoring.yaml) —
# zero Terraform-dependent values, a clean fit unlike alb-controller/karpenter.

grafana-password:
	kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
	@echo ""

grafana-ui:
	@echo "Login at http://localhost:3001 — user: admin, password: run 'make grafana-password'"
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3001:80

# Everything a fresh `make eks-up` needs afterward to be usable again —
# none of this is Terraform-managed, so it doesn't survive a teardown/rebuild.
bootstrap: kubeconfig storageclass ollama-secret argocd argocd-apps

# gpu-up/gpu-down removed — Karpenter provisions/deprovisions GPU capacity
# automatically based on real pod demand (k8s/karpenter/nodepool-gpu.yaml),
# replacing the old static-node-group manual toggle entirely.

gpu-plugin:
	kubectl apply -f k8s/gpu/nvidia-device-plugin.yaml

vllm:
	kubectl apply -f k8s/vllm/namespace.yaml
	kubectl apply -f k8s/vllm/deployment.yaml
	kubectl apply -f k8s/vllm/service.yaml
	@echo "vLLM downloading model weights — first start takes ~5-10 min. Watch: kubectl -n inference logs -f deploy/vllm"

vllm-chat:
	@echo "Port-forwarding vLLM on :8000 — Ctrl+C to stop"
	@echo 'Try: curl localhost:8000/v1/chat/completions -H "Content-Type: application/json" -d '"'"'{"model":"Qwen/Qwen2.5-1.5B-Instruct","messages":[{"role":"user","content":"Hello!"}]}'"'"''
	kubectl -n inference port-forward svc/vllm 8000:8000

## ----- DRA track (modern GPU scheduling — see docs/GPU_SCHEDULING.md) -----
## NOTE: DRA does not work with Karpenter. Requires EKS 1.34+ and managed node groups.

dra-driver:
	kubectl delete -f k8s/gpu/nvidia-device-plugin.yaml --ignore-not-found
	helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
	helm repo update
	helm install nvidia-dra-driver-gpu nvidia/nvidia-dra-driver-gpu \
		--namespace nvidia-dra-driver-gpu --create-namespace

dra-inspect:
	@echo "== ResourceSlices (what the driver publishes) =="
	kubectl get resourceslices
	@echo "== DeviceClasses =="
	kubectl get deviceclasses
	@echo "Now: kubectl describe resourceslice <name> — read the attributes"

dra-vllm:
	@echo "Verify the API shape first: kubectl explain resourceclaimtemplate.spec.spec.devices.requests"
	kubectl apply -f k8s/vllm/namespace.yaml
	kubectl apply -f k8s/dra/resourceclaimtemplate.yaml
	kubectl apply -f k8s/dra/vllm-dra.yaml

dra-claims:
	kubectl -n inference get resourceclaims
	kubectl -n inference describe resourceclaims

dra-down:
	kubectl delete -f k8s/dra/vllm-dra.yaml --ignore-not-found
	kubectl delete -f k8s/dra/resourceclaimtemplate.yaml --ignore-not-found

## ----- Hygiene -----

fmt:
	cd terraform && terraform fmt -recursive

validate:
	cd terraform && terraform init -backend=false && terraform validate
