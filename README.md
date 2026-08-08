# Reefy Ollama apps

Canonical Reefy app manifests for running Ollama with NVIDIA, AMD, and Intel
GPU acceleration.

## Variants

| Reefy app | Manifest | Upstream image | Accelerator |
|---|---|---|---|
| `ollama` | `nvidia/app.json` | `ollama/ollama:0.32.6` | NVIDIA CUDA |
| `ollama-rocm` | `amd/app.json` | `ollama/ollama:0.32.6-rocm` | AMD ROCm |
| `ollama-intel` | `intel/app.json` | `ollama/ollama:0.32.6` | Intel Vulkan |

The three manifests are lightweight wrappers around official Ollama images.
This repository does not rebuild or mirror Ollama. Each package records its
exact upstream image and uses Reefy's CDI device requests to activate the
matching host provider.

Intel acceleration uses Ollama's Vulkan backend and sets `OLLAMA_VULKAN=1`
plus `OLLAMA_IGPU_ENABLE=1`. Ollama 0.32.6 requires the latter opt-in to keep
integrated GPUs in its scheduler. The Intel NPU is not requested because
Ollama currently targets Intel GPUs, not the NPU.

## Versioning

Reefy package versions use `<upstream-release>-reefy.<revision>`. NVIDIA and
AMD use `v0.32.6-reefy.1`; Intel uses `v0.32.6-reefy.2` to include the iGPU
scheduler opt-in. All variants are based on Ollama `v0.32.6`.

## Publishing

Reefy's catalog imports each manifest from this repository by an immutable git
tag. The app publisher uploads the matching relative `icon.png` to the Reefy
CDN and stores the assembled catalog entry in PostgreSQL. No Reefy backend
container deployment is required for an app release.

## Validation

```sh
python -m unittest discover -s tests -v
```

Real GPU inference is validated by Reefy's protected dev-only hardware E2E
gate before production promotion.

## Upstream

- [Ollama](https://github.com/ollama/ollama)
- [Ollama Docker instructions](https://docs.ollama.com/docker)
- [Ollama hardware support](https://docs.ollama.com/gpu)

## License

The Reefy manifests and supporting files in this repository are licensed
under the MIT License. Ollama and model licenses remain governed by their
respective upstream projects.
