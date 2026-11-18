# Third-Party Components and Notice Index

This file is an index to third-party license, notice, exception, provenance, and corresponding-source material distributed with or prepared for this SDK. It does not replace any component's original license or notice and does not apply one license to the SDK as a whole.

## Delivery categories

- **SDK-carried components:** Any third-party source or prebuilt directory physically included in a release archive. Its original license, copyright, SPDX and notice material must remain with that archive.
- **buildenv-managed components:** components listed in `tools/kernel-environment/sources.lock`. A minimal release may omit their installed directories; `buildenv` then obtains the locked official source/archive, validates it and installs it locally. If those directories or download caches are included in a release, they are distributed components and their redistribution obligations apply directly.
- **Docker/apt components:** `docker_env/Dockerfile` builds from `ubuntu:22.04` and installs Ubuntu/PPA packages. This SDK distributes the Docker recipe, not a prebuilt image. Anyone distributing a prebuilt image must provide the package-level license and corresponding-source material required by that image.

Automatic download does not remove license or attribution obligations. The release owner must bind notices and any corresponding-source offer or delivery to the exact SDK contents.

## buildenv-managed locked components

The authoritative machine-readable versions and digests are in `tools/kernel-environment/sources.lock`.

| Component | Official source | Locked revision/version | Installed path | License / notice evidence |
|---|---|---|---|---|
| CodeLinaro msm-kernel | `https://git.codelinaro.org/clo/la/kernel/msm-5.15.git` | `f278c736182df6de50199aee950bcfc9ad4e9eab`, followed by the SDK six-Patch series | `kernel/msm-kernel` | Kernel `COPYING` and file SPDX identifiers; Patch provenance is documented separately |
| Kernel build framework | `https://git.codelinaro.org/clo/la/kernel/build.git` | `0868e657b69ac0faae74ccde795360b9b3a0b645` | `kernel/build/kernel` | component `LICENSE`, `MODULE_LICENSE_APACHE2`, `METADATA` |
| Bazel common rules | `https://git.codelinaro.org/clo/la/kernel_platform/build/bazel_common_rules.git` | `0b71409dd6fabfb2b8853cb611940b4a1a748f28` | `kernel/build/bazel_common_rules` | upstream/file-level license material; release copy must retain it |
| GCC host sysroot | `https://git.codelinaro.org/clo/la/kernelplatform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8.git` | `369c42eaba15b5b6ca44dc16745b2ff44511a043` | `kernel/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8` | component `NOTICE`, `MODULE_LICENSE_GPL`, and `LICENSES/GCC-Host*` |
| Clang prebuilt | `https://git.codelinaro.org/clo/la/kernelplatform/prebuilts-master/clang/host/linux-x86.git` | `b75008e4544bc723b147032b2dbcbc85ef54365f`; clang-r450784e, Android build 8508608 | `kernel/prebuilts/clang/host/linux-x86` | component `NOTICE`, Apache/BSD/MIT module license files and embedded LGPL/Python notices; redistribution review remains required |
| AOSP/GNU build-tools | `https://git.codelinaro.org/clo/la/kernel_platform/prebuilts/build-tools.git` | `8999a75f00aa303c51f07f27ea751719ee3cc065` | `kernel/prebuilts/build-tools` | mixed licenses; mapped groups below plus component `METADATA`/manifest |
| Kernel build tools | `https://git.codelinaro.org/clo/la/kernel/prebuilts/build-tools.git` | `e979ba5e4295e4c9761e1f49b8f0ab6848ad146f` | `kernel/prebuilts/kernel-build-tools` | mixed licenses; seven mapped groups below; remaining bundle requires further mapping |
| Android NDK r23b | `https://dl.google.com/android/repository/android-ndk-r23b-linux.zip` | 23.1.7779620; archive SHA256 `c6e97f9c8cfe5b7be0a9e6c15af8e7a179475b7ded23e2d1c1fa0945d6fb4382` | `kernel/prebuilts/ndk-r23` | component `NOTICE`, `NOTICE.toolchain`, sysroot notices; exact provenance remains partial for compiler-rt, zlib and kernel-headers |
| NDK integration metadata | `https://git.codelinaro.org/clo/la/kernel_platform/toolchain/prebuilts/ndk/r23.git` | `93532f3052c14fbb337ff57d5732128dc7481ee6` (`Android.mk`) | `kernel/prebuilts/ndk-r23/Android.mk` | follows the source file's upstream notices |

## kernel-build-tools

