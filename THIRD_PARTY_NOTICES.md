# Third-party notices

Siri AI+ is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). It includes or builds on the third-party work listed below, which keeps its own license.

## Included in this repository

### rizzo-pii

The privacy shield (`Sources/SiriCore/Privacy/`) is a Swift port of the detection pipeline of [rizzo-pii](https://github.com/Rizzo-AI-Academy/rizzo-pii) (regular expressions, checksums and post-processing). `Support/rizzo-pii/` contains the scripts that download the rizzo-pii model from Hugging Face and convert it to Core ML on your Mac. Author: [Simone Rizzo](https://github.com/simone-rizzo), Rizzo AI Academy.

```text
MIT License

Copyright (c) 2026 Simone Rizzo — Rizzo AI Academy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### rizzo-flow

The fast decisions (`Sources/SiriCore/Decisions/`) are a Swift port of the typed decision layer of [rizzo-flow](https://github.com/rizzo-ai-academy/rizzo-flow): the `spark-decisions-v3` prompt (`prompts.py`) and the decoding of the answers (`decisions.py`: candidates, softmax, status and statistics). `Support/eval/rizzo-flow-smoke.jsonl` is copied unchanged from its `benchmarks/smoke.jsonl`. Author: [Simone Rizzo](https://github.com/simone-rizzo), Rizzo AI Academy. Attribution is also in [NOTICE](NOTICE).

```text
Copyright 2026 Simone Rizzo — Rizzo AI Academy

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

## Downloaded or installed on your Mac, not included here

Siri AI+ can download or install these components when you ask it to. They are not redistributed in this repository, and each one keeps its own license.

| Component | Author | License | Used for |
|---|---|---|---|
| [rizzo-pii-0.3B](https://huggingface.co/rizzoaiacademy/rizzo-pii-0.3B) model | Simone Rizzo, Rizzo AI Academy | MIT | Privacy shield, installed by `Support/rizzo-pii/install.sh` |
| [rizzo-flow](https://huggingface.co/rizzoaiacademy/rizzo-flow) model (a LoRA fine-tune of Spark-X2.5-4B) | Simone Rizzo, Rizzo AI Academy | Apache-2.0 | Fast decisions, downloaded from Settings › Models |
| [ds4](https://github.com/antirez/ds4) | Salvatore Sanfilippo ([@antirez](https://github.com/antirez)) | MIT | Local DeepSeek V4 models on Macs with 96 GB or more |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | ggml-org | MIT | Runs Gemma and rizzo-flow on your Mac, installed with Homebrew |
| [Gemma 4](https://ai.google.dev/gemma) GGUF files by ggml-org | Google | Google's terms for Gemma | Local models |
| [Codex CLI](https://github.com/openai/codex) | OpenAI | Its own license | ChatGPT with your subscription |
| [Claude Code](https://claude.com/claude-code) | Anthropic | Its own terms | Claude with your subscription |
| [Open-Meteo](https://open-meteo.com) weather data | Open-Meteo | CC BY 4.0 | Weather on the Home screen |

Siri AI+ is an independent project and is not affiliated with, endorsed by, or sponsored by Apple Inc. Siri, Apple Intelligence, Xcode, Safari, Pages, Numbers and Keynote are trademarks of Apple Inc.
