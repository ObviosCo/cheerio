# Third-party notices

Cheerio's own source code is MIT licensed (see [LICENSE](LICENSE)). The pieces below are
not, and their notices must accompany any redistributed build. This file is bundled into
`Cheerio.app` so that a build carries its attribution with it.

## Sortformer v2.1 — speaker-diarization model

- **Streaming Sortformer** © NVIDIA Corporation, licensed under
  [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).
  Upstream model: [nvidia/diar_streaming_sortformer_4spk-v2](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2)
- Core ML conversion by [FluidInference](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml),
  also published under CC BY 4.0.
- Changes from the original: converted to Core ML and palettized to 6-bit for the
  Apple Neural Engine.
- The model is not committed to this repository (a ~93 MB size decision, not a license
  requirement). `Scripts/fetch-models.sh` downloads it at build time against pinned
  SHA-256 hashes, and it ships inside the built app.

## FluidAudio — Swift diarization framework

[FluidAudio](https://github.com/FluidInference/FluidAudio) © FluidInference, licensed under
the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). Linked as a Swift
package, pinned to an exact version, and compiled into the built app.