| Component | Distributed path | Version | License | Exact source revision | License material | Notice / exception | Corresponding source group | Provenance |
|---|---|---|---|---|---|---|---|---|
| DTC / libfdt | `kernel/prebuilts/kernel-build-tools/linux-x86/bin/dtc` | Android DTC 1.6.0 build | GPL-2.0-or-later; libfdt GPL/BSD dual path | `f500e27127cc8f2e9345fceedf2cef604eb38c9d` | `LICENSES/GPL-2.0-only.txt`; `LICENSES/BSD-2-Clause.txt` | `LICENSES/DTC-kernel-build-tools-README.license.txt` | `kernel-build-tools/dtc` | `kernel/prebuilts/kernel-build-tools/manifest.xml` |
| kmod / depmod | `kernel/prebuilts/kernel-build-tools/linux-x86/bin/depmod` | kmod 26 | GPL-2.0-or-later tools; LGPL-2.1-or-later library | `b748b53013964743132f5296d7f21377af939383` | `LICENSES/GPL-2.0-only.txt`; `LICENSES/LGPL-2.1.txt` | `LICENSES/kmod-NOTICE.txt` | `kernel-build-tools/kmod` | bundle manifest |
| e2fsprogs | `kernel/prebuilts/kernel-build-tools/linux-x86/bin/{e2fsck,e2fsdroid,mke2fs,tune2fs}` | 1.46.2 Android snapshot | GPL-2.0; Library GPL v2; BSD/MIT sublibraries | `b0470324bb553858a02569058f133aa536b379ed` | `LICENSES/GPL-2.0-only.txt` | `LICENSES/e2fsprogs-NOTICE.txt`; `LICENSES/e2fsprogs-libuuid-COPYING.txt` | `kernel-build-tools/e2fsprogs` | bundle manifest |
| dwarves / pahole | `kernel/prebuilts/kernel-build-tools/linux-x86/bin/pahole` | dwarves 1.23 | GPL-2.0-only | `962126d1dade6b7968b588aab60c9193eeaa68ef` | `LICENSES/GPL-2.0-only.txt` | no separate upstream notice found; this row supplies attribution | `kernel-build-tools/dwarves` | bundle manifest |
| erofs-utils | `kernel/prebuilts/kernel-build-tools/linux-x86/bin/{mkfs.erofs,fsck.erofs}` | manifest-pinned snapshot | GPL-2.0-or-later; liberofs GPL or Apache-2.0 | `559a5b18dcb3297cbd6d2e47c77fde514350930a` | `LICENSES/GPL-2.0-only.txt`; `LICENSES/Apache-2.0.txt` | `LICENSES/erofs-utils-COPYING.txt` | `kernel-build-tools/erofs-utils` | bundle manifest |
| libabigail | `kernel/prebuilts/kernel-build-tools/linux-x86/bin/{abidiff,abidw,abitidy}` | 2.1.0 AOSP build | Apache-2.0 WITH LLVM-exception | `b0be93d8d82d1f40091823c4bd35711190d16762` | `LICENSES/libabigail-LICENSE.txt` | `LICENSES/libabigail-license-change-2020.txt` | `kernel-build-tools/libabigail` | bundle manifest |
| SWIG | `kernel/prebuilts/kernel-build-tools/linux-x86/bin/swig` and library data | 4.0.1 | GPL-3.0-or-later plus SWIG special terms and university licenses | `0ffab894f917fcbbd031eaab870fbabaefe5daaa` | `LICENSES/GPL-3.0.txt`; `LICENSES/SWIG-LICENSE.txt` | `LICENSES/SWIG-LICENSE-UNIVERSITIES.txt`; `LICENSES/SWIG-COPYRIGHT.txt` | `kernel-build-tools/swig` | bundle manifest |

The remaining kernel-build-tools bundle is outside these seven completed source groups. This index does not claim a new file-level source mapping for that remainder.

## AOSP/GNU build-tools

