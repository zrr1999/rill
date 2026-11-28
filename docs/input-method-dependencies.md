# Rill input method runtime notices

The macOS frontend is implemented in Swift/AppKit using InputMethodKit and the librime C API. It does not contain Squirrel frontend code or require a Squirrel installation. Public default data is bundled as described below. Personal Rime schemas, dictionaries, Lua scripts, language models and user databases can optionally be imported on the user's machine; personal files are never part of this repository or app distribution.

## Independent default data

`scripts/input_method_data_manifest.json` pins the following public assets and SHA-256 values. `assemble_input_method.py` checks every downloaded or cached asset before extracting data into the input method's signed Resources directory. Install-time deployment uses only those bundled files and the packaged runtime; it does not download data or read an installed Squirrel application.

| Data | Source | License |
| --- | --- | --- |
| Simplified Pinyin dictionary, revision `0c6861ef7420ee780270ca6d993d18d4101049d0` | [rime/rime-pinyin-simp](https://github.com/rime/rime-pinyin-simp/tree/0c6861ef7420ee780270ca6d993d18d4101049d0), `pinyin_simp.dict.yaml` | Apache-2.0, PinyinSimp.txt (including upstream AUTHORS) |
| Standard OpenCC 1.4.2 dictionaries/configs | [BYVoid/OpenCC on PyPI](https://pypi.org/project/OpenCC/1.4.2/), pinned macOS CPython 3.12 wheel | Apache-2.0, OpenCC.txt and OpenCC-AUTHORS.txt |

The dictionary derives from Android Pinyin IME and is maintained by the Rime contributors. Its source is 1,266,216 bytes, pinned to SHA-256 `e341598343a0f0f2035bb1aafc34a7f3bb7887deeecb3f60796262aaa2983e6b`. Rill supplies a small full-pinyin schema with six candidates, punctuation and local user-frequency learning in `Resources/InputMethodDefaultProfile/`. The default does not contain Wanxiang dictionaries, Lua scripts or an LTS language model. Packaging never downloads the model. The runtime plugins remain available for optionally imported personal profiles; imported language models are copied locally, never downloaded or added to an app distribution.

Only architecture-independent OpenCC `.json` and `.ocd2` data are extracted from the wheel; its Python code and native binaries are neither installed nor shipped. These standard files supplement imported profiles without overwriting user files. The original licenses are copied into `Resources/Licenses/` alongside these notices.

## Pinned runtime

The package uses the official [librime 1.18.0 release](https://github.com/rime/librime/releases/tag/1.18.0). The [runtime manifest](../scripts/rime_runtime_manifest.json) pins the universal macOS archive and the SHA-256 of each original file. Packaging verifies them before copying and signing.

The archive's `version-info.txt` identifies these plugin source revisions:

| Component | Revision | License copy |
| --- | --- | --- |
| [librime](https://github.com/rime/librime/tree/1c0a468e7fff2b2763400abe1e892ed66d08b00e) | 1c0a468 | librime.txt, BSD-3-Clause |
| [librime-lua](https://github.com/hchunhui/librime-lua/tree/6da5d6c) | 6da5d6c | librime-lua.txt, BSD-3-Clause |
| [librime-octagram](https://github.com/lotem/librime-octagram/tree/57d18b9) | 57d18b9 | librime-octagram.txt, BSD-3-Clause |
| [librime-predict](https://github.com/rime/librime-predict/tree/920bd41) | 920bd41 | librime-predict.txt, BSD-3-Clause |

## Bundled dependency licenses

The input method ships the notices from `Resources/InputMethodLicenses/` in `RillInputMethod.app/Contents/Resources/Licenses/`.

| Dependency | Revision | License copy |
| --- | --- | --- |
| [spdlog](https://github.com/gabime/spdlog/tree/79524ddd08a4ec981b7fea76afd08ee05f83755d) and its bundled fmt | 79524dd | spdlog.txt and fmt.txt |
| [LevelDB](https://github.com/google/leveldb/tree/bb74ef739973a70ca9f0d90788a1da89b788c0ad) | bb74ef7 | leveldb.txt |
| [yaml-cpp](https://github.com/jbeder/yaml-cpp/tree/56e3bb550c91fd7005566f19c079cb7a503223cf) | 56e3bb5 | yaml-cpp.txt |
| [marisa-trie](https://github.com/s-yata/marisa-trie/tree/3e87d53b78e15f2f43783d5e376561a8c9722051) | 3e87d53 | marisa-trie.txt |
| [OpenCC](https://github.com/BYVoid/OpenCC/tree/025f371dc76b598d77384fbdab90c937471844d8) | 025f371 (1.4.2) | OpenCC.txt |
| [OpenCC's bundled Darts, MARISA and RapidJSON](https://github.com/BYVoid/OpenCC/tree/025f371dc76b598d77384fbdab90c937471844d8/deps) | 0.32h, 0.3.1 and 1.1.0 | darts-clone.txt, marisa-trie.txt and RapidJSON.txt |
| [Boost](https://github.com/boostorg/boost/tree/boost-1.92.0) | 1.92.0 | Boost.txt |
| [Lua](https://github.com/lua/lua/blob/v5.4.9/lua.h) | 5.4.9 (binary version string) | Lua.txt |

The upstream release includes no source revision for its separately downloaded Lua tree; the Lua copyright is retained from the bundled version. The checksum pin fixes the binary, including that dependency. The original Rime C headers in `Sources/CRime/include/` retain their upstream notices.
