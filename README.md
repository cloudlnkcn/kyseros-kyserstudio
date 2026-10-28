# Kyserai app for KyserOS

KyserOS app manifests and container build process for [Kyserai](https://github.com/cloudlnkcn/kyserai),
a local LLM server with OpenAI-compatible REST APIs, published in NVIDIA,
AMD, and Intel GPU variants.

## One image, one provider association per variant

All three variants ship the same program from one shared image. What differs
is only the OS provider each variant manifest is associated with: an explicit
CDI request in `devices` selects the matching KyserOS host provider artifact
(kernel modules, firmware, and driver user space built by the sibling
provider repositories and pinned to the OS build). KyserOS prepares the
requested provider before the container starts, injects its CDI resources,
and silently drops the request when the provider is not available so the app
always starts and Kyserai falls back to CPU.

| KyserOS app | Manifest | OS provider repo | CDI request |
|---|---|---|---|
| `kyserai` | `nvidia/app.json` | `kyseros-nvidia` | `nvidia.com/gpu=all` |
| `kyserai-rocm` | `amd/app.json` | `kyseros-amd` | `amd.com/gpu=all` |
| `kyserai-intel` | `intel/app.json` | `kyseros-intel` | `intel.com/gpu=all` |

A variant's directory name (`nvidia` / `amd` / `intel`) is the catalog's
variant column; the slug and the CDI request keep the manifest and its
provider a matched pair.

## No drivers are baked in

Following the KyserOS provider contract, the image carries no GPU driver
stack at all:

- The provider host extensions own everything driver-shaped. The NVIDIA
  provider injects `libcuda`, the NVIDIA Vulkan ICD, and the device nodes;
  the AMD provider injects the RADV ICD and its libdrm alongside `amdgpu`;
  the Intel provider injects the i915/xe render nodes. Nothing in this
  repository duplicates any of it.
- The image supplies only what the contract leaves to the app: the current
  Khronos Vulkan loader, built from source at the `VULKAN_VERSION` pin in
  the Dockerfile (newer than Ubuntu's distro package) plus `vulkan-tools`,
  and Kyserai's common runtime libraries. The Vulkan llama.cpp backend
  works on every variant because the loader scans the ICD that the
  provider's CDI spec mounts in.
- The remaining inference backends (llama.cpp CUDA / ROCm / SYCL, sd.cpp,
  FastFlowLM) are downloaded at runtime by Kyserai itself, so their CUDA
  and ROCm runtimes arrive with the backend, never inside the image.

FastFlowLM on the AMD XDNA2 NPU needs the `amdxdna` driver, NPU
firmware, and the XRT user space, which are driver components and
therefore the AMD provider's responsibility: `kyseros-amd` ships all
three, and its CDI spec adds the `/dev/accel/*` device nodes and the XRT
libraries to GPU containers when an NPU is bound. Nothing NPU-related is
baked into this image.

## Container build

The [Dockerfile](Dockerfile) builds Kyserai from the sibling `kyserai`
checkout, supplied as the named build context `kyserai`. One build serves
all three variants:

```sh
docker buildx build \
    --build-context kyserai=../kyserai \
    -t kyserai:v10.26.1-kyseros.1 .
```

Local builds require the `kyserai` repository checked out next to this one.
The apt stages default to the Aliyun Ubuntu archive mirror
(`APT_MIRROR=mirrors.aliyun.com`) and the Khronos clones go through the
ghfast.top proxy (`GITHUB_MIRROR=https://ghfast.top/`), matching networks
that cannot reach the upstream archives; pass `--build-arg APT_MIRROR=<host>`
or `--build-arg GITHUB_MIRROR=` (empty) to point them at the upstream
servers.
Local builds are the only build path: there is no CI image build workflow.
Build the image and mirror it to wherever KyserOS loads it from.

## Versioning

KyserOS package versions use `<kyserai-release>-kyseros.<revision>`. The
current release is `v10.26.1-kyseros.1`, based on Kyserai `v10.26.1`, and
the image tag matches the package version. Bump the version together with
the `source_ref` and `image` in each manifest and the `VULKAN_VERSION` pin
in the Dockerfile.

## Publishing

Publishing is two halves: manifests reach the catalog through git, the
image reaches the registry through one script. The manifest half goes
first; a freshly published catalog entry is not installable until the
image half binds the registry reference onto it.

1. Manifests: commit, tag, and push. On the cloud service, run a catalog
   sync and publish the pending staging entries (or author the entries
   in the dashboard). The matching relative `icon.png` goes to the
   KyserOS CDN once per release.
2. Image and bindings, with the service login (values recorded in the
   kyseros-amd AGENTS.md):

   ```sh
   KYSEROS_SERVICE_EMAIL=... KYSEROS_SERVICE_PASSWORD=... \
       scripts/publish.sh
   ```

   This builds the shared image from the sibling `kyserai` checkout,
   uploads it under `kyseros-apps/kyserai`, binds the registry reference
   to all three catalog entries, and binds the newest
   `kyseros-providers/amd-driver` upload on the service (its current
   digest) to `kyserai-rocm` - no digest to copy by hand. Rerun with
   `--skip-build` when only the bindings change, `--sync` to trigger a
   catalog sync and show the pending review queue, `--provider-ref REF`
   to bind an explicit reference (the NVIDIA and Intel providers go
   this way), and `--no-provider` to leave the provider binding alone.
   The Dockerfile already defaults to the Aliyun apt mirror and the
   ghfast.top GitHub proxy; `KYSEROS_GITHUB_MIRROR` (or
   `--github-mirror`) overrides the latter, and an explicitly empty
   value falls back to the upstream servers.

The provider artifact carries the OS build id and kernel ABI digest, and
the device verifies both against the running slot at activation, so the
app, its provider, and the OS always stay a matched set. No KyserOS
backend container deployment is required for an app release.

## Validation

```sh
python -m unittest discover -s tests -v
```

Real GPU inference is validated by KyserOS's protected dev-only hardware E2E
gate before production promotion.

## Upstream

- [Kyserai](https://github.com/cloudlnkcn/kyserai)
- [Kyserai API overview](https://github.com/cloudlnkcn/kyserai/blob/main/docs)

## License

The KyserOS manifests, container build process, and supporting files in this
repository are licensed under the MIT License. Kyserai and model licenses
remain governed by their respective upstream projects.