| Component | Distributed path | Version | License | Exact source revision | License material | Notice / exception | Corresponding source group | Provenance |
|---|---|---|---|---|---|---|---|---|
| GNU Make | `kernel/prebuilts/build-tools/linux-x86/bin/make` | 4.3 | GPL-3.0-or-later | `7f1b28cb868e94502c5c97dcd9bbe357853f0542` | `LICENSES/GPL-3.0.txt` | no extra notice required | `build-tools/make` | `kernel/prebuilts/build-tools/manifest.xml` |
| GNU Bison | `kernel/prebuilts/build-tools/linux-x86/bin/bison` and `kernel/prebuilts/build-tools/common/bison/skeletons/` | 3.8.2 | GPL-3.0-or-later WITH parser skeleton exception | `d868ebf0b94600d99735f2bd4a77bc9245ce11c4` | `LICENSES/GPL-3.0.txt` | No official standalone exception file exists. Complete official exception source: `kernel/prebuilts/build-tools/common/bison/skeletons/bison.m4`, SHA256 `a3056074b9d6da3866e4dff3d8fba2b9d81d1ca2ca74920718586822d60df767`, byte-identical to exact source `data/skeletons/bison.m4`. It applies to generated parser/skeleton output carrying the emitted special-exception notice. | `build-tools/bison` | bundle manifest; exact-source comparison; **CLOSED** |
| GNU M4 | `kernel/prebuilts/build-tools/linux-x86/bin/m4` | 1.4.19 | GPL-3.0-or-later | `999e923272bc2cedab2abcd9206e449b91635e3e` | `LICENSES/GPL-3.0.txt` | no extra notice required | `build-tools/m4` | bundle manifest |
| XZ Utils | `kernel/prebuilts/build-tools/linux-x86/bin/xz` | 5.2.5 | public domain; LGPL-2.1-or-later; ancillary GPLv2/GPLv3 | `e953aba95e0060876d5969cc9322cf2dbb5e2cf5` | `LICENSES/LGPL-2.1.txt`; `LICENSES/GPL-2.0-only.txt`; `LICENSES/GPL-3.0.txt` | `LICENSES/XZ-Utils-COPYING.txt` | `build-tools/xz` | bundle manifest |

The current locked build-tools bundle revision is `8999a75f00aa303c51f07f27ea751719ee3cc065`. Bundle revision alone is not a substitute for the individual source revisions above, and this index does not extend the completed mapping beyond these four GNU groups.

## GCC Host

| Component | Distributed path | Version | License | Exact source revision / archive SHA | License material | Notice / exception | Corresponding source group | Provenance |
|---|---|---|---|---|---|---|---|---|
| GCC 4.8 / glibc 2.17 Host bundle | `kernel/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8` | GCC 4.8.3 plus Ubuntu Raring sysroot / eglibc 2.17 | mixed GPL/LGPL/GCC exception/package-specific terms | exact revisions in `metadata/TOOLCHAIN_SOURCES`; exact package versions/checksums in `metadata/PACKAGE_SOURCES` | `LICENSES/GPL-3.0.txt`; `LICENSES/LGPL-2.1.txt`; original component files under `LICENSES/GCC-Host/` | distributed bundle `NOTICE`; `LICENSES/GCC-Runtime-Library-Exception-3.1.txt`; `LICENSES/GCC-Host-eglibc-2.17-LICENSES.txt`; `LICENSES/GCC-Host-Third-Party-NOTICES.md` | `gcc-host-4.8` | exact source/package copyright and license material installed; **LICENSE/NOTICE CLOSED** |


## Retained toolchain notices

| Component | Distributed path | Version | License / notice material | Source-delivery status |
|---|---|---|---|---|
| clang-r450784e | `kernel/prebuilts/clang/host/linux-x86/clang-r450784e` | Clang 14.0.7 r450784e | component-local `NOTICE`, LLVM `LICENSE.TXT`, `LGPL-2.1.txt`, Python/pip/setuptools licenses, manifest and source-info | Existing report conclusion retained; no new source mapping asserted in this assembly |
| Android NDK r23b | `kernel/prebuilts/ndk-r23` | 23.1.7779620 | component-local `NOTICE`, `NOTICE.toolchain`, and sysroot `NOTICE` | **NO_COPYLEFT_SOURCE_GAP_FOUND:** the actual 2431-file trimmed package contains no identified distributed GPL/LGPL/copyleft component with an unmet corresponding-source obligation. GPL/LGPL texts in `NOTICE.toolchain` cover absent complete Host toolchain components. Provenance is **PARTIAL**: exact revisions remain UNKNOWN for `platform/external/compiler-rt`, `platform/external/zlib`, and `platform/external/kernel-headers`. |

## Delivery note

The former root `libs/` runtime and its DT-tool consumers are no longer distributed with this system-only SDK. Their license and notice files remain archived in `docs/LICENSES/` for provenance.

The kernel-build-tools remainder, embedded Clang assets, and the three NDK provenance gaps identified above remain **TO BE VERIFIED** before claiming a complete component-by-component source mapping. Corresponding source information is maintained separately for release compliance. The release owner must bind any required source delivery to the exact SDK release. The formal delivery channel is not decided by this notice index.
