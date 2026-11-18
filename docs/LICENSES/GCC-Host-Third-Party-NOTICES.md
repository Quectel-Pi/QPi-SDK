# GCC 4.8 / glibc 2.17 Host bundle: third-party license index

This file indexes original license and copyright materials for the distributed Host bundle at:

`kernel/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8`

It does not replace, paraphrase, or modify those original materials. The bundle's own `NOTICE` is retained at its original path; it contains the GNU GPL version 2 text but is not an aggregate component attribution notice. Exact source revisions, package versions, checksums, build scripts, and patches are maintained separately for release compliance.

## AOSP toolchain sources

| Component | Exact revision/version | Distributed content | License evidence | Original material installed under `LICENSES/GCC-Host/` | Corresponding source |
|---|---|---|---|---|---|
| GNU binutils | `binutils-2.27`; project revision `d42268bd795ae78a45e6a225ee77c5617777223a` | BFD/opcodes libraries, headers, and toolchain support | mixed GPL/LGPL and subcomponent terms in the exact source `COPYING*` files | `aosp/binutils-2.27/` | `gcc-host-4.8/aosp-toolchain/binutils` |
| GCC | `gcc-4.8.3`; project revision `f236b449daeff96112b586ed4f06980e88012d39` | compiler runtime libraries, headers, and toolchain support | GPLv3+, LGPLv3+, GCC Runtime Library Exception, and libsanitizer terms in the exact source | `aosp/gcc-4.8.3/` | `gcc-host-4.8/aosp-toolchain/gcc` |
| Toolchain build support | project revision `58be6006bb71abb97d7cdff7be3e73d55bbc22b8` | scripts used to construct the bundle/sysroot | GPLv2 and LGPLv2.1 texts carried by the exact source | `aosp/toolchain-build/` | `gcc-host-4.8/aosp-toolchain/build` |
| GMP | `5.0.5`; project revision `b2acd5dbf47868ac5b5bc844e16d2cadcbd4c810` | `libgmp.a` and headers | GPLv3 / LGPLv3 dual-license materials in the exact archive | `aosp/gmp-5.0.5/` | `gcc-host-4.8/aosp-toolchain/gmp/gmp-5.0.5.tar.bz2` |
| MPFR | `3.1.1`; project revision `de979fc377db766591e7feaf052f0de59be46e76` | `libmpfr.a` and headers | LGPLv3+ and GPLv3 texts in the exact archive | `aosp/mpfr-3.1.1/` | `gcc-host-4.8/aosp-toolchain/mpfr/mpfr-3.1.1.tar.bz2` |
| MPC | `1.0.1`; project revision `835d16e92eed875638a8b5d552034c3b1aae045b` | `libmpc.a` and headers | LGPLv3+ text in the exact archive | `aosp/mpc-1.0.1/` | `gcc-host-4.8/aosp-toolchain/mpc/mpc-1.0.1.tar.gz` |
| ISL | `0.11.1`; project revision `0ccf95726af8ce58ad61ff474addbce3a31ba99c` | `libisl.a` and headers | permissive license in the exact archive `LICENSE` | `aosp/isl-0.11.1/` | `gcc-host-4.8/aosp-toolchain/isl/isl-0.11.1.tar.bz2` |
| CLooG | `0.18.0`; project revision `604793eab97d360aef729f064674569ee6dbf3e1` | `libcloog-isl.a` and headers | LGPLv2.1+ and bundled ISL terms in the exact source | `aosp/cloog-0.18.0/` | `gcc-host-4.8/aosp-toolchain/cloog` |

The applicable terms are the unmodified files in the listed directories. In particular, GCC's `COPYING.RUNTIME` is the GCC Runtime Library Exception; GCC and binutils carry multiple GPL/LGPL texts for their respective subcomponents; ISL carries its permissive license; and the remaining mathematical libraries carry their upstream license texts.

## Ubuntu Raring sysroot source packages

| Source package | Exact version | Distributed package/path | License evidence | License and copyright material | Corresponding source provenance |
|---|---|---|---|---|---|
| acl | `2.2.51-8ubuntu3` | Host sysroot ACL interfaces/libraries | LGPL-2.1 with GPL portions, per exact `debian/copyright` | `ubuntu/acl-2.2.51-8ubuntu3/` | exact `.dsc`, upstream archive, Debian archive, and checksums under `gcc-host-4.8/ubuntu-source-packages/` and `metadata/ubuntu-copyleft-source-sha256.tsv` |
| alsa-lib | `1.0.25-4ubuntu3` | Host sysroot ALSA interfaces/libraries | LGPL-2.1-or-later, with separate aServer GPL material | `ubuntu/alsa-lib-1.0.25-4ubuntu3/` | same exact-source package set and checksum manifest |
| attr | `2.4.46-8ubuntu2` | Host sysroot extended-attribute interfaces/libraries | LGPL-2.1 with GPLv2 portions, per exact `debian/copyright` | `ubuntu/attr-2.4.46-8ubuntu2/` | same exact-source package set and checksum manifest |
| audiofile | `0.3.5-1` | Host sysroot audiofile interfaces/libraries | LGPL-2+, GPL-2+, BSD-3-Clause, and file-specific terms recorded by the package | `ubuntu/audiofile-0.3.5-1/` | same exact-source package set and checksum manifest |
| eglibc | `2.17-0ubuntu5` | Host sysroot libc, loader, pthread, headers, and related objects | LGPL-2.1-or-later, GPLv2-or-later utilities, and incorporated third-party terms | `ubuntu/eglibc-2.17-0ubuntu5/`; also `../GCC-Host-eglibc-2.17-LICENSES.txt` | same exact-source package set, checksum manifest, and retained sysroot patches |
| esound | `0.2.41-10ubuntu1` | Host sysroot esound interfaces/libraries | GPLv2 daemon and LGPLv2 other components | `ubuntu/esound-0.2.41-10ubuntu1/` | same exact-source package set and checksum manifest |
| libcap2 | `2.22-1.2ubuntu2` | Host sysroot capability interfaces/libraries | BSD-style terms or GPL alternative, plus PAM-specific material | `ubuntu/libcap2-2.22-1.2ubuntu2/` | same exact-source package set and checksum manifest |
| linux | `3.8.0-19.29` | Host sysroot Linux UAPI headers | GPLv2 and file-specific exceptions/terms, per exact package copyright | `ubuntu/linux-3.8.0-19.29/` | exact `.dsc`, upstream archive, Debian diff, and checksum manifest |
| pulseaudio | `3.0-0ubuntu6` | Host sysroot PulseAudio interfaces/libraries | LGPL-2.1+ with GPL-effective server portions and recorded file-specific terms | `ubuntu/pulseaudio-3.0-0ubuntu6/` | exact `.dsc`, upstream archive, Debian archive, and checksum manifest |

Each `ubuntu/<package-version>/debian-copyright` is copied byte-for-byte from that exact unpacked Ubuntu source package. Adjacent `COPYING`, `LICENSE`, or similarly named files are copied byte-for-byte from the same exact source. These originals contain package-specific copyright notices and mixed-license details that are not present in the bundle-level GPLv2 `NOTICE`.

## Existing shared license texts

The following shared texts already distributed in `LICENSES/` remain applicable where the original component material refers to them:

- `GPL-2.0-only.txt`
- `GPL-3.0.txt`
- `LGPL-2.1.txt`
- `GCC-Runtime-Library-Exception-3.1.txt`

An expression such as “version 2.1 or later” is the component's grant; it does not require creating a rewritten “or later” license text. The exact component copyright/license files above and the standard license texts are retained together.
