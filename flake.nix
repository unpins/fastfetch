{
  description = "fastfetch as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Round 8 — TLS-swap trampoline (graphics.gd / Cosmopolitan prior art).
  #
  # Round 7 (aneeshdurg's foreign-dlopen) worked for stateless IPC clients
  # (DBus + Bluetooth) but crashed on TLS-heavy dispatchers (Vulkan/OpenCL/
  # Wayland) at si_addr=0xfffffffffffffffe — the glibc-loaded lib expected
  # TLS slots that the musl-static main process never set up. Round 8 ports
  # graphics.gd's solution: a pool of 64 glibc-bound threads each capturing
  # its own TLS pointer, plus an asm trampoline (foreign_tramp.S) that does
  # arch_prctl(ARCH_SET_FS) before every call into a foreign function (and
  # restores native FS on return). See [[reference_foreign_dlopen_tls_swap_trampoline]].
  inputs.graphicsgd-src = {
    url = "github:quaadgras/graphics.gd/07c79b4a08fdce43fc830e3fcd959c98cdfa6a2b";
    flake = false;
  };

  # The fdlhelper is the one piece here that is glibc-dynamic, and its glibc
  # must be at least as new as the host libraries it dlopen's — libvulkan on
  # current distros wants 2.42+, and a helper built against an older one fails
  # the symbol-version lookup. This used to need a second, newer nixpkgs; the
  # catalog pin now ships glibc-2.42-84 against nixos-unstable's 2.42-61, so the
  # extra input was buying an OLDER libc. Follow unpins-lib and keep one nixpkgs.
  # The 2.17 floor still comes from polyfill-glibc below, not from the pin.
  inputs.nixpkgs.follows = "unpins-lib/nixpkgs";

  # polyfill-glibc (corsix): rewrites .gnu.version_r so the helper can run
  # against older glibc than it was built with. Same tool upstream fastfetch
  # uses for its `*-polyfilled.tar.gz` release artifacts. Built inline since
  # nixpkgs doesn't ship it. C11 + ninja.
  inputs.polyfill-glibc-src = {
    url = "github:corsix/polyfill-glibc/dd59051faaa10ee63c1b96f1b47bf9fcd3770ee2";
    flake = false;
  };

  outputs = { self, unpins-lib, graphicsgd-src, nixpkgs, polyfill-glibc-src }:
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "fastfetch";
      # Build fastfetch + its whole pkgsStatic dep closure (glib/GObject,
      # imagemagick, chafa, vulkan-loader, ocl-icd, dconf, wayland, ddcutil, …)
      # through the unpin-llvm engine: every object LLVM bitcode, whole-program
      # LTO into one static 0-DT_NEEDED binary. `build` receives an engine-
      # swapped pkgs whose `pkgsStatic` IS the bitcode set, so the `p`/`pd`/
      # `dconfStatic`/`tlsTrampoline` derivations fold under the engine
      # automatically. The glibc/musl foreign-dlopen helpers stay off-engine
      # (they use helperPkgs.stdenv / pkgsCross.musl64, not pkgsStatic) — they
      # must remain real dynamic ELFs run as separate processes at runtime.
      engine = "unpin-llvm";
      smoke = [ "--version" ];
      smokePattern = "fastfetch";
      # Scoped per-package exception to the darwin portability allow-list.
      # fastfetch's macOS backend weak-links two Apple PrivateFrameworks that
      # have no public equivalent: DisplayServices (builtin-display brightness)
      # and MediaRemote (the now-playing Media module). action-build's verify
      # step permits exactly these two private frameworks for this package
      # only — the strict default (public Frameworks + libSystem + libobjc)
      # is unchanged for every other catalog package. Symbols are weak-import
      # and NULL-guarded, so the features degrade gracefully if a macOS update
      # ever removes the framework.
      darwinAllowPrivateFrameworks = [ "DisplayServices" "MediaRemote" ];

      # The static binary keeps the datadir/helper path constants its libraries
      # bake in — glib's localedir, libX11's compose tables, dbus-launch, the
      # XML catalog, the RUNPATHs of the two embedded foreign-dlopen helpers —
      # and Nix reads them as runtime references. None is reachable: the code
      # is linked in and the helpers are extracted and run from a temporary
      # directory. Left alone they dragged a 1.02 GB closure behind a 15 MB
      # binary, most of it ImageMagick's and glib's build inputs.
      removeReferences = [
        "libdrm" "libx11" "glib-static" "dbus-static" "imagemagick"
        "libxml2" "glibc" "gcc-15" "graphicsgd" "fastfetch-static"
      ];
      build = pkgs:
        let
          # Native build (incl. CI's aarch64 arm runner): build==host, so
          # legacyPackages.<system>. When cross-compiling (e.g. the local
          # build-aarch64-linux helper on an x86_64 box), instantiate it as a
          # *cross* set so its buildPackages tools (polyfill-glibc, ninja) run on
          # the build host while glibcHelper's fdlhelper still targets the host
          # arch. Plain nixpkgs, not the engine set: these stay real dynamic ELFs.
          helperPkgs =
            if pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system
            then nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}
            else import nixpkgs {
              localSystem = pkgs.stdenv.buildPlatform.system;
              crossSystem = pkgs.stdenv.hostPlatform.system;
            };

          # Extracted verbatim from graphics.gd's HELPER macro in
          # startup/internal/dlopen/dlopen.c. The helper is shipped as an
          # external glibc-dynamic ELF (embedded via xxd -i into the static
          # archive, extracted to TMPDIR at first dlopen). It creates a
          # 64-thread pool, each thread:
          #   1. Captures its own glibc TLS pointer + __tramp_ctx address
          #      into __tls_pool
          #   2. Posts ready semaphore when all 64 done
          #   3. Parks on shutdown semaphore forever
          # After init, main() calls back into the main binary's
          # foreign_helper() with (dlopen, dlsym, dlclose, dlerror,
          # &__tls_pool). foreign_helper() longjmps out, leaving the
          # pool threads alive in process memory for foreign_tramp to
          # consult per-call.
          helperSrc = builtins.toFile "helper.c" ''
            #define _GNU_SOURCE
            #include <dlfcn.h>
            #include <stdio.h>
            #include <stdlib.h>
            #include <pthread.h>
            #include <semaphore.h>
            #include <stdint.h>

            #define TLS_POOL_SIZE 64

            __thread struct { long sp; void *stack[32]; } __tramp_ctx;

            struct tls_pool {
              void *tls_ptrs[TLS_POOL_SIZE];
              void *tramp_ctxs[TLS_POOL_SIZE];
              sem_t ready;
              sem_t shutdown;
              int count;
              pthread_mutex_t lock;
            } __tls_pool;

            static void *get_tls(void) {
              void *tls;
            #ifdef __x86_64__
              __asm__ volatile("mov %%fs:0, %0" : "=r"(tls));
            #elif defined(__aarch64__)
              __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tls));
            #else
            # error "unsupported architecture"
            #endif
              return tls;
            }

            static void *pool_thread(void *arg) {
              int idx = (int)(intptr_t)arg;
              pthread_mutex_lock(&__tls_pool.lock);
              __tls_pool.tls_ptrs[idx] = get_tls();
              __tls_pool.tramp_ctxs[idx] = &__tramp_ctx;
              __tls_pool.count++;
              if (__tls_pool.count == TLS_POOL_SIZE) sem_post(&__tls_pool.ready);
              pthread_mutex_unlock(&__tls_pool.lock);
              sem_wait(&__tls_pool.shutdown);
              return NULL;
            }

            int main(int argc, char **argv, char **envp) {
              (void)envp;
              const char *ep;
              long addr = 0;
              if (argc != 2) {
                fprintf(stderr, "%s: not intended to be run directly\n", argv[0]);
                return 1;
              }
              /* Parse argv[1] as a decimal long by hand instead of strtol():
                 under _GNU_SOURCE + glibc 2.38+, strtol redirects to the C23
                 __isoc23_strtol@GLIBC_2.38 symbol, which polyfill-glibc has no
                 rule to downgrade to the 2.17 floor on aarch64 (the x86 table
                 covers it, the aarch64 one does not). A hand-rolled parser has
                 zero libc-version coupling and works identically on every arch. */
              ep = argv[1];
              if (*ep < '0' || *ep > '9') {
                fprintf(stderr, "%s: invalid function address\n", argv[0]);
                return 2;
              }
              for (; *ep >= '0' && *ep <= '9'; ep++)
                addr = addr * 10 + (*ep - '0');
              if (*ep) {
                fprintf(stderr, "%s: invalid function address\n", argv[0]);
                return 2;
              }
              sem_init(&__tls_pool.ready, 0, 0);
              sem_init(&__tls_pool.shutdown, 0, 0);
              pthread_mutex_init(&__tls_pool.lock, NULL);
              __tls_pool.count = 0;
              __tls_pool.tls_ptrs[0] = get_tls();
              __tls_pool.tramp_ctxs[0] = &__tramp_ctx;
              __tls_pool.count = 1;
              pthread_attr_t attr;
              pthread_attr_init(&attr);
              pthread_attr_setstacksize(&attr, 16384);
              for (int i = 1; i < TLS_POOL_SIZE; i++) {
                pthread_t t;
                pthread_create(&t, &attr, pool_thread, (void*)(intptr_t)i);
                pthread_detach(t);
              }
              pthread_attr_destroy(&attr);
              while (__tls_pool.count < TLS_POOL_SIZE) {
                sem_wait(&__tls_pool.ready);
              }
              return ((int (*)(void *))addr)((void *[]){
                  dlopen, dlsym, dlclose, dlerror, &__tls_pool,
              });
            }
          '';

          # polyfillGlibc: tool that rewrites a binary's glibc symbol-version
          # references to target an older floor. Self-contained C11 + ninja
          # build from upstream sources.
          # Build-time tool: it rewrites a target binary's ELF version
          # records (arch-agnostic), so it must run on the *build host*, not
          # the target. Using helperPkgs.stdenv would build it for the target
          # arch — fine natively (build==host) but unbuildable when cross-
          # compiling (e.g. aarch64-linux from x86_64) without an arm builder.
          # buildPackages.stdenv pins it to the build host; identical natively.
          polyfillGlibc = helperPkgs.buildPackages.stdenv.mkDerivation {
            pname = "polyfill-glibc";
            version = "dd59051";
            src = polyfill-glibc-src;
            nativeBuildInputs = [ helperPkgs.buildPackages.ninja ];
            buildPhase = ''
              runHook preBuild
              ninja polyfill-glibc
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp polyfill-glibc $out/bin/
              runHook postInstall
            '';
          };

          # Per-arch system dynamic-loader path on the typical Linux host
          # (Debian/Ubuntu/RHEL/Arch/Alpine-glibc/Gentoo-glibc all use these).
          # NixOS pure systems don't have /lib64 — `nix-ld` covers that case;
          # users running unpins binaries on bare NixOS need it anyway.
          systemLdSoGlibc =
            if pkgs.stdenv.hostPlatform.isx86_64 then
              "/lib64/ld-linux-x86-64.so.2"
            else if pkgs.stdenv.hostPlatform.isAarch64 then
              "/lib/ld-linux-aarch64.so.1"
            else
              throw "unsupported arch for fdlhelper glibc ld.so path";

          systemLdSoMusl =
            if pkgs.stdenv.hostPlatform.isx86_64 then
              "/lib/ld-musl-x86_64.so.1"
            else if pkgs.stdenv.hostPlatform.isAarch64 then
              "/lib/ld-musl-aarch64.so.1"
            else
              throw "unsupported arch for fdlhelper musl ld.so path";

          # glibcHelper: glibc-dynamic ELF embedded for the glibc-host path
          # (Debian/Ubuntu/RHEL/Arch/Fedora/etc). Built against helperPkgs
          # glibc 2.42+, then polyfilled down to a 2.17 floor (CentOS 7
          # vintage). See [[feedback_polyfill_glibc_fixup_trap]] for why
          # dontPatchELF/dontStrip are required.
          glibcHelper = helperPkgs.stdenv.mkDerivation {
            pname = "graphicsgd-glibc-helper";
            version = "07c79b4";
            dontUnpack = true;
            nativeBuildInputs = [ polyfillGlibc helperPkgs.patchelf ];
            dontPatchELF = true;
            dontStrip = true;
            buildPhase = ''
              cp ${helperSrc} helper.c
              $CC -pie -fPIC -O2 -o fdlhelper helper.c -lpthread -ldl
              polyfill-glibc --target-glibc=2.17 fdlhelper
              patchelf --set-interpreter ${systemLdSoGlibc} --remove-rpath fdlhelper
            '';
            installPhase = ''
              mkdir -p $out/bin
              cp fdlhelper $out/bin/fdlhelper
            '';
            doInstallCheck = true;
            installCheckPhase = ''
              file $out/bin/fdlhelper | grep -q 'dynamically linked' \
                || { echo "glibcHelper NOT dynamic: $(file $out/bin/fdlhelper)"; exit 1; }
              actual=$(patchelf --print-interpreter $out/bin/fdlhelper)
              [ "$actual" = "${systemLdSoGlibc}" ] \
                || { echo "interpreter not patched: $actual"; exit 1; }
              if polyfill-glibc --print-imports $out/bin/fdlhelper \
                  | grep -qE 'GLIBC_2\.(1[89]|[2-9][0-9])'; then
                echo "polyfill failed: >=2.18 symbols still present:"
                polyfill-glibc --print-imports $out/bin/fdlhelper \
                  | grep -E 'GLIBC_2\.(1[89]|[2-9][0-9])'
                exit 1
              fi
            '';
          };

          # muslHelper: musl-dynamic ELF embedded for the musl-host path
          # (Alpine, Chimera, Void-musl, etc). No polyfill needed — musl pledges
          # ABI stability across releases, so a 1.2.x helper runs on any Alpine
          # 3.16+ vintage.
          muslCross =
            if pkgs.stdenv.hostPlatform.isx86_64 then pkgs.pkgsCross.musl64
            else pkgs.pkgsCross.aarch64-multiplatform-musl;
          muslHelper = muslCross.stdenv.mkDerivation {
            pname = "graphicsgd-musl-helper";
            version = "07c79b4";
            dontUnpack = true;
            nativeBuildInputs = [ muslCross.buildPackages.patchelf ];
            dontPatchELF = true;
            dontStrip = true;
            buildPhase = ''
              cp ${helperSrc} helper.c
              $CC -pie -fPIC -O2 -o fdlhelper helper.c -lpthread -ldl
              patchelf --set-interpreter ${systemLdSoMusl} --remove-rpath fdlhelper
            '';
            installPhase = ''
              mkdir -p $out/bin
              cp fdlhelper $out/bin/fdlhelper
            '';
            doInstallCheck = true;
            installCheckPhase = ''
              file $out/bin/fdlhelper | grep -q 'dynamically linked' \
                || { echo "muslHelper NOT dynamic"; exit 1; }
              actual=$(patchelf --print-interpreter $out/bin/fdlhelper)
              [ "$actual" = "${systemLdSoMusl}" ] \
                || { echo "musl interp not patched: $actual"; exit 1; }
            '';
          };

          # tlsTrampoline: static archive built from graphics.gd's dlopen.c
          # + foreign_tramp.S + the xxd-i'd fdlhelper bytes (see the patch
          # header for what changes in dlopen.c).
          tlsTrampoline = pkgs.pkgsStatic.stdenv.mkDerivation {
            pname = "graphicsgd-dlopen-static";
            version = "07c79b4";
            src = graphicsgd-src;
            sourceRoot = "source/startup/internal/dlopen";
            nativeBuildInputs = [ pkgs.xxd ];
            patches = [
              ./patches/graphicsgd-dlopen-embedded-helper.patch
              ./patches/graphicsgd-aarch64-trampoline-stub.patch
            ];
            postPatch = ''
              # Embed both pre-built helpers via xxd -i. The static main
              # binary detects the host libc at first dlopen and extracts
              # whichever helper matches.
              cp ${glibcHelper}/bin/fdlhelper glibc_helper
              xxd -i -n glibc_helper_data glibc_helper > glibc_helper_data.c
              cp ${muslHelper}/bin/fdlhelper musl_helper
              xxd -i -n musl_helper_data musl_helper > musl_helper_data.c
            '';
            buildPhase = ''
              runHook preBuild
              $CC -fPIE -O2 -I. -c glibc_helper_data.c -o glibc_helper_data.o
              $CC -fPIE -O2 -I. -c musl_helper_data.c  -o musl_helper_data.o
              $CC -fPIE -O2 -I. -c dlopen.c            -o dlopen.o
              $CC -fPIE -O2 -I. -c foreign_tramp.S     -o foreign_tramp.o
              "$AR" rcs foreign_dlopen.a dlopen.o foreign_tramp.o \
                glibc_helper_data.o musl_helper_data.o
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib
              cp foreign_dlopen.a $out/lib/
              runHook postInstall
            '';
          };

          # ddcutil em musl-static não builda upstream: autoconf detecta
          # `malloc(0) == NULL` em musl como "broken malloc" e ativa
          # `#define malloc rpl_malloc` em config.h, mas o gnulib que
          # forneceria `rpl_malloc` não está no projeto — implicit-decl
          # quebra o build. Fix clássico: dizer ao autoconf que o
          # malloc do sistema é bom (musl segue POSIX, retornar NULL
          # pra size==0 é permitido). Igual pra realloc.
          # vulkan-loader 1.4.x em Linux faz `add_library(vulkan SHARED)`
          # hardcoded (loader/CMakeLists.txt:418); opção `APPLE_STATIC_
          # LOADER` é APPLE-only. Em musl-static, ld --shared explode com
          # `R_X86_64_32 against hidden symbol __TMC_END__ in crtbeginT.o`
          # (mesmo padrão de libyuv ver
          # [[feedback_pkgsstatic_imagemagick_chain_patches]] #3).
          vulkanLoaderOverlay = final: prev: {
            vulkan-loader = prev.vulkan-loader.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [ ./patches/vulkan-loader-static-library.patch ];
            });
          };
          # ocl-icd 2.3.4: Makefile.am builda `noinst_PROGRAMS=run_dummy_
          # icd_through_our_ICDL` que linka contra libOpenCL.a (forte)
          # JUNTO com `run_dummy_icd_weak_gen.o` (mesmas funções, weak).
          # Em glibc/shared, ld resolve weak<strong via versioning. Em
          # musl-static, ld é estrito → "multiple definition" pra ~600
          # funções OpenCL. Esses noinst são só pra UPDATE_DATABASE
          # workflow do upstream, fastfetch não usa.
          oclIcdOverlay = final: prev: {
            ocl-icd = prev.ocl-icd.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [ ./patches/ocl-icd-no-test-programs.patch ];
            });
          };
          ddcutilOverlay = final: prev: {
            ddcutil = prev.ddcutil.overrideAttrs (old: {
              configureFlags = (old.configureFlags or [ ]) ++ [
                "ac_cv_func_malloc_0_nonnull=yes"
                "ac_cv_func_realloc_0_nonnull=yes"
              ];
              # ddcutil 2.2.7 (26.05) includes <execinfo.h> unconditionally in
              # linux_util.c (segv-handler backtrace). musl has no execinfo.h;
              # libexecinfo is the standalone musl-compatible backtrace impl.
              # Supplies the header (so the include resolves) and libexecinfo.a
              # (backtrace/backtrace_symbols); -lexecinfo injected for the
              # static link. Keeps the segv backtrace, disables nothing.
              buildInputs = (old.buildInputs or [ ]) ++ [ final.libexecinfo ];
              NIX_LDFLAGS = (old.NIX_LDFLAGS or "") + " -lexecinfo";
              # ddcutil.pc ships with its `Requires:` line commented out and
              # `Libs: -lddcutil` only — so a static consumer (pkg-config
              # --static, or CMake's pkg_search_module) never pulls the closure
              # and the final link fails (jansson/acl/udev/gudev/usb/backtrace
              # undefined). Repair the .pc with a real Requires.private + the
              # libexecinfo backtrace dep so both fastfetch branches link clean.
              postInstall = (old.postInstall or "") + ''
                pc=$out/lib/pkgconfig/ddcutil.pc
                if [ -e "$pc" ]; then
                  sed -i '/^# *Requires:/d' "$pc"
                  printf 'Requires.private: glib-2.0 jansson libacl gudev-1.0 libusb-1.0 libudev libdrm\nLibs.private: -lexecinfo\n' >> "$pc"
                fi
              '';
            });
          };
          # chafa 1.18.0 em nixpkgs (by-name layout) declara
          # buildInputs: [ glib libavif libjxl librsvg ]. Os loaders
          # extras puxam cadeias pesadas — librsvg em particular requer
          # libunwind static que o pin atual de nixpkgs não tem. Pra
          # logo simples de OS, esses codecs são over-engineered. Tentei
          # ligar tudo (ver [[feedback_pkgsstatic_imagemagick_chain_patches]])
          # e bateu em 10+ pontos de patch separados em musl-static.
          chafaDropLoaders = [ "librsvg" "libavif" "libjxl" ];
          chafaOverlay = final: prev: {
            chafa = prev.chafa.overrideAttrs (old: {
              configureFlags = (old.configureFlags or [ ]) ++ [
                "--without-svg"
                "--without-avif"
                "--without-heif"
                "--without-jxl"
                "--without-tiff"
                # --without-tools: skip o CLI `chafa` binário (que quer
                # freetype pra rendering). fastfetch só consome libchafa.
                "--without-tools"
              ];
              buildInputs = builtins.filter
                (x: !(builtins.elem (x.pname or x.name or "") chafaDropLoaders))
                (old.buildInputs or [ ]);
              propagatedBuildInputs = builtins.filter
                (x: !(builtins.elem (x.pname or x.name or "") chafaDropLoaders))
                (old.propagatedBuildInputs or [ ]);
            });
          };
          # ImageMagick decodes the image logo. PNG, JPEG, WebP, TIFF, HEIC
          # and JPEG XL stay (nix-lib's libjxl/libheif fixes in codecFixes).
          # SVG goes through ImageMagick's built-in renderer: librsvg would add
          # 20 MB (28 -> 48 MB on x86_64, its pango/cairo/harfbuzz chain) for
          # a terminal logo. The rest is cut: fonts, colour management and X11
          # have no use for a logo, and the RAW/EXR/DjVu/JPEG 2000 chains
          # don't build static without more overlays.
          imagemagickOverlay = final: prev: {
            imagemagick = (prev.imagemagick.override {
              bzip2Support = false;
              fontconfigSupport = false;
              freetypeSupport = false;
              djvulibreSupport = false;
              lcms2Support = false;
              librsvgSupport = false;
              openexrSupport = false;
              liblqr1Support = false;
              libraqmSupport = false;
              librawSupport = false;
              libxml2Support = false;
              openjpegSupport = false;
              libX11Support = false;
              libXtSupport = false;
              fftwSupport = false;
            }).overrideAttrs (old:
              # darwin: imagemagick still links libxml2.a (core config
              # parsing), whose encoding.o references iconv, and imagemagick's
              # static link omits -liconv. It has to be GNU libiconv
              # (`libiconvReal`), for two independent reasons: nixpkgs' plain
              # `libiconv` on darwin is Apple's, which installs only bin/iconv
              # and the charset tables — no lib/ at all, so `-liconv` had
              # nothing to resolve against; and nix-lib's darwinIconvConverge
              # hands GNU's header to libxml2 on the engine scopes, so
              # encoding.o asks for the PREFIXED `libiconv_open`/
              # `libiconv_close`/`libiconv`. GNU's archive defines both
              # spellings, so it satisfies either. darwin-only; linux/musl
              # carry iconv in libc so this stays off there.
              prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
                buildInputs = (old.buildInputs or [ ]) ++ [ final.libiconvReal ];
                NIX_LDFLAGS = (old.NIX_LDFLAGS or "") + " -liconv";
              });
          };
          # potrace 1.16 (pulled by imagemagick) bundles a vintage getopt.c
          # with K&R definitions + `extern int getopt ();` (empty parens =
          # unspecified args in old C). gcc-15's default -std=gnu23 (26.05)
          # reinterprets `()` as `(void)`, so the 3-arg K&R definition no
          # longer matches its own prototype ("number of arguments doesn't
          # match prototype"; "too many arguments to getenv"). Same gcc-15
          # C23 family as the -std=gnu17 fix elsewhere in the sweep. Compile
          # potrace as gnu17 (does not disable anything — makes it build).
          potraceOverlay = final: prev: {
            potrace = prev.potrace.overrideAttrs (old: {
              NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " -std=gnu17";
            });
          };
          # libultrahdr (transitive dep of imagemagick) runs a CTest unit-test
          # suite at build time that fails under qemu user-mode emulation on the
          # cross targets (UHDRUnitTests). It's a build-time self-test, not a
          # functional gate — turn it off so the lib builds on every arch.
          # On ppc64le its CMakeLists has no arch branch (FATAL "not
          # recognized") and no AltiVec/VSX SIMD path — add the branch via a
          # generic ARCH + intrinsics off (scalar build, codec unaffected).
          libultrahdrOverlay = final: prev: {
            libultrahdr = prev.libultrahdr.overrideAttrs (old: {
              doCheck = false;
              doInstallCheck = false;
            } // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isPower {
              patches = (old.patches or [ ]) ++ [ ./patches/libultrahdr-generic-arch-fallback.patch ];
              cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DUHDR_ENABLE_INTRINSICS=0" ];
            });
          };
          # nix-lib's per-library fixes for the codecs ImageMagick pulls (as
          # chafa/flake.nix): libjxl lib-only, libheif decode-only.
          codecFixes = final: prev: {
            libjxl    = unpins-lib.lib.nativeFixes.libjxl    prev;
            libheif   = unpins-lib.lib.nativeFixes.libheif   prev;
            graphite2 = unpins-lib.lib.nativeFixes.graphite2 prev;
          };
          p = pkgs.pkgsStatic.extend (final: prev:
            (ddcutilOverlay final prev)
            // (codecFixes final prev)
            // (chafaOverlay final prev)
            // (imagemagickOverlay final prev)
            // (vulkanLoaderOverlay final prev)
            // (oclIcdOverlay final prev)
            // (potraceOverlay final prev)
            // (libultrahdrOverlay final prev)
          );
          dropDeps = [
            "libpulseaudio" "dconf"
            "libglvnd"
            "xfconf"
          ];
          # nixpkgs points CUSTOM_{PCI,AMDGPU}_IDS_PATH at hwdata/libdrm in the
          # store, and upstream feeds those to FF_STR() (CMakeLists passes them
          # to target_compile_definitions unquoted). Stringification expands
          # macros first, so the GNU predefined `linux` == 1 rewrites the path
          # to ".../hwdata-static-x86_64-unknown-1-musl-0.406/..." — a dead
          # path that nothing can open, and the only thing keeping a store
          # reference to hwdata alive in a binary meant to run off-store.
          # ENABLE_EMBEDDED_*IDS below carries both tables inside the binary,
          # so the file is a miss-path fallback anyway; without the flag it
          # falls back to upstream's /usr/share/hwdata/pci.ids, a real host
          # file. Dropped rather than quoted for that reason.
          dropCustomIdsPaths = builtins.filter
            (f: builtins.match "-DCUSTOM_(PCI|AMDGPU)_IDS_PATH.*" (toString f) == null);
          # dconfStatic: dconf's GSettings backend + engine + gvdb, built as
          # static archives against OUR pkgsStatic glib. nixpkgs marks
          # pkgsStatic.dconf badPlatforms.isStatic because its meson hardcodes
          # shared_library() for libdconf.so + the libdconfsettings.so gio
          # module (R_X86_64_32 vs hidden __TMC_END__ in musl-static). We drop
          # the unneeded shared/exe subdirs and turn the gsettings backend into
          # a static_library, then repack meson's thin archives into fat ones.
          #
          # Why this and not "dlopen host libgio": GSettings is backend-
          # pluggable; on GNOME the real data lives in the dconf backend, a
          # SEPARATE gio module (libdconfsettings.so) loaded by dlopen-scan —
          # NOT part of glib. A static glib only carries its built-in
          # memory/keyfile backends (defaults only). dlopen'ing the host module
          # drags a second host glib into the process → GType registry mismatch.
          # Embedding the dconf backend (built against our glib) and registering
          # it as a static gio module gives full GSettings fidelity (user db +
          # /etc/dconf system dbs + schema defaults + gnome-terminal profile)
          # with zero host .so. dconf_register_static_gsettings_backend() is an
          # exported helper we append (G_DEFINE_TYPE's get_type is hidden, and
          # the stock g_io_module_load derefs a GTypeModule → crashes on NULL).
          # Built from `p` (not raw pkgsStatic) so dconf's dbus -> libx11 dep
          # shares the one libx11 this flake's overlays produce, instead of
          # leaking a second, differently-overridden copy into the closure.
          dconfStatic = p.dconf.overrideAttrs (o: {
            pname = "dconf-static-libs";
            outputs = [ "out" ];
            meta = (o.meta or { }) // { badPlatforms = [ ]; };
            mesonFlags = (o.mesonFlags or [ ]) ++ [
              "-Dbash_completion=false" "-Dman=false" "-Dvapi=false" "-Dgtk_doc=false"
            ];
            patches = (o.patches or [ ]) ++ [ ./patches/dconf-static-gsettings-backend.patch ];
            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib $out/include/dconf
              # meson static_library emits thin archives referencing build-tree
              # .o; repack each as a fat archive from its <target>.a.p obj dir.
              for a in $(find . -name '*.a' ! -name '*-test*' ! -path '*tests*'); do
                objdir="$a.p"; base=$(basename "$a")
                if [ -d "$objdir" ]; then
                  "$AR" rcs "$out/lib/$base" "$objdir"/*.o
                fi
              done
              cp ../common/dconf-enums.h ../common/dconf-paths.h ../common/dconf-changeset.h $out/include/dconf/ || true
              cp ../engine/dconf-engine.h $out/include/dconf/ || true
              runHook postInstall
            '';
            dontFixup = true;
          });
          # darwin scope: only the codec overlays fastfetch's macOS backend
          # needs (chafa + imagemagick for logo rendering; potrace pulled by
          # imagemagick). None of the Linux foreign-dlopen / dconf / vulkan-
          # loader / wayland machinery applies on darwin, so it is left out.
          # pkgsStatic-darwin's own CC_FOR_BUILD is a cc wrapper driving ELF
          # ld.lld, so a package that compiles and RUNS a host gen-tool (gmp,
          # sqlite's jimsh) can't produce a runnable Mach-O with it. Point
          # CC_FOR_BUILD at $CC instead — valid only because build == host
          # there. Under a cross set that equality is exactly what's false:
          # $CC targets the foreign arch, jimsh comes out arm64 and the x86_64
          # builder can't run it ("./jimsh was built without -DHAVE_REALPATH").
          # nixpkgs already wires a correct build-host CC_FOR_BUILD when
          # cross-compiling, so gate on native and leave cross alone. Every
          # real target (x86_64-darwin, and aarch64-darwin native on macos-14)
          # is native, so this is identity on all of them — it only lets the
          # local ../build-aarch64-darwin cross check run.
          withDarwinBuildCC = drv:
            if !(pkgs.pkgsStatic.stdenv.buildPlatform.canExecute
                   pkgs.pkgsStatic.stdenv.hostPlatform)
            then drv
            else drv.overrideAttrs (o: {
              preConfigure = (o.preConfigure or "") + ''
                export CC_FOR_BUILD=$CC
              '';
            });
          pd = pkgs.pkgsStatic.extend (final: prev:
            (chafaOverlay final prev)
            // (codecFixes final prev)
            // (imagemagickOverlay final prev)
            // (potraceOverlay final prev)
            # darwin meson-subsystem fixes (nixos-26.05): glib 2.88.1
            # meson.build:84 does `host_machine.subsystem()`, which aborts
            # ("Subsystem not defined") whenever meson runs in cross mode.
            # On native x86_64-darwin the glib/pango objc cross-file forces
            # cross mode; on the CI Rosetta path the build is a genuine cross,
            # so every meson dep needs the complete [host_machine] cross-file.
            # Reuse nix-lib's per-package fixes (same set ffmpeg applies). Each
            # short-circuits to prev.X off-darwin, and pd is darwin-only. chafa
            # (autotools) pulls glib; the rest are lazy if not in the closure.
            // {
              glib       = unpins-lib.lib.nativeFixes.glib       prev;
              dav1d      = unpins-lib.lib.nativeFixes.dav1d      prev;
              fontconfig = unpins-lib.lib.nativeFixes.fontconfig prev;
              pango      = unpins-lib.lib.nativeFixes.pango      prev;
              cairo      = unpins-lib.lib.nativeFixes.cairo      prev;
              # imagemagick freezes MVDelegate/RMDelegate at ${coreutils}/bin/
              # {mv,rm} (--with-frozenpaths). Under pkgsStatic that coreutils is
              # coreutils-static, which links gmp-with-cxx-static, whose host
              # gen-tool fails CC_FOR_BUILD on darwin (vanilla cc wrapper drives
              # ELF ld.lld, can't emit a runnable Mach-O). The fix is the same
              # CC_FOR_BUILD=$CC used elsewhere (+ --disable-fat/--disable-
              # assembly: gmp's x86_64 mpn asm emits a rel8 branch ld64.lld
              # rejects, generic C mpn is identical). The point is to keep it
              # SCOPED to imagemagick's delegate coreutils: applying it set-wide
              # overrides a darwin stdenv requisite and forks the base bootstrap
              # → an uncached gnutar-1.35 whose test 155 (time01.at) fails on the
              # macos-14 arm64 runner. Scoped here, the stdenv's own gmp/coreutils
              # (native, in initialPath) are untouched, so the base gnutar stays
              # the cached catalog build. Same principle as fastfetch's sqlite arg.
              imagemagick = (imagemagickOverlay final prev).imagemagick.override {
                coreutils = prev.coreutils.override {
                  gmp = withDarwinBuildCC (prev.gmp.overrideAttrs (o: {
                    configureFlags = (o.configureFlags or [ ])
                      ++ [ "--disable-fat" "--disable-assembly" ];
                  }));
                };
              };
            }
          );

          # The foreign-dlopen TLS-swap trampoline only has get_tls() asm and
          # ld.so paths for x86_64 + aarch64 (helper.c #errors on any other
          # arch, systemLdSo{Glibc,Musl} throw). The secondary cross targets
          # mkStandaloneFlake publishes for every package — linux-i686,
          # linux-ppc64le, linux-riscv64, linux-armv7l — therefore can't use
          # it. On those we ship a lean static fastfetch (core detection only)
          # via the third branch below; the trampoline path stays on the two
          # arches it supports.
          useDlopen = pkgs.stdenv.hostPlatform.isx86_64
            || pkgs.stdenv.hostPlatform.isAarch64;
        in
        if pkgs.stdenv.hostPlatform.isDarwin
        then
        # fastfetch's nixpkgs postPatch bakes `${python3.interpreter}` into
        # the shell completions. Under pkgsStatic-darwin python3 is
        # meta.broken (static CPython doesn't build on darwin), aborting
        # eval. Override just fastfetch's python3 arg to the regular dynamic
        # darwin python3 (overriding it scope-wide breaks the stdenv
        # bootstrap — python3 is foundational). The reference is only a path
        # string in completion files the bin-only artifact doesn't ship.
        # Linux pkgsStatic python3 is fine, so this is darwin-only.
        # apple-sdk_15 = null: fastfetch buildInputs apple-sdk_15 (macosDeps),
        # which under pkgsStatic is apple-sdk-static — whose Csu crt is a
        # `clang -r` Mach-O relocatable link the engine's lld can't do (only
        # cctools ld does -r). The engine links crt-less and gets every SDK
        # header/framework via SDKROOT (-isysroot/-F), so this buildInput is
        # redundant. nix-lib's generic appleSdkOverride targets `apple-sdk`, not
        # the `apple-sdk_15` param fastfetch happens to use, so drop it here.
        # sqlite = withDarwinBuildCC: fastfetch links sqlite (sqliteSupport,
        # package counting) → sqlite-static, whose autosetup builds a jimsh0
        # host tool with CC_FOR_BUILD. Under pkgsStatic-darwin CC_FOR_BUILD is
        # the vanilla cc wrapper driving ELF ld.lld → "Cannot find a tclsh".
        # Native darwin build == host, so $CC is the builder cc. Scoped to
        # fastfetch's sqlite arg (php-style), NOT set-wide: a set-wide sqlite
        # override is a darwin stdenv requisite and forks the base bootstrap.
        ((pd.fastfetch.override {
          python3 = pkgs.buildPackages.python3;
          apple-sdk_15 = null;
          sqlite = withDarwinBuildCC pd.sqlite;
        }).overrideAttrs (old: {
          # darwin: fastfetch's macOS backend reads system info via Apple
          # frameworks (CoreFoundation/IOKit/SystemConfiguration/...) from
          # apple-sdk + sysctl — no foreign-dlopen trampoline needed (the
          # darwin allowlist permits libSystem + frameworks dynamic per
          # docs/dynamic-link-policy.md). Logo rendering keeps chafa +
          # imagemagick (codec-trimmed overlay). MoltenVK — the only Vulkan
          # provider on darwin — has no pkgsStatic build (badPlatforms), so
          # the Vulkan device-name line is off; the GPU is still detected via
          # IOKit/Metal in fastfetch's apple GPU module.
          #
          # fastfetch's macOS backend weak-links two Apple *PrivateFrameworks*
          # — DisplayServices (builtin-display brightness) and MediaRemote
          # (the now-playing Media module). The unpins darwin portability
          # contract normally allows only public /System/Library/Frameworks/*,
          # but these two genuinely have no public equivalent. Rather than drop
          # the features, fastfetch is granted a *scoped, per-package* exception
          # via `darwinAllowPrivateFrameworks` (declared at the mkStandaloneFlake
          # call below): the action-build portability check permits exactly
          # these two private frameworks for this package only — every other
          # package's contract stays strict. The symbols are FF_A_WEAK_IMPORT
          # + NULL-guarded, so they degrade gracefully if a future macOS drops
          # the framework.
          # No wrapProgram (see the Linux branches): the shipped artifact
          # must be the bare Mach-O (otool -L allowlist).
          postInstall = "";
          # MoltenVK lives in fastfetch's propagatedBuildInputs (buildInputs
          # is empty on darwin). Drop it there — it has no pkgsStatic build
          # (spirv-tools/MoltenVK static fails), and ENABLE_VULKAN=Off below
          # means fastfetch doesn't need it. GPU still comes from IOKit/Metal.
          propagatedBuildInputs = builtins.filter
            (x: (x.pname or x.name or "") != "MoltenVK")
            (old.propagatedBuildInputs or [ ]);
          # Link chafa, ImageMagick, sqlite3 and zlib from their static
          # archives. Upstream's default BINARY_LINK_TYPE=dlopen loads them
          # from the host at runtime (with an LC_RPATH to Homebrew's lib dirs),
          # so a Mac without Homebrew had no image logo. `dynamic` links what
          # CMake found and defines FF_DISABLE_DLOPEN; with only .a files in
          # this set the result is static. (`static` would add -static, which
          # macOS doesn't link.) zlib is added so pkg-config finds a static
          # one instead of the SDK's libz.tbd. pkg-config's Libs.private
          # supply the archives' own deps; -framework entries ride along.
          patches = (old.patches or [ ]) ++ [ ./patches/no-copy-dt-needed-entries.patch ];
          buildInputs = (old.buildInputs or [ ]) ++ [ pd.zlib ];
          preConfigure = (old.preConfigure or "") + ''
            pcs="chafa zlib MagickCore sqlite3"
            libs="$($PKG_CONFIG --static --libs-only-L $pcs) $($PKG_CONFIG --static --libs-only-l $pcs)"
            fws="$($PKG_CONFIG --static --libs-only-other $pcs | grep -oE 'framework[ ,][A-Za-z0-9_]+' | sed -E 's/^framework[ ,]/-framework /' | sort -u | tr '\n' ' ')"
            export NIX_LDFLAGS="$NIX_LDFLAGS $libs $fws"
          '';
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
            "-DBINARY_LINK_TYPE=dynamic"
            "-DENABLE_VULKAN=Off"
            "-DENABLE_IMAGEMAGICK7=On"
            "-DENABLE_IMAGEMAGICK6=Off"
            "-DENABLE_CHAFA=On"
            # Bare -lc++ for MagickCore.a's C++ deps (libultrahdr): it makes
            # the engine driver link its static libc++ (see the Linux branch
            # for why it can't ride NIX_LDFLAGS).
            "-DCMAKE_EXE_LINKER_FLAGS=-lc++"
          ];
        }))
        else if useDlopen
        then
        # python3 overridden to the plain build-host interpreter (like the
        # darwin branch): under the engine pkgsStatic.python3 is a CPython
        # --with-lto build that demands a standalone llvm-ar the engine cc
        # doesn't expose. fastfetch only bakes ${python3.interpreter} into
        # shell completions the bin-only artifact never ships.
        ((p.fastfetch.override { python3 = pkgs.buildPackages.python3; }).overrideAttrs (old: {
          # nixpkgs' postInstall wraps fastfetch with an LD_LIBRARY_PATH
          # prefix — pointless for a static 0-DT_NEEDED binary. It also
          # breaks the build: under the engine `wrapProgram` =
          # makeBinaryWrapper, which compiles the C wrapper with `-x c` from
          # stdin; the engine cc then appends the sysroot crt objects into
          # that still-open `-x c` scope, so clang tries to *compile* crt1.o
          # (-Werror,-Wnull-character on its ELF bytes).
          postInstall = "";
          propagatedBuildInputs = builtins.filter
            (x: !(builtins.elem (x.pname or x.name or "") dropDeps))
            (old.propagatedBuildInputs or [ ]);
          # Filter dropDeps out of buildInputs too: fastfetch 2.63.1 (26.05)
          # moved libpulseaudio/dconf/libglvnd/xfconf from propagatedBuildInputs
          # to buildInputs, so the propagated-only filter above no longer caught
          # them. libpulseaudio in particular is meta.badPlatforms on
          # musl-static (refuses to even evaluate). These are already disabled
          # at the feature level (ENABLE_PULSE/DCONF/XFCONF=Off; dconf replaced
          # by dconfStatic), so dropping the inputs is consistent, not new.
          buildInputs = (builtins.filter
            (x: !(builtins.elem (x.pname or x.name or "") dropDeps))
            (old.buildInputs or [ ]))
            ++ [
              p.libdrm.dev
              p.dbus.dev
              p.libxcb.dev
              p.libxrandr.dev
              p.glib.dev
              p.ddcutil
              # libexecinfo: ddcutil.a calls backtrace() (segv handler); musl
              # has no execinfo, so the static link needs -lexecinfo + its -L.
              p.libexecinfo
              # xfce4util: XFCE version detection. fastfetch stubs it out under
              # FF_DISABLE_DLOPEN ("dlopen is disabled"); we patch de_linux.c to
              # call xfce_version_string() directly and link this .a statically.
              p.xfce.libxfce4util.dev
              p.imagemagick.dev
              p.chafa.dev
              p.vulkan-loader.dev
              p.ocl-icd
              # Round 9: libwayland-client static (resolveu crash em Wayland
              # session via trampoline). Outras libs continuam via trampoline
              # — chain-LTO transitive pra static-all não fechou em playground
              # (overlay no pkgsStatic disparou rebuild de stdenv musl); fica
              # como work pra nix-lib futuro.
              p.wayland.dev
              # Headers and .pc only (OpenGL, Sound): both libraries are
              # dlopen'ed from the host through the trampoline, never linked.
              pkgs.libglvnd.dev
              pkgs.libpulseaudio.dev
            ];
          patches = (old.patches or [ ]) ++ [
            ./patches/linux-static-link-per-tu.patch
            ./patches/pulse-callbacks-native-tls.patch
            ./patches/register-dconf-backend.patch
          ];
          preConfigure = (old.preConfigure or "") + ''
            mkdir -p build
            cp ${p.hwdata}/share/hwdata/pci.ids build/pci.ids
            cp ${p.libdrm}/share/libdrm/amdgpu.ids build/amdgpu.ids
            chmod +w build/pci.ids build/amdgpu.ids
            # linux-static-link-per-tu.patch makes these libraries' references
            # direct; link them from their static archives (-L/-l only:
            # pkg-config's "other" flags are compiler-driver flags ld rejects,
            # and pthread lives in musl's libc).
            #
            # MagickCore.a pulls C++ transitive deps (e.g. libultrahdr), so the
            # otherwise-C binary needs the C++ runtime. Under the engine that is
            # libc++ (not libstdc++, absent from the sysroot). It is NOT added
            # here: a bare -lc++ is what flips the unpin driver's C++-link
            # detection (which then emits --start-group -lc++ -lc++abi -lunwind
            # --end-group), but the cc-wrapper rewrites every non "-L/" entry of
            # NIX_LDFLAGS to "-Wl,<flag>", so "-lc++" would reach the driver as
            # "-Wl,-lc++" — invisible to the detector and unresolved by ld (it
            # even breaks the CMake C-compiler check). Instead -lc++ is passed
            # bare via CMAKE_EXE_LINKER_FLAGS below (cmake puts it straight on
            # the link line). MagickCore's -L/-l still ride NIX_LDFLAGS fine.
            logoLibs="$($PKG_CONFIG --static --libs-only-L chafa zlib MagickCore) $($PKG_CONFIG --static --libs-only-l chafa zlib MagickCore)"
            export NIX_LDFLAGS="$NIX_LDFLAGS $logoLibs"

            # libdrm_amdgpu is a separate .pc/.a from libdrm. ddcutil.a drags a
            # closure that ddcutil.pc does NOT declare (its Requires line is
            # commented out, Libs is just -lddcutil): glib-2.0, jansson, libacl,
            # gudev-1.0, libusb-1.0, libudev, and backtrace (libexecinfo on
            # musl) — list them all.
            restPcs="dbus-1 ddcutil libdrm libdrm_amdgpu glib-2.0 jansson libacl gudev-1.0 libusb-1.0 libudev xcb-randr xrandr libelf libxfce4util-1.0"
            restLibs="$($PKG_CONFIG --static --libs-only-L $restPcs) $($PKG_CONFIG --static --libs-only-l $restPcs)"
            export NIX_LDFLAGS="$NIX_LDFLAGS $restLibs -lexecinfo"

            # settings.c's GSettings, GVariant and sqlite3 refs are direct, and
            # the dconf backend comes from dconfStatic (registered at main() by
            # register-dconf-backend.patch). ($PKG_CONFIG is the cross wrapper;
            # bare `pkg-config` isn't on PATH in pkgsStatic.)
            gtkLibs="$($PKG_CONFIG --static --libs-only-L gio-2.0 gio-unix-2.0 sqlite3) $($PKG_CONFIG --static --libs-only-l gio-2.0 gio-unix-2.0 sqlite3)"
            export NIX_LDFLAGS="$NIX_LDFLAGS -L${dconfStatic}/lib -l:libdconfsettings.a -l:libdconf-engine.a -l:libdconf-gdbus-thread.a -l:libdconf-common.a -l:libgvdb.a -l:libdconf-shm.a $gtkLibs"
          '';
          # Round 9: -l:libwayland-client.a força static-pull mesmo com
          # BINARY_LINK_TYPE=dlopen (CMake default, mantido). Resolve crash
          # de libwayland-client carregado via trampoline em sessão Wayland.
          # libffi: dep transitive de libwayland (protocol marshalling).
          # Trampoline continua pra libvulkan/libOpenCL/libdbus/libchafa/etc.
          NIX_LDFLAGS = "-L${tlsTrampoline}/lib -l:foreign_dlopen.a -l:libwayland-client.a -lffi --wrap=dlopen --wrap=dlsym --wrap=dlclose --wrap=dlerror";
          cmakeFlags = (dropCustomIdsPaths (old.cmakeFlags or [ ])) ++ [
            "-DENABLE_EMBEDDED_PCIIDS=On"
            "-DENABLE_EMBEDDED_AMDGPUIDS=On"
            # Round 8: ICD-loader status pending validation. Round 7 verified
            # __wrap_dlopen/dlsym return valid pointers, but the first call
            # via the returned pointer SIGSEGV'd at si_addr=0xfffffffffffffffe
            # (TLS slot the lib expected but musl never set up). Round 8's
            # trampoline switches FS via arch_prctl on every call so libvulkan
            # sees a "real" glibc TLS at call time. Smoke target.
            "-DENABLE_VULKAN=On"
            "-DENABLE_OPENCL=On"
            "-DENABLE_EGL=On"
            "-DENABLE_GLX=On"
            "-DENABLE_XCB_RANDR=On"
            "-DENABLE_XRANDR=On"
            "-DENABLE_WAYLAND=On"
            "-DENABLE_DRM=On"
            "-DENABLE_DRM_AMDGPU=On"
            "-DENABLE_DBUS=On"
            "-DENABLE_PULSE=On"
            "-DENABLE_DCONF=Off"
            "-DENABLE_GIO=On"
            "-DENABLE_DDCUTIL=On"
            "-DENABLE_IMAGEMAGICK7=On"
            "-DENABLE_IMAGEMAGICK6=Off"
            "-DENABLE_CHAFA=On"
            # Bare -lc++ (not via NIX_LDFLAGS — see preConfigure) so the engine
            # cc driver detects a C++ link and pulls libc++/libc++abi/libunwind
            # for MagickCore.a's C++ deps. cmake places it directly on the link
            # line, unwrapped, unlike NIX_LDFLAGS' "-Wl,"-prefixed entries.
            "-DCMAKE_EXE_LINKER_FLAGS=-lc++"
          ];
        }))
        else
        # Static-link branch — linux-i686 / ppc64le / riscv64 / armv7l.
        # The foreign-dlopen TLS-swap trampoline has get_tls() asm only for
        # x86_64/aarch64 (see useDlopen), so these secondary cross targets
        # can't dlopen host libs at runtime. Instead we use fastfetch's own
        # BINARY_LINK_TYPE=static mode: it sets FF_DISABLE_DLOPEN globally and
        # links each found lib's .a straight into the binary. The static deps
        # are the same ones the primary targets build (and that chafa/jxl
        # already ship green on every one of these crosses), so the feature
        # set matches the primary targets — except Vulkan/OpenCL/EGL/GLX,
        # which load the *host* GPU ICD/driver at runtime and so genuinely
        # need dlopen (there is no .a to link — the driver is host-specific).
        # GPU name/vendor still resolves here via /sys/class/drm + the
        # embedded pci.ids (libdrm-free path), so only GPU compute/render API
        # detail is lost on these arches.
        # python3 overridden to the plain build-host interpreter (like the
        # darwin branch): under the engine pkgsStatic.python3 is a CPython
        # --with-lto build that demands a standalone llvm-ar the engine cc
        # doesn't expose. fastfetch only bakes ${python3.interpreter} into
        # shell completions the bin-only artifact never ships.
        ((p.fastfetch.override { python3 = pkgs.buildPackages.python3; }).overrideAttrs (old: {
          # No wrapProgram (see the useDlopen branch).
          postInstall = "";
          propagatedBuildInputs = builtins.filter
            (x: !(builtins.elem (x.pname or x.name or "") dropDeps))
            (old.propagatedBuildInputs or [ ]);
          # Same static deps as the primary Linux branch, minus vulkan-loader
          # and ocl-icd (host-ICD; can't be static-linked). All others link
          # their .a directly under BINARY_LINK_TYPE=static.
          buildInputs = (builtins.filter
            (x: !(builtins.elem (x.pname or x.name or "") dropDeps))
            (old.buildInputs or [ ]))
            ++ [
              p.libdrm.dev
              p.dbus.dev
              p.libxcb.dev
              p.libxrandr.dev
              p.glib.dev
              p.ddcutil
              # libexecinfo: ddcutil.a's backtrace() dep (its .pc carries
              # -lexecinfo in Libs.private; this provides the -L).
              p.libexecinfo
              p.imagemagick.dev
              p.chafa.dev
              p.wayland.dev
            ];
          patches = (old.patches or [ ]) ++ [
            ./patches/no-copy-dt-needed-entries.patch
            ./patches/register-dconf-backend.patch
          ];
          preConfigure = (old.preConfigure or "") + ''
            mkdir -p build
            cp ${p.hwdata}/share/hwdata/pci.ids build/pci.ids
            cp ${p.libdrm}/share/libdrm/amdgpu.ids build/amdgpu.ids
            chmod +w build/pci.ids build/amdgpu.ids
            # GSettings (theme/icons/font/cursor/WMTheme) via the embedded
            # static dconf backend — same as the primary targets.
            # BINARY_LINK_TYPE=static already direct-links settings.c's
            # glib/gio/sqlite3 refs.
            gtkLibs="$($PKG_CONFIG --static --libs-only-L gio-2.0 gio-unix-2.0 sqlite3) $($PKG_CONFIG --static --libs-only-l gio-2.0 gio-unix-2.0 sqlite3)"
            # C++ runtime (libc++) for MagickCore.a's C++ deps is passed bare
            # via CMAKE_EXE_LINKER_FLAGS below, NOT here: the cc-wrapper "-Wl,"-
            # prefixes every non "-L/" NIX_LDFLAGS entry, so "-lc++" would arrive
            # as "-Wl,-lc++" and never trip the engine driver's C++-link detector
            # (which is what pulls the c++/c++abi/unwind group). -lstdc++ isn't
            # in the sysroot either. dconf/gtk -L/-l still ride NIX_LDFLAGS fine.
            export NIX_LDFLAGS="$NIX_LDFLAGS -L${dconfStatic}/lib -l:libdconfsettings.a -l:libdconf-engine.a -l:libdconf-gdbus-thread.a -l:libdconf-common.a -l:libgvdb.a -l:libdconf-shm.a $gtkLibs"
          '';
          cmakeFlags = (dropCustomIdsPaths (old.cmakeFlags or [ ])) ++ [
            # link our static .a deps into the binary instead of dlopen'ing
            "-DBINARY_LINK_TYPE=static"
            "-DENABLE_EMBEDDED_PCIIDS=On"
            "-DENABLE_EMBEDDED_AMDGPUIDS=On"
            "-DENABLE_XCB_RANDR=On"
            "-DENABLE_XRANDR=On"
            "-DENABLE_WAYLAND=On"
            "-DENABLE_DRM=On"
            "-DENABLE_DRM_AMDGPU=On"
            "-DENABLE_DBUS=On"
            "-DENABLE_GIO=On"
            "-DENABLE_DCONF=Off"
            "-DENABLE_DDCUTIL=On"
            "-DENABLE_IMAGEMAGICK7=On"
            "-DENABLE_IMAGEMAGICK6=Off"
            "-DENABLE_CHAFA=On"
            # host-ICD/driver — genuinely need runtime dlopen, no .a to link
            "-DENABLE_VULKAN=Off"
            "-DENABLE_OPENCL=Off"
            "-DENABLE_EGL=Off"
            "-DENABLE_GLX=Off"
            "-DENABLE_PULSE=Off"
            # Bare -lc++ (not via NIX_LDFLAGS — see preConfigure) so the engine
            # cc driver detects a C++ link and pulls libc++/libc++abi/libunwind
            # for MagickCore.a's C++ deps. cmake places it directly on the link
            # line, unwrapped, unlike NIX_LDFLAGS' "-Wl,"-prefixed entries.
            "-DCMAKE_EXE_LINKER_FLAGS=-lc++"
          ];
        }));
    };
}
