# Licensing and source provenance

The restored RISC OS kernel and most guest modules in this project come from **public source files carrying Apache-2.0 licences and notices**. They are modified Acorn-derived sources, not a new operating system written entirely from scratch. Host tools and some supporting code have other licences, described below. This document identifies the material we actually use; it does not grant rights to other RISC OS releases, commercial ROM images or applications.

## Which original RISC OS source we use

The implementation baseline is the public **cleaned RISC OS 3.60 source import** preserved in the component Git repositories under [RiscOS/Sources on the 4corn GitLab mirror](https://gitlab.4corn.co.uk/RiscOS/Sources). The historical kernel/cohort commits are described upstream as “Import from cleaned 360 CD”. We exported selected revisions from those repositories and restored their original-machine paths for ARM2/MEMC1 hardware.

“Recovered” means recovered from those public version-control histories. It does **not** mean disassembled from a ROM or copied from a commercial ROM image. The maintained `src/` tree contains our patched copies. The original snapshots, manifests and restoration evidence remain in `experiments/`.

The core source references are:

| Component | Original repository and pinned revision | Licence evidence retained here |
|---|---|---|
| Kernel | [Kernel, `3da129d209b2c78d19f6c28d9a8f15cd6f1c3bfc`](https://gitlab.4corn.co.uk/RiscOS/Sources/Kernel/-/tree/3da129d209b2c78d19f6c28d9a8f15cd6f1c3bfc) | [Upstream LICENSE](src/Kernel/LICENSE) and Acorn copyright/Apache notices in files such as [s/GetAll](src/Kernel/s/GetAll) |
| Matching machine, CPU and shared headers | [HdrSrc, `c9113ab79d9ca2ccc49a9b7518911132ca9ffa1b`](https://gitlab.4corn.co.uk/RiscOS/Sources/Programmer/HdrSrc/-/tree/c9113ab79d9ca2ccc49a9b7518911132ca9ffa1b) | [Original snapshot licence](src/HdrSrc/LICENSE) and retained header notices |
| Missing public allocation/interface definitions | [HdrSrc, `403c6dd8bce92d0629634cbf57f68f43b2f30d38`](https://gitlab.4corn.co.uk/RiscOS/Sources/Programmer/HdrSrc/-/tree/403c6dd8bce92d0629634cbf57f68f43b2f30d38) | [PublicInterfaces/LICENSE](src/PublicInterfaces/LICENSE), [per-file provenance](manifests/public-interface-files.json) and the [interface assessment](licenses/restored-interfaces.md) |
| FileCore | [FileCore, `708e0ddb5a077e68690a1719038368860081e785`](https://gitlab.4corn.co.uk/RiscOS/Sources/FileSys/FileCore/-/tree/708e0ddb5a077e68690a1719038368860081e785) | [FileCore/LICENSE](src/FileCore/LICENSE) and per-file notices |
| ADFS | [ADFS, `b32ebc4dd79436ecb942c773759583cd7365b178`](https://gitlab.4corn.co.uk/RiscOS/Sources/FileSys/ADFS/ADFS/-/tree/b32ebc4dd79436ecb942c773759583cd7365b178) | [ADFS/LICENSE](src/ADFS/LICENSE) and per-file notices |

The [component inventory](manifests/components.json) gives the full repository URL, revision, role, licence explanation and restoration patches for **every maintained component**, including FileSwitch, ResourceFS, MessageTrans, Messages, TerritoryManager, UK, International and IntKey. The [kernel cohort](manifests/kernel-cohort.json) also records the matching component headers; their presence does not mean those components are included as runtime modules. The maintained Wimp, FontManager and ROMFonts are runtime implementations in the experimental desktop, identified separately from components that still supply only headers. See the [desktop source report](docs/desktop-source/RESULTS.md) and [tested desktop scope](docs/desktop-startup/RESULTS.md).

The separate public-interface pin supplies missing definitions; it is not a replacement kernel or a later machine workspace. The project is not based on RO26. **RISC OS 3.11 remains our compatibility target**, but we are not claiming to have obtained or relicensed a complete 3.11 ROM distribution.

## What the retained notices and assessments mean

For a recovered component, we record four things separately:

1. **Where the bytes came from:** upstream repository, exact Git revision and file hashes.
2. **What permission accompanied them:** the upstream `LICENSE` file where present, plus copyright and licence notices inside the source files. For example, the kernel's `s/GetAll` retains Acorn Computers' copyright notice and expressly identifies Apache License 2.0.
3. **What we changed:** the recorded [restoration patch series](patches/restoration/series), source change notices, and subsequent Git history of the maintained tree. Keeping Acorn's notices does not imply Acorn wrote our changes.
4. **Which resources and exceptions were reviewed:** message files, fonts, sprites and host dependencies are identified in the component assessments rather than assumed to share a licence merely because they appear in a public repository.

Thus, “retained notices” means we preserve the actual upstream copyright, attribution and licence statements. “Assessment” means the project's documented examination of those statements and the relevant resource provenance. It is **not** a new licence granted by this project, nor a claim that public availability alone permits redistribution.

Apache-2.0 permits modification and distribution of covered source and object code subject to its conditions. Those include supplying the licence, retaining applicable source notices, identifying modified files, and carrying forward applicable upstream NOTICE attributions where supplied. It does not grant general trademark rights. The controlling terms are the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0), also supplied [locally](licenses/Apache-2.0).

## Resources and component-specific qualifications

- **Fonts, help, messages and sprite data:** the current ROM builds these from identified public source inputs. The kernel bitmap font is `src/Kernel/s/vdu/vdufontl1`; International supplies its public alphabet tables. TerritoryManager's SystemDisc sprite comes from its pinned public source asset and is recompressed with the public Squash algorithms. None is extracted from a ROM image. This does not establish visual or behavioural identity with 3.11.
- **Selected desktop resources:** the [asset manifest](manifests/desktop-assets.json) records 39 exact public Wimp/FontManager/ROMFonts inputs (592,677 bytes), selected using the original UK build recipes. Component Apache-2.0 licences are retained; these native resources do not have separate file-level licence notices. The [desktop assessment](licenses/desktop/ASSESSMENT.md) records that distinction, format/provenance checks and excluded assets. They are not ROM extracts or a claim of RISC OS 3.11 visual identity.
- **Rendering-provider messages:** ColourTrans and DrawMod use two additional original UK message files from the pinned cohort. The [resource record](docs/renderers/reports/resources.json) gives exact hashes and names; their component Apache-2.0 licences apply, with no separate message-file notice. SuperSampler tables are generated from the preserved Acorn Apache-2.0 BASIC algorithms, not from ROM data.
- **Software FPEmulator:** the complete [ARM vendor snapshot](https://gitlab.4corn.co.uk/RiscOS/Sources/HWSupport/FPASC/-/tree/827b16098de462b3dadc6caadf62d30ed664c926) supplies ARM core 1.13 and its coherent RISC OS wrapper. This is a later component exception because the 3.60 snapshot lacks the core. ARM files carry BSD three-clause terms; the aggregate [upstream licence](src/FPEmulator/LICENSE) also supplies Apache-2.0 terms for the remaining distribution. The [assessment](licenses/FPEmulator-assessment.md) identifies the exact coverage and notices. Binary distributions must include the ARM copyright, conditions and disclaimer; do not describe this component as Apache-only.
- **UK territory:** the pinned [UK source, `55aa82c8862f02d9db5bb4b2a9350dc8baf97192`](https://gitlab.4corn.co.uk/RiscOS/Sources/Internat/Territory/UK/-/tree/55aa82c8862f02d9db5bb4b2a9350dc8baf97192) has explicit Acorn Apache-2.0 notices in its source and Makefile, but no standalone `LICENSE` at that revision. Its plain message resource has no separate file-level notice. We preserve that distinction. The [UK assessment](licenses/UK-assessment.md) and [resource comparison](licenses/uk-resource-provenance/provenance.json) record corroboration from a later Apache-licensed public TerritoryModule snapshot. That comparison supports provenance; it does not itself grant a new licence to the old resource, and no later runtime bytes were substituted.
- **Squash:** Jon Thackray's portable compressor/decompressor and associated definitions carry the [BSD three-clause notice](licenses/Squash-BSD3). Other wrappers retain their own notices. These algorithms prepare the sprite on the build host and now also form the restored guest Squash SWIs. The original Apache-licensed module wrapper is built from its pinned source; see the utility section below.

These facts support the project's recorded licensing position for its identified current inputs. They are not blanket clearance for future desktop assets, additional modules, trademarks, games or other third-party payloads. Each addition needs its own source and licence record.

## Project code and host dependencies

New project restoration code, build scripts, test harnesses and original diagnostic media are Apache-2.0 unless a file states otherwise. Existing upstream licences and notices continue to apply to modified files.

| Host dependency | Terms and source | Relationship to the guest ROM |
|---|---|---|
| AsAsm and observation patches | [Pinned GCCSDK source](https://github.com/riscos-dot-info/gccsdk/tree/212d4567f007e7d30f4af3d6e1919a3d8a115b1c/tools/asasm), GPL-2.0-or-later; source archive and patches in `third_party/` | Produces/verifies ARM objects; no host assembler code is joined into the ROM |
| ELF toolchain / decaof | Same pinned archive; retain its per-file BSD-style and other supplied notices | Host object-file support |
| Tokenise | Public Tools/Sources/tokenise revision `d6ea854482663935562dc4c1bc2cde4bf3b570aa`; [source licence](third_party/tokenise/LICENSE), Apache-2.0 | Generates help text from identified public inputs |
| GNU M4, Autoconf, Automake and Libtool | Their own COPYING files, notices and applicable exceptions; versions/archive hashes in [toolchain manifest](manifests/toolchain.json) | Host build infrastructure |
| MacArch | Separate GPL-3.0-or-later host dependency; [licence](licenses/MacArch-GPL3), pinned core source archive and [device patch](third_party/patches/macarch-original-disc-change.patch) | Executes the ROM for tests; neither core nor native harness executable is joined into it |

The bundled archives contain source, not prebuilt host executables. If native GPL-covered tools or combined test executables are distributed later, their applicable source and notice requirements must also be met. Apple Clang/macOS SDK are installed developer prerequisites, not bundled guest components.

Do not add proprietary ROM images, resources extracted from them, or commercial application/disc payloads. Preserve original attribution and document the provenance of each new source or asset.


## ArcLibre desktop startup sources and assets

The Desktop, Filer and Switcher (TaskManager) implementations are recovered from
Acorn's publicly released source history mirrored by 4corn, using the cleaned
RISC OS 3.60 cohort:

| Component | Original source repository | Pinned revision |
| --- | --- | --- |
| Desktop | https://gitlab.4corn.co.uk/RiscOS/Sources/Desktop/Desktop | `4a444dda0d87eec121c2d2969cdaf1c842bc0e3e` |
| Filer | https://gitlab.4corn.co.uk/RiscOS/Sources/Desktop/Filer | `d2d9cf8ae3226a33e05b4be2f4e7dbb7a95ee10d` |
| Switcher | https://gitlab.4corn.co.uk/RiscOS/Sources/Desktop/Switcher | `36c0337f13d2446cc16f5d876f2944053f1eee91` |

Each component retains its original Apache-2.0 LICENSE and source notices.
`manifests/desktop-startup-inputs.json` records repository, revision, original
hash and maintained hash for every imported file, including the matching
Econet, FilerAct and DragASprit public interface headers. Those headers do not
imply inclusion of working runtime modules.

The selected native assets are Desktop's UK Messages, Filer's UK Messages and
Templates, and Switcher's UK Messages and Templates. They come directly from
those pinned public source revisions, with no ROM extraction or external asset
substitution. Their redistribution basis is the enclosing component's
Apache-2.0 release; the selected files contain no separate asset licence. The
resource builder records each asset's exact hash, file type and licence basis
in `build/desktop-startup/resources.json`. Existing copyright text is retained.
The Desktop source also contains the original welcome-screen vector artwork;
its provenance and licence are the Desktop source file itself. Apache-2.0 does
not grant trademark rights or imply Acorn endorsement. ArcLibre is the project
name; compatibility claims remain bounded by the recorded tests.

Assembly adaptations are reviewable in `patches/desktop-startup`. Reversing the
series must recover every pinned original hash. New diagnostic tasks and host
build/test code carry Apache-2.0 notices. MacArch remains a separate GPL-covered
host testing dependency and is not linked into the guest ROM.

Pinboard is additionally pinned to cleaned-3.60 revision
`128b61d89cdaea881fc8e44a482cc00a180ecc9b` from
https://gitlab.4corn.co.uk/RiscOS/Sources/Desktop/Pinboard. Its original Apache-2.0
LICENSE and notices are retained. Its UK Messages and Templates are included in
the experimental ROM under the same component-release basis as the startup
assets above. Template2D is retained as a source input but is not joined into the
ROM. No default backdrop bitmap or external wallpaper is included.


The pointer correction adds SpriteExtend 0.99 from
https://gitlab.4corn.co.uk/RiscOS/Sources/Video/Render/SprExtend at cleaned-3.60
revision `0ca1c4b36a786fced03e53e63f1524cba73ed834`. Its original Apache-2.0 licence, notices, UK Messages
and C sprite-area validator are retained. The ARM2 profile uses the retained
assembly sprite renderer; it does not include the JPEG decoder or C-generated
plotting engine. The C validator is translated to ARM2 with the same licence
and an explicit modification notice, and tested against its original C source.
All selected file hashes and adaptations are in the startup manifest and patch
series. No cursor bitmap is taken from a proprietary ROM or fabricated to mask
the missing service: SpriteExtend converts the existing public Wimp sprite.

The desktop splash identifies the project as ArcLibre and says “Derived from
the RISC OS open-source release”, separately from the original Acorn copyright
notice. This refers to the public source distribution identified above and its
pinned cleaned-3.60 cohort; it does not claim that a complete RISC OS 3.11 ROM
was released as open source. Modifications do not
remove the original authors' copyright. This describes the origin of the code,
not an Acorn release or endorsement. Original source notices remain intact;
ArcLibre changes are recorded in the patch series. See Apache-2.0 sections 4
(retaining notices and identifying modifications) and 6 (trademarks):
https://www.apache.org/licenses/LICENSE-2.0 .

ADFSFiler 0.83 and ShellCLI 0.28 are selected from the cleaned-360-CD commits in
https://gitlab.4corn.co.uk/RiscOS/Sources/FileSys/ADFS/ADFSFiler and
https://gitlab.4corn.co.uk/RiscOS/Sources/Desktop/ShellCLI . Their exact revisions
and original/current file hashes are recorded in `desktop-startup-inputs.json`.
Their Apache-2.0 licences and source notices are retained, including the selected
UK Messages and ADFSFiler Templates resources. No icons are extracted from ROM:
the existing reviewed Wimp sprite pool supplies the drive artwork. The authored
ShareD interface aliases express published SWI numbers; no OSLib implementation
or network sharing module is included. The local `references/` collection is
excluded from Git and release packages; only deliberately selected inputs under
`src/` enter the build.

Obey 0.33 and BufferManager are now runtime components, selected from
`Programmer/Obey` revision `9fd2629acfcd9125960b704c42f1b259a45840ac`
and `HWSupport/Buffers` revision `be2e051d01382492b65a1685d1f33e8ef4935444`
on the same 4corn mirror. Their Apache-2.0 licences, source notices and original
UK Messages are retained. The startup manifest records each original and
maintained hash; patches 0009–0010 contain all source adaptations. BufferManager
was previously present only as a public interface header. Its real vector and
buffer implementation now queues the kernel's mouse input. The application
floppy generated by `tests/build_desktop_app.py` is original Apache-2.0 test code.
User-supplied commercial games are private compatibility fixtures and are never
included in the source or ROM packages.

## Original-machine sound

The five sound runtimes are selected from the same cleaned-3.60 cohort:

| Component | 4corn repository under `RiscOS/Sources` | Exact revision |
| --- | --- | --- |
| Sound0 (SoundDMA) | HWSupport/Sound/Sound0 | `9bd59f38c9b7caff055eff8ff308cce832e52b47` |
| Sound1 (SoundChannels) | HWSupport/Sound/Sound1 | `8b1dec5daa1229b3da2440b7e1fa686f5163c1bc` |
| Sound2 (SoundScheduler) | HWSupport/Sound/Sound2 | `92732881e2d81578cbdf837064a8e8d23f331279` |
| WaveSynth | HWSupport/Sound/Voices/WaveSynth | `143b33d865036d6f9bc27136697a0b4252b1495c` |
| Percussion | HWSupport/Sound/Voices/Percussion | `4df094f1ea6c1ab6d347bc587796b7f8a647f326` |

Their original Apache-2.0 LICENSE files and Acorn notices are retained. Selected
UK Messages have no separate asset notice; their recorded basis is the enclosing
Apache-2.0 component release. WaveSynth's built-in Beep and Percussion's waveform
algorithms/data come from those identified source files, not a ROM. External
Brass/Organ voice application assets are not selected or joined. The exact
original/maintained hashes are in `manifests/sound-inputs.json`; modifications are
in `patches/sound`. Generated tokenised help is derived from the retained source.
The Zarch disc and all captures containing its code/data remain private test
inputs/output, outside release packages. Its use for testing grants no new
redistribution permission for the game.

### DragASprite runtime

The desktop includes DragASprite 0.11 from [the public DragASprit repository](https://gitlab.4corn.co.uk/RiscOS/Sources/Desktop/DragASprit), revision `31057aec4e4f93497ac66d5f8c83ede58d08322e`. `manifests/desktop-action-inputs.json` identifies each original file and maintained derivative. Its Apache-2.0 licence and Acorn notices remain in `src/DragASprit`; the build adaptations are recorded in `patches/desktop-actions`. The module uses the existing reviewed sprite resources and introduces no extracted ROM assets.

## Original system sprite commands

The desktop also includes **SpriteUtils 1.10**, from the public
[SpriteUtil repository](https://gitlab.4corn.co.uk/RiscOS/Sources/Video/Render/SpriteUtil),
cleaned-3.60 revision `b74d38f3b2b69d1b6cda5377c4b102de1f5be10f`.
`src/SpriteUtil/LICENSE` and the original Acorn notices accompany its sources.
Its original UK Messages, HelpSrc, Help and Syntax files are retained; the
runtime messages and generated help come from this cohort, with no ROM extracts.
The enclosing Apache-2.0 licence is the recorded basis for these assets; no
separate asset notice was found in the selected files. Exact original/maintained
hashes are in `manifests/desktop-action-inputs.json`, and the reversible assembly
adaptation is `patches/desktop-actions/0003-spriteutils-arm2.patch`.
The public test sprite and command test program are new Apache-2.0 project code.
Nevryon remains a user-supplied commercial test fixture, excluded from source
and binary release packages; restoring its required OS commands imports none
of the game's implementation or assets into ArcLibre.

## TaskWindow and FilterManager

Task-service sources are also retained from the public cleaned-3.60 cohort:
**TaskWindow 0.53** from [Desktop/TaskWindow](https://gitlab.4corn.co.uk/RiscOS/Sources/Desktop/TaskWindow),
revision `9d0a32bfcc51b43840d28ef8a23713061834b6f2`, and **FilterManager 0.11**
from [Desktop/Filter](https://gitlab.4corn.co.uk/RiscOS/Sources/Desktop/Filter),
revision `0728a78f554bdc46cac5043ba8a21941e6da3775`.
Their Apache-2.0 LICENSE files and Acorn source notices remain under
`src/TaskWindow` and `src/Filter`. The only newly selected runtime resources are
their UK Messages files; no separate asset notice occurs in those files, and
the enclosing component licence is the recorded basis. No fonts, sprites or
proprietary ROM bytes are added. Exact original and maintained hashes appear
in `manifests/task-services-inputs.json`; adaptations and the exit-path fix are
in the reversible `patches/task-services` series. The parent, filter and child
test programs are new Apache-2.0 ArcLibre code.

## Original C runtime, FilerAct and FilerSWIs

The C desktop restoration uses the matching public cleaned-3.60 cohort:

| Component | Original repository and exact revision |
| --- | --- |
| SharedCLibrary / RISC_OSLib | [Lib/RISC_OSLib](https://gitlab.4corn.co.uk/RiscOS/Sources/Lib/RISC_OSLib), `5e08cc7c4aae4163c8c964e5c19ac033f7d5fb85` |
| FilerAct | [Desktop/FilerAct](https://gitlab.4corn.co.uk/RiscOS/Sources/Desktop/FilerAct), `e2c9bb13ec47443521e1e13fef55abbfc213239d` |
| FilerSWIs | [Desktop/FilerSWIs](https://gitlab.4corn.co.uk/RiscOS/Sources/Desktop/FilerSWIs), `e76e9cdf66526a6f1a822b65bb8dd0ee1ac7003f` |

Their Apache-2.0 LICENSE files and per-file notices, including the retained
Acorn and Codemist attributions in the C library, accompany the maintained
sources. `manifests/desktop-c-inputs.json` and `desktop-action-inputs.json`
identify exact original and modified file hashes. The reversible patches are
in `patches/desktop-c` and `patches/desktop-actions`; modified upstream files
carry explicit ArcLibre change notices.

The four selected native resources are the original UK CLib Messages,
RISC_OSLib Messages, FilerAct Messages and FilerAct Templates. Their exact
paths, file types and hashes are recorded in
`build/desktop-c-runtime/resources.json`. These assets have no separate
file-level licence; their recorded basis is the enclosing component's public
Apache-2.0 release. No ROM extract, commercial application resource, substitute
font or proprietary C-library binary is included. FilerSWIs has no separate
resource payload.

The additional host compiler is public GCCSDK 3.4.6, pinned in
`manifests/c-toolchain.json`. Its selected host source archive, original per-component notices and
local patches are retained; the unused restricted CMunge directory is excluded. The [toolchain report](docs/desktop-c/TOOLCHAIN.md)
distinguishes host adaptations from the ROM-library data-placement fix.
GCCSDK target libraries are not linked into the ROM: the guest uses the real
original SharedCLibrary plus ArcLibre-authored division ABI adapters. These
adapters call the original arithmetic/error implementations. The diagnostic
floppy and test C program are new Apache-2.0 project code.

The allocator stack-check correction is a build adaptation of that same pinned
source: it preserves the original Norcroft `#pragma -s1` regions in `c/alloc`
and `rlib/c/flex` when compiling with GCCSDK. No additional source or library
is imported. The original files and notices remain unchanged; affected
functions and source hashes accompany the build in
`unchecked-stack-prologues.json`. See the
[editing report](docs/graphics-apps/EDITING.md) for the failure, adaptation and
runtime checks.


## Built-in Edit, Apps launcher and BBC BASIC

The desktop application cohort remains the public cleaned RISC OS 3.60 import:

| Component | Original repository | Pinned revision |
| --- | --- | --- |
| EditApp | [EditApp](https://gitlab.4corn.co.uk/RiscOS/Sources/Apps/EditApp) | `32d4c01ad1ecb99973cdb2b66af0238d8bff843b` |
| ResFiler | [ResFiler](https://gitlab.4corn.co.uk/RiscOS/Sources/FileSys/ResourceFS/ResFiler) | `7bc149fa33f4a22e1e8383c4fb6041541e0b8773` |
| BASIC | [BASIC](https://gitlab.4corn.co.uk/RiscOS/Sources/Programmer/BASIC) | `9a232a360592d98d0333f223c3c5bd9b0f6e562a` |

Each imported component retains its Apache-2.0 LICENSE. The per-file original
and maintained hashes are in `manifests/desktop-app-inputs.json`; the changes
are reversible with `patches/desktop-apps/series`. BASIC's original handwritten
floating-point routines are compiled in the integer BASIC105 configuration,
not the hardware-FPA BASIC64 configuration.

Selected assets are Edit's original UK Messages, Templates and Help; its Boot
and ROM Run scripts; the original tokenised BASIC Export helper; ResourceFiler's
UK Messages; and BASIC's UK Messages. These are files in those exact public
source commits, covered by their component release and without separate asset
licence notices. The helper is a public source-tree BASIC program, not a ROM
extraction. Its original `&FFB` catalogue type is preserved explicitly. Existing
Edit/Apps icons come from the previously documented public desktop sprite set.
No commercial disk content is included. Asset hashes and types are recorded by
`tools/build_desktop_apps.py` in `build/desktop-apps/resources.json`.

New C entry/jump adapters are Apache-2.0 and call the actual original
SharedCLibrary implementations. No GCC libgcc target code is added to the ROM.
The ST506 test disk and document text are project-authored disposable fixtures.


## Original Draw and Paint applications

- Draw: [Draw public source repository](https://gitlab.4corn.co.uk/RiscOS/Sources/Apps/Draw), cleaned-3.60 revision `4a47260942c2263aad63fd26cebcbe332f386490`.
- Paint: [Paint public source repository](https://gitlab.4corn.co.uk/RiscOS/Sources/Apps/Paint), cleaned-3.60 revision `54e9d858ed04502897185b6396f063232a2f83b5`.

Both component Apache-2.0 LICENSE files and existing source notices remain in
`src/Draw` and `src/Paint`. `manifests/graphics-app-inputs.json` records exact
upstream and maintained hashes. The reversible changes are recorded in
`patches/graphics-apps`.

The runtime asset selection is the original UK Messages, Templates and Help,
ROM launch/boot scripts, Draw's tool sprite file and Paint's UK tool sprite
file. Their redistribution basis is the enclosing public Apache-2.0 component
release; these files carry no separate asset licence. Exact paths, file types
and hashes are recorded in `build/graphics-apps/resources.json`. Draw's tool
sprites are embedded by its original ResourceFile wrapper. Existing application
icons come from the previously documented desktop sprite set. Additional
source-tree sprite variants are retained as source inputs but are not installed.
No upstream sample drawings, third-party test artwork or prebuilt application
binaries were imported. Runtime test artwork is created anew by the test.
The C entry adapters are ArcLibre-authored Apache-2.0 code and retain the real
original SharedCLibrary startup and services.

## ArcLibre original-machine appearance and Palette

The bitmap-font/flat-background profile changes the restored kernel's desktop
CMOS defaults only when explicitly built with `ArcLibreDesktopDefaults`.
Restoration patch 0031 retains the original flag-absent bytes. The final desktop
resource selector removes four unused Wimp tile sprites, including one 16bpp
VIDC20 tile; it preserves all retained records byte for byte and keeps the
complete original sprite files in the source archive. The existing pinned Wimp
asset licence and notices still apply. Selection hashes and individual removal
reasons are recorded in `desktop-resource-selection.json` beside the built ROM.

`src/ArcPalette` is a new ArcLibre-authored Apache-2.0 palette editor, not a
recovered Acorn implementation or the later DisplayManager. Its [source](src/ArcPalette/s/ArcPalette)
and [licence](src/ArcPalette/LICENSE) are included in the source distribution.
It uses the existing `palette` icon from the pinned Wimp sprite resources and
public Wimp APIs; no ROM-derived assets are added. Its original workspace and
bounded functionality are documented in the [profile report](docs/archimedes-desktop/RESULTS.md).

The plain window furniture is the unmodified `Resources/UK/Tools,ff9` from
Wimp commit `530acd4a18ffa97ce7a6b5b20fdef0a4db3ef647`, the same pinned cohort
as the selected Wimp runtime. Its original repository, SHA-256, size and
Apache source notice are recorded in `manifests/archimedes-furniture.json`.
The build selects this file instead of Tools3d; both originals remain in the
source tree. Palette’s revised layout follows the publicly available RISC OS 3
Applications Guide (printed pages 115–117); no manual artwork or original
Palette program bytes are incorporated.

## Public Wimp message allocations

The maintained `PublicInterfaces/hdr/Messages` comes from Programmer/HdrSrc
revision `403c6dd8bce92d0629634cbf57f68f43b2f30d38`, retaining its Castle
Apache-2.0 notice. The [input manifest](manifests/public-message-inputs.json)
records original and maintained hashes. The [patch](patches/public-messages/series)
uses the complete exported NetFS/Wimp/PDriver bases instead of adding the
legacy system/application base twice. The source and existing allocation values
are public; no proprietary ROM was consulted or extracted for this correction.

The user's Impression application was run unmodified on a disposable private
disc copy. It is not an ArcLibre dependency or redistributable asset: its files,
resources, screenshots and runtime captures remain outside source/release
packages. Public regression tests use a new Apache-2.0 menu client.

## Character-stream runtime sources

The stream components are selected from the same public cleaned-3.60 cohort:

- [DeviceFS](https://gitlab.4corn.co.uk/RiscOS/Sources/HWSupport/DeviceFS), revision `1d464cee133c220ff66d2f136284f633fe3f3086`.
- [SystemDevs](https://gitlab.4corn.co.uk/RiscOS/Sources/HWSupport/SystemDevs), revision `32481c2bf1a836d989e5f3686653666c387c0d6e`.
- [PipeFS](https://gitlab.4corn.co.uk/RiscOS/Sources/FileSys/PipeFS), revision `614e2725452d242c4f3d3c747d8790d74d7d5797`.

Their original Apache-2.0 LICENSE files and Acorn source notices are retained.
`manifests/stream-inputs.json` records the exact selected source, interface,
build-description and documentation bytes. The only selected runtime assets
are their UK message files, covered by the component releases and carrying no
separate asset licences. No prebuilt runtime modules or upstream test binaries
are imported. Their runtime and exact-ROM release gates are recorded in
[the stream report](docs/streams/RESULTS.md); source selection itself is not
a substitute for that validation.

## RAM filing and free-space runtime sources

The everyday filing modules retain their original Apache-2.0 LICENSE
files and source notices from the public cleaned-3.60 release:

- [RAMFS](https://gitlab.4corn.co.uk/RiscOS/Sources/FileSys/RAMFS/RAMFS), revision `ef43a7ada8c3681c33031c9ab4d4761dabf3d13d` (maintained directory `RamFS`).
- [RAMFSFiler](https://gitlab.4corn.co.uk/RiscOS/Sources/FileSys/RAMFS/RAMFSFiler), revision `be30ead145d8f7c289f629cf540cb4d18c7cb47b`.
- [Free](https://gitlab.4corn.co.uk/RiscOS/Sources/Desktop/Free), revision `ad049d9991c69640cf46586e82a5ddb0669e0df0`.

`manifests/ram-filing-inputs.json` identifies each selected file and its hash.
The runtime assets are the components' UK messages and Free's released window
templates. Both template variants are retained as source; the Archimedes build
selects the flat `Template2D` resource. These files carry no separate asset
licence in the pinned release. No prebuilt modules, proprietary ROM resources,
fonts or upstream test executables are imported. The [RAM filing report](docs/ram-filing/RESULTS.md) records the actual
workspace, icon, file and free-space gates; importing sources alone does not
establish runtime compatibility.

## DOSFS and host-tool exclusions

[DOSFS](https://gitlab.4corn.co.uk/RiscOS/Sources/FileSys/ImageFS/DOSFS) 0.62 at
`ec870faf21127aba600c58b3571115ac164e40f3` is imported as a disc-loaded module,
not as part of the ROM. Its Apache-2.0 LICENSE and the Acorn notices remain on
all 34 selected files (the in-file credits to J G Smith and S M Cormie are
internal Acorn authorship notes under the same 1996 Acorn notice);
`manifests/dosfs-inputs.json` records the upstream and maintained hashes and
`patches/dosfs` the changes. The UK Messages file carries no separate notice
and is embedded unmodified.

The pinned `s/StaticDefs` default format template contains an opaque
`MSDOS3.3`-labelled x86 boot sector whose separate provenance has not been
established. ArcLibre does not redistribute it: `tools/import_dosfs.py`
excises exactly that block from the import baseline and the manifest records
the hashes of the complete upstream file and of the excised lines. `c/BOOTblock`
(an unused second copy) is not imported. The replacement default boot sector
`src/ArcLibre/s/DOSFSBoot` is independently written ArcLibre code (Apache-2.0):
standard FAT BPB values and a short x86 routine that prints a non-system-disc
message, waits for a key and calls INT 19h. It loads nothing.

The module header and C veneers `src/ArcLibre/s/DOSFSHdr` (with
`src/ArcLibre/h/DOSFShdr`) are ArcLibre code implementing the contract
described by the original `cmhg/DOSFShdr`; no CMHG or CMunge output is used.
The module links the original RISC_OSLib RAM stubs (`clib/s/cl_stub_r`,
Apache-2.0, already in the source cohort) and ArcLibre's `s/GCCDiv`. Drlink
(GPL host tool) adds its standard self-relocation sequence and table to the
image, as any linker adds its documented output format; the GCCSDK compiler
and Drlink are not linked into the module otherwise. The distributable floppy
holds only this module and an ArcLibre ReadMe. Test PC discs are generated on
the host from project-authored data.

The historical GCCSDK archive contained CMunge 0.76 under its own restrictive
`Docs/Copyright`, not the compiler's GPL. It was not used to generate this ROM.
The replacement host source archive excludes all 57 files in that directory
and the bootstrap omits the utility. The [selection manifest](manifests/c-toolchain-selection.json)
records exact provenance; retained files keep their individual notices. Earlier
source packages containing the whole archive must not be described as uniformly
GPL or unrestricted. This change does not change or relicense the ROM.

## ScreenBlanker and string-voice runtime sources

The selected public cleaned-3.60 sources are
[ScrBlank](https://gitlab.4corn.co.uk/RiscOS/Sources/Video/Render/ScrBlank) at
`9d17f822bccc749fa9d345301eb95573fb90c444` and
[StringLib](https://gitlab.4corn.co.uk/RiscOS/Sources/HWSupport/Sound/Voices/StringLib)
at `38468e6b620847a1eebe7f16a5648d51a0702200`. Their original Apache-2.0
LICENSE files and notices remain; `manifests/standard-utility-inputs.json` records
all 13 selected inputs and original/maintained hashes. Their UK message files
have no separate asset notices. String voices are generated by the original
algorithms, without imported samples or music. Their [runtime gate](docs/standard-utilities/RESULTS.md) validates the original
workspace, copied ARM2 code, frame/palette effects and real sound DMA; full
release evidence is tied separately to the exact ROM hash.

## Original IIC and RTCAdjust

The selected public cleaned-3.60 sources are
[IIC](https://gitlab.4corn.co.uk/RiscOS/Sources/HWSupport/IIC) at
`3a9726dcc5cf61a5722dbcec9bc52f2468e9e57a` and
[RTCAdjust](https://gitlab.4corn.co.uk/RiscOS/Sources/HWSupport/RTCAdjust) at
`a0f37cd91cdd45e99d1643c77512a76b0f875d0e`. Their Apache-2.0 LICENSE files and
source notices remain; `manifests/clock-inputs.json` records all nine selected
inputs with original and maintained hashes. Their UK message files carry no
separate notice. The [runtime gate](docs/clock/RESULTS.md) uses only generated
media and the emulated PCF8583.

## ArcLibre !Calc, !Configure and PaletteUtil

`src/ArcCalc`, `src/ArcConfigure` (BASIC programs and ROM wrappers) and
`src/ArcPalette` are new Apache-2.0 ArcLibre code. `!Configure`'s nine section
icons are the unmodified Apache-2.0 `Resources/Sprites,ff9` of
[SystemRes/Configure](https://gitlab.4corn.co.uk/RiscOS/Sources/SystemRes/Configure)
at `2fb77e8dc4c0ebac6c32d62614168afb8dcff714` (its LICENSE is kept beside it;
`manifests/configure-inputs.json`). Acorn's 3.11 `!Calc`, `!Configure` and PaletteUtil were never
published; these reproduce their documented appearance and behaviour (RISC OS
3 User Guide, PRM, measured screenshots) without Acorn code or templates.
Apart from those section icons, their icons are sprites of the pinned
Apache-licensed Wimp set.

## Original networking modules

Econet, BBCEconet, NetFS, NetFiler, NetPrint and NetStatus come from their
cleaned-3.60 repositories at the revisions in `manifests/network-inputs.json`
(with `Hdr:PoduleReg` from Programmer/HdrSrc `403c6dd8bce9`). They keep their
Apache-2.0 LICENSE files and notices; ArcLibre's ARM2 changes are in
`patches/network` and marked in each modified file.

## Original expansion card, serial and parallel modules

Podule, SerialDeviceDriver, SerialDeviceSupport and ParallelDeviceDriver come
from their cleaned-3.60 HWSupport repositories at the revisions in
`manifests/hardware-inputs.json`. They keep their Apache-2.0 LICENSE files and
notices; ArcLibre's ARM2/IOC changes, including Podule's RISC OS 3.11 wording,
are in `patches/hardware` and marked in each modified file.

## ArcLibre ARM3Support

`src/ARM3Support` is new Apache-2.0 ArcLibre code implementing the documented
RISC OS 3 ARM3 cache interface; Acorn's 3.11 ARM3Support was never published.
Its default cache areas are the values in the pinned 3.60 kernel's
`s/NewReset`, and its message wording follows the pinned HWSupport/ARM
module's Messages (both Apache-2.0).

## Original Debugger

[Debugger](https://gitlab.4corn.co.uk/RiscOS/Sources/Programmer/Debugger) at
`973b1967d8ff1c48dcd138d1d27f1721217228b8` keeps its Apache-2.0 LICENSE and
notices; `manifests/debugger-inputs.json` records ten selected inputs. Its UK
messages and tokenised help carry no separate notice.

## Original Squash, Chars and Help

These restored runtime components extend the same public cleaned-3.60 cohort:

- [Squash](https://gitlab.4corn.co.uk/RiscOS/Sources/Programmer/Squash), revision `a21ce91e3d0a1a8c04f3e0dd72683a6d7fa2ab76`.
- [Chars](https://gitlab.4corn.co.uk/RiscOS/Sources/Apps/Chars), revision `6360d0336eff8cfd3a4857b0500c13f7c9d32e77`.
- [Help](https://gitlab.4corn.co.uk/RiscOS/Sources/Apps/Help), revision `01f0e2d2ee060eff698cc50d4c2a0731a8bf3d07`.
- [Alarm](https://gitlab.4corn.co.uk/RiscOS/Sources/Apps/Alarm), revision `ea4dc989e3121d63682cd6f8fce639667c501c7a`.

`manifests/desktop-utility-inputs.json` records 60 selected files. Squash retains
its combined licence: Jon Thackray's compression sources use the BSD three-clause
terms, while the Acorn module/interface code uses Apache-2.0. Both notices and
the binary-redistribution attribution requirement are retained. Its C codecs
were already present for host asset generation; this imports the matching SWI
and assembler implementations, not a different codec cohort. The original
module wrapper avoids any dependency on CMunge.

Chars, Help and Alarm retain their original Apache notices, including the
leading licence lines embedded in the tokenised BASIC source. For ROM storage
their `!RunImage` programs are compacted by `tools/basic_squish.py`, new
Apache-2.0 ArcLibre code that is not derived from Acorn's proprietary squish
tool. It removes non-licence REMs and spaces, shortens names and joins lines;
the licence lines are kept byte for byte. Alarm's `Code` is produced by running
its original `AlarmSrc` in the ROM's own BASIC (`tools/generate_alarm_code.py`);
the generated bytes are build output, not committed. Alarm's wrapper carries a
modification notice. Alarm is distributed on its own floppy
(`arclibre-alarm.adf`, `tools/build_alarm_disc.py`) rather than in the ROM; the
disc's ReadMe (`src/ArcLibre/alarm/ReadMe`) is new ArcLibre text under
Apache-2.0. Tokenisation is their source representation;
these files are not prebuilt ARM modules. Their UK messages, help text and
window templates are selected from the same revisions. No separate asset
licence is present in those selected resources. The flat Help template is the
original `Templat2d`; no proprietary ROM assets, fonts, icons or executable
applications are extracted. Candidate source import and assembly alone do not
establish runtime compatibility or change the installed release.
