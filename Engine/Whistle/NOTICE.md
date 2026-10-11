# Model attribution

Whistle model weights: Cactus Compute,
[pinned model card](https://huggingface.co/Cactus-Compute/whistle/blob/ca5287601bef25af26dcf2e1b2bdc0843a7c19e5/README.md).
The card declares [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
The app downloads the original archive without modifying its weights.

The Swift implementation in this package is Murmur's native implementation of
the evaluated graph and cache policy. It does not bundle Needle's inference
library or claim to reproduce the upstream runtime's streaming or quality guarantees.
