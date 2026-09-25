# Rill input method runtime notices

The macOS frontend is implemented in Swift/AppKit using InputMethodKit and the
librime C API. It does not contain Squirrel frontend code or require a Squirrel
installation. Public default data is bundled as described below. Personal Rime
schemas, dictionaries, Lua scripts, language models and user databases can
optionally be imported on the user's machine; personal files are never part of
this repository or app distribution.

## Independent default data

`scripts/input_method_data_manifest.json` pins the following public assets and
SHA-256 values. `prepare_input_method_data.py` checks every downloaded or cached
asset before extracting data into the input method's signed Resources directory.
Install-time deployment uses only those bundled files and the packaged runtime;
it does not download data or read an installed Squirrel application.

| Data | Source | License |
| --- | --- | --- |
| Simplified Pinyin dictionary, revision `0c6861ef7420ee780270ca6d993d18d4101049d0` | [rime/rime-pinyin-simp](https://github.com/rime/rime-pinyin-simp/tree/0c6861ef7420ee780270ca6d993d18d4101049d0), `pinyin_simp.dict.yaml` | Apache-2.0, PinyinSimp.txt (including upstream AUTHORS) |
| Standard OpenCC 1.1.9 dictionaries/configs | [BYVoid/OpenCC on PyPI](https://pypi.org/project/OpenCC/1.1.9/), pinned macOS CPython 3.12 wheel | Apache-2.0, OpenCC.txt |

The dictionary derives from Android Pinyin IME and is maintained by the Rime
contributors. Its source is 1,266,216 bytes, pinned to SHA-256
`e341598343a0f0f2035bb1aafc34a7f3bb7887deeecb3f60796262aaa2983e6b`.
Rill supplies a small full-pinyin schema with six candidates, punctuation and
local user-frequency learning in `Resources/InputMethodDefaultProfile/`.
The default does not contain Wanxiang dictionaries, Lua scripts or an LTS language
model. Packaging never downloads the model. The runtime plugins remain available
for optionally imported personal profiles; imported language models are copied
locally, never downloaded or added to an app distribution.

Only architecture-independent OpenCC `.json` and `.ocd2` data are extracted from
the wheel; its Python code and native binaries are neither installed nor shipped.
These standard files supplement imported profiles without overwriting user files.
The original licenses are copied into `Resources/Licenses/` alongside these notices.

## Pinned runtime

The package uses the official [librime 1.16.0 release](https://github.com/rime/librime/releases/tag/1.16.0),
asset `rime-a251145-macOS-universal.tar.bz2`, SHA-256
`e4c9a8767a456f2550f1242921b7656c6e6be088c89a921274bd5d4404f58b99`.
`scripts/rime_runtime_manifest.json` records the individual original file hashes.
Packaging verifies the archive and all cached runtime files before copying and signing.

The archive's `version-info.txt` identifies these plugin source revisions:

| Component | Revision | License copy |
| --- | --- | --- |
| [librime](https://github.com/rime/librime/tree/a251145) | a251145 | librime.txt, BSD-3-Clause |
| [librime-lua](https://github.com/hchunhui/librime-lua/tree/68f9c36) | 68f9c36 | librime-lua.txt, BSD-3-Clause |
| [librime-octagram](https://github.com/lotem/librime-octagram/tree/dfcc151) | dfcc151 | librime-octagram.txt, GPL-3.0 |
| [librime-predict](https://github.com/rime/librime-predict/tree/920bd41) | 920bd41 | librime-predict.txt, BSD-3-Clause |

The pinned Octagram revision uses GPL-3.0; a newer branch's different license
must not be substituted for the license of the shipped binary. This integration
is for the personal-use scope. Public distribution needs a compatible project
license and the corresponding source obligations resolved before release.

## Bundled dependency licenses

Verbatim licenses are kept in `Resources/InputMethodLicenses/` and copied into
`RillInputMethod.app/Contents/Resources/Licenses/`. The release build's dependency
submodules are:

| Dependency | Revision | License copy |
| --- | --- | --- |
| [glog](https://github.com/google/glog/tree/7b134a5c82c0c0b5698bb6bf7a835b230c5638e4) | 7b134a5 | glog.txt |
| [LevelDB](https://github.com/google/leveldb/tree/99b3c03b3284f5886f9ef9a4ef703d57373e61be) | 99b3c03 | leveldb.txt |
| [yaml-cpp](https://github.com/jbeder/yaml-cpp/tree/2f86d13775d119edbb69af52e5f566fd65c6953b) | 2f86d13 | yaml-cpp.txt |
| [marisa-trie](https://github.com/s-yata/marisa-trie/tree/3e87d53b78e15f2f43783d5e376561a8c9722051) | 3e87d53 | marisa-trie.txt |
| [OpenCC](https://github.com/BYVoid/OpenCC/tree/556ed22496d650bd0b13b6c163be9814637970ae) | 556ed22 | OpenCC.txt |
| [Boost](https://github.com/boostorg/boost/tree/boost-1.89.0) | 1.89.0 | Boost.txt |
| [Lua](https://www.lua.org/license.html) | 5.4.8 (binary version string) | Lua.txt |

The upstream release includes no source revision for its separately downloaded
Lua tree; the Lua copyright is retained from the bundled version. The checksum
pin fixes the binary, including that dependency. The original Rime C headers
in `Sources/CRime/include/` retain their upstream notices.
