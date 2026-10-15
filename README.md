# Kyserai GPU apps for KyserOS

KyserOS app manifests and container build process for [Kyserai](https://github.com/cloudlnkcn/kyserai),
a local LLM server with OpenAI-compatible REST APIs, published in NVIDIA,
AMD, and Intel GPU variants.

## Variants

| KyserOS app | Manifest | Image | Accelerator |
|---|---|---|---|
| `kyserai` | `nvidia/app.json` | `kyserai:v10.25.5-nvidia` | NVIDIA CUDA |
| `kyserai-rocm` | `amd/app.json` | `kyserai:v10.25.5-amd` | AMD ROCm / XDNA2 NPU |
| `kyserai-intel` | `intel/app.json` | `kyserai:v10.25.5-intel` | Intel Vulkan / SYCL |

All three variants ship the same Kyserai program. The images differ only in
runtime libraries: the AMD image additionally carries the XRT user space used
by the FastFlowLM NPU backend. No GPU toolkit is baked in beyond that -
inference backends (llama.cpp, sd.cpp, FastFlowLM) are downloaded at runtime
by Kyserai itself, matched to the accelerator that KyserOS publishes via CDI
(`nvidia.com/gpu`, `amd.com/gpu=all`, `intel.com/gpu=all`).

## Container build

The [Dockerfile](Dockerfile) builds Kyserai from the sibling `kyserai`
checkout, supplied as the named build context `kyserai`:

```sh
docker buildx build \
    --build-context kyserai=../kyserai \
    --build-arg GPU_VARIANT=nvidia \
    -t kyserai:nvidia .
```

`GPU_VARIANT` is one of `nvidia`, `amd`, `intel`. Local builds require the
`kyserai` repository checked out next to this one.

## CI build

`.github/workflows/build.yml` builds the three variants from the pinned
kyserai ref as a build check. Nothing is pushed to a registry: images load
into the runner's local docker as `kyserai:<kyserai-ref>-<variant>` and
`kyserai:<variant>` and are discarded with the job. Deployment images come
from local builds (see above) or from mirroring the built images to wherever
KyserOS loads them from.

## Versioning

KyserOS package versions use `<kyserai-release>-kyseros.<revision>`. All
three variants are currently `v10.25.5-kyseros.1`, based on Kyserai
`v10.25.5`. Bump the version together with the `KYSERAI_REF` pin in
`build.yml` and the tags in each manifest.

## Publishing

KyserOS's catalog imports each manifest from this repository by an immutable
git tag. The app publisher uploads the matching relative `icon.png` to the
KyserOS CDN and stores the assembled catalog entry in PostgreSQL. No KyserOS
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
