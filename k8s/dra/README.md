# DRA track (Dynamic Resource Allocation)

The modern GPU scheduling path. See [../../docs/GPU_SCHEDULING.md](../../docs/GPU_SCHEDULING.md) for how this differs from the device plugin.

## Prerequisites

- **EKS 1.34+** (this repo's Terraform now defaults to 1.34). DRA is available on 1.33 but 1.34+ is recommended — core DRA went GA in 1.34.
- **Managed node group, not Karpenter.** DRA does not currently work with Karpenter or EKS Auto Mode.
- The **NVIDIA DRA driver** installed on the cluster (Helm chart from NVIDIA). The classic device plugin should be *removed* first — running both is a misconfiguration.

## Install the driver

```bash
kubectl delete -f ../gpu/nvidia-device-plugin.yaml   # remove the classic path first

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm install nvidia-dra-driver-gpu nvidia/nvidia-dra-driver-gpu \
  --namespace nvidia-dra-driver-gpu --create-namespace
```

Verify the driver is publishing devices:

```bash
kubectl get resourceslices          # one or more per GPU node
kubectl get deviceclasses           # e.g. gpu.nvidia.com
kubectl describe resourceslice <name>   # look at the published attributes — this is the whole point
```

> **Read the ResourceSlice output carefully.** Memory in bytes, compute capability, MIG profiles, NVLink topology — everything the old integer model threw away. This is the "aha" moment worth writing about.

## Apply the workload

```bash
kubectl apply -f resourceclaimtemplate.yaml
kubectl apply -f vllm-dra.yaml
```

## ⚠️ Verify the API shape before applying

DRA moved from `resource.k8s.io/v1beta1` to `resource.k8s.io/v1` when it went GA in 1.34, and the request structure changed. **These manifests are a starting point, not verified against your cluster.** Before applying:

```bash
kubectl explain resourceclaimtemplate.spec.spec.devices.requests
kubectl api-resources | grep resource.k8s.io
```

Adjust to match what your cluster and driver version actually expect. Debugging this yourself *is* the exercise — and it's exactly the kind of version-transition work these roles involve.
