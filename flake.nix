{
  description = "Standalone build of fastfetch";

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

  # The fdlhelper has to be glibc-dynamically-linked against a glibc whose
  # symbols are a superset of what host libraries need at runtime. The
  # unpins-lib pin (~Sep 2025, glibc 2.40-224) is older than what most
  # current Linux distros / NixOS configurations ship; libvulkan on host
  # boxes is generally built against glibc 2.42+, and dlopen'ing it from
  # a 2.40 helper fails on symbol-version lookup. We source the helper
  # from nixos-unstable for a recent glibc — and then polyfill-glibc the
  # resulting binary back down to a 2.17 floor (covers CentOS 7+ vintage),
  # so the helper runs on any modern-enough distro.
  inputs.nixpkgs-recent.url = "github:NixOS/nixpkgs/nixos-unstable";

  # polyfill-glibc (corsix): rewrites .gnu.version_r so the helper can run
  # against older glibc than it was built with. Same tool upstream fastfetch
  # uses for its `*-polyfilled.tar.gz` release artifacts. Built inline since
  # nixpkgs doesn't ship it. C11 + ninja.
  inputs.polyfill-glibc-src = {
    url = "github:corsix/polyfill-glibc/dd59051faaa10ee63c1b96f1b47bf9fcd3770ee2";
    flake = false;
  };

  outputs = { self, unpins-lib, graphicsgd-src, nixpkgs-recent, polyfill-glibc-src }:
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "fastfetch";
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
      build = pkgs:
        let
          # Native build (incl. CI's aarch64 arm runner): build==host, so
          # legacyPackages.<system> — byte-identical to the original. When
          # cross-compiling (e.g. the local build-aarch64-linux helper on an
          # x86_64 box), instantiate recentPkgs as a *cross* set so its
          # buildPackages tools (polyfill-glibc, ninja) run on the build host
          # while glibcHelper's fdlhelper still targets the host arch.
          recentPkgs =
            if pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system
            then nixpkgs-recent.legacyPackages.${pkgs.stdenv.hostPlatform.system}
            else import nixpkgs-recent {
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

          # Replacement foreign_compile() body for dlopen.c. Upstream's
          # version posix_spawn'd `cc` at runtime to compile the HELPER
          # macro from in-memory C source. We skip that entirely.
          #
          # First-choice path: memfd_create — write the embedded helper
          # bytes to an anonymous in-memory file, then hand elf_exec the
          # /proc/self/fd/N path. Zero disk write. The fd is leaked on
          # purpose: it must outlive foreign_compile() so that elf_exec
          # can open() the proc-fd path; process exit clears it.
          #
          # Fallback path (kernel < 3.17 or seccomp blocks memfd_create):
          # extract to /tmp/.musl_dlopen_helper/helper. mtime-cache so
          # repeated runs of the same fastfetch binary skip the write.
          # /tmp chosen over $HOME because it's typically tmpfs (cleans
          # up at reboot) and the helper is ephemeral per-session.
          foreignCompileBody = builtins.toFile "foreign_compile_body.c" ''
            extern unsigned char glibc_helper_data[];
            extern unsigned int  glibc_helper_data_len;
            extern unsigned char musl_helper_data[];
            extern unsigned int  musl_helper_data_len;

            /*
             * Pick the embedded helper that matches the host's libc.
             * Signal = presence of the canonical ld.so for each libc:
             *   /lib64/ld-linux-x86-64.so.2 (glibc x86_64)
             *   /lib/ld-linux-aarch64.so.1  (glibc aarch64)
             *   /lib/ld-musl-x86_64.so.1    (musl  x86_64)
             *   /lib/ld-musl-aarch64.so.1   (musl  aarch64)
             * glibc-first because hybrid systems (gcompat, chimera) ship
             * glibc compat and we'd rather load the more-portable glibc
             * libs there. Returns 0 if no known libc is detected.
             */
            static int pick_helper(unsigned char **data, unsigned int *len) {
            #if defined(__x86_64__)
              if (access("/lib64/ld-linux-x86-64.so.2", F_OK) == 0) {
                *data = glibc_helper_data; *len = glibc_helper_data_len; return 1;
              }
              if (access("/lib/ld-musl-x86_64.so.1", F_OK) == 0) {
                *data = musl_helper_data; *len = musl_helper_data_len; return 1;
              }
            #elif defined(__aarch64__)
              if (access("/lib/ld-linux-aarch64.so.1", F_OK) == 0) {
                *data = glibc_helper_data; *len = glibc_helper_data_len; return 1;
              }
              /* aarch64 musl helper not built yet — ld-musl-aarch64.so.1
                 detection would route to a 1-byte placeholder, so skip it. */
            #endif
              return 0;
            }

            static bool foreign_compile(char exe[PATH_MAX]) {
              unsigned char *data; unsigned int len;
              if (!pick_helper(&data, &len)) return false;

              int memfd = memfd_create("dlopen_helper", 0);
              if (memfd >= 0) {
                ssize_t off = 0;
                while (off < (ssize_t)len) {
                  ssize_t r = write(memfd, data + off, len - off);
                  if (r < 0) { close(memfd); goto disk_fallback; }
                  off += r;
                }
                snprintf(exe, PATH_MAX, "/proc/self/fd/%d", memfd);
                return true;
              }
            disk_fallback:
              my_strlcpy(exe, "/tmp/.musl_dlopen_helper", PATH_MAX);
              if (mkdir(exe, 0755) && errno != EEXIST) return false;
              my_strlcat(exe, "/helper", PATH_MAX);
              switch (is_file_newer_than(get_program_executable_name(), exe)) {
                case 0: return true;
                case 1: case 2: break;
                default: return false;
              }
              char tmp[PATH_MAX];
              my_strlcpy(tmp, exe, PATH_MAX);
              my_strlcat(tmp, ".tmpXXXXXX", PATH_MAX);
              int tmpfd = mkstemp(tmp);
              if (tmpfd == -1) return false;
              ssize_t w = write(tmpfd, data, len);
              fchmod(tmpfd, 0755);
              close(tmpfd);
              if (w != (ssize_t)len) { unlink(tmp); return false; }
              if (rename(tmp, exe) == -1) { unlink(tmp); return false; }
              return true;
            }
          '';

          # polyfillGlibc: tool that rewrites a binary's glibc symbol-version
          # references to target an older floor. Self-contained C11 + ninja
          # build from upstream sources.
          # Build-time tool: it rewrites a target binary's ELF version
          # records (arch-agnostic), so it must run on the *build host*, not
          # the target. Using recentPkgs.stdenv would build it for the target
          # arch — fine natively (build==host) but unbuildable when cross-
          # compiling (e.g. aarch64-linux from x86_64) without an arm builder.
          # buildPackages.stdenv pins it to the build host; identical natively.
          polyfillGlibc = recentPkgs.buildPackages.stdenv.mkDerivation {
            pname = "polyfill-glibc";
            version = "dd59051";
            src = polyfill-glibc-src;
            nativeBuildInputs = [ recentPkgs.buildPackages.ninja ];
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
          # (Debian/Ubuntu/RHEL/Arch/Fedora/etc). Built against recentPkgs
          # glibc 2.42+, then polyfilled down to a 2.17 floor (CentOS 7
          # vintage). See [[feedback_polyfill_glibc_fixup_trap]] for why
          # dontPatchELF/dontStrip are required.
          glibcHelper = recentPkgs.stdenv.mkDerivation {
            pname = "graphicsgd-glibc-helper";
            version = "07c79b4";
            dontUnpack = true;
            nativeBuildInputs = [ polyfillGlibc recentPkgs.patchelf ];
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
          # (Alpine, Chimera, Void-musl, etc). Built via pkgsCross.musl64
          # (x86_64 only for now — aarch64 musl cross is a different attr
          # and the Alpine arm64 user base is smaller). No polyfill needed
          # — musl pledges ABI stability across releases, so a 1.2.x helper
          # runs on any Alpine 3.16+ vintage.
          muslHelper =
            if pkgs.stdenv.hostPlatform.isx86_64 then
              pkgs.pkgsCross.musl64.stdenv.mkDerivation {
                pname = "graphicsgd-musl-helper";
                version = "07c79b4";
                dontUnpack = true;
                nativeBuildInputs = [ pkgs.pkgsCross.musl64.buildPackages.patchelf ];
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
              }
            else
              # aarch64 musl cross-build path not yet wired. Embed a 1-byte
              # placeholder so xxd-i emits a valid C symbol; foreign_compile
              # never references it because the aarch64 detection branch
              # only checks the glibc ld.so path (see foreignCompileBody).
              pkgs.runCommand "musl-helper-placeholder" { } ''
                mkdir -p $out/bin
                printf '\0' > $out/bin/fdlhelper
              '';

          # tlsTrampoline: static archive built from graphics.gd's dlopen.c
          # + foreign_tramp.S + the xxd-i'd fdlhelper bytes. Patches applied
          # at postPatch (see comments inline):
          #   1. Drop the HELPER macro (no runtime-cc compilation; helper
          #      is embedded pre-built)
          #   2. Replace foreign_compile() with embed-extract version
          #   3. Rename public dlopen→__wrap_dlopen (etc.) so linker
          #      --wrap=NAME flags route fastfetch's POSIX calls through
          #      our patched impl
          tlsTrampoline = pkgs.pkgsStatic.stdenv.mkDerivation {
            pname = "graphicsgd-dlopen-static";
            version = "07c79b4";
            src = graphicsgd-src;
            sourceRoot = "source/startup/internal/dlopen";
            nativeBuildInputs = [ pkgs.xxd ];
            postPatch = ''
              # 1. Embed both pre-built helpers via xxd -i. The static
              #    main binary detects host libc at first dlopen and
              #    extracts whichever helper matches.
              cp ${glibcHelper}/bin/fdlhelper glibc_helper
              xxd -i -n glibc_helper_data glibc_helper > glibc_helper_data.c
              cp ${muslHelper}/bin/fdlhelper musl_helper
              xxd -i -n musl_helper_data musl_helper > musl_helper_data.c

              # 2. Strip HELPER macro from dlopen.c (no longer used; the
              #    embed-extract foreign_compile we insert next reads bytes).
              sed -i '/^#define HELPER \\$/,/^  "}\\n"$/d' dlopen.c

              # 3. Strip the runtime-cc foreign_compile() body.
              sed -i '/^static bool foreign_compile(char exe\[PATH_MAX\]) {$/,/^}$/d' dlopen.c

              # 4. Insert our embed-extract foreign_compile() right before
              #    the foreign_setup() that calls it. Uses an awk getline
              #    loop to splice contents of foreignCompileBody verbatim.
              awk -v insert='${foreignCompileBody}' '
                /^static void foreign_setup\(void\) \{$/ && !done {
                  while ((getline line < insert) > 0) print line
                  close(insert)
                  done = 1
                }
                { print }
              ' dlopen.c > dlopen.c.new
              mv dlopen.c.new dlopen.c

              # 5. Rename public dlopen/dlsym/dlclose/dlerror → __wrap_*.
              #    fastfetch's library.h emits POSIX dlopen/dlsym/dlclose
              #    calls; linker --wrap=NAME rewrites them to __wrap_NAME,
              #    which our patched dlopen.c now provides. Other public
              #    APIs (dlsym_raw, dlopen_callback_*, dlopen_set_*) keep
              #    their names — fastfetch doesn't call them.
              sed -i \
                -e 's|^void \*dlopen(const char \*path, int mode) {$|void *__wrap_dlopen(const char *path, int mode) {|' \
                -e 's|^void \*dlsym(void \*handle, const char \*name) {$|void *__wrap_dlsym(void *handle, const char *name) {|' \
                -e 's|^int dlclose(void \*handle) {$|int __wrap_dlclose(void *handle) {|' \
                -e 's|^char \*dlerror(void) {$|char *__wrap_dlerror(void) {|' \
                dlopen.c
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
          # Sed troca SHARED→STATIC na linha do else-Linux.
          vulkanLoaderOverlay = final: prev: {
            vulkan-loader = prev.vulkan-loader.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                substituteInPlace loader/CMakeLists.txt \
                  --replace-fail "add_library(vulkan SHARED)" \
                                 "add_library(vulkan STATIC)" \
                  --replace-fail "install(TARGETS vulkan EXPORT VulkanLoaderConfig)" \
                                 "install(TARGETS vulkan)" \
                  --replace-fail "install(EXPORT VulkanLoaderConfig DESTINATION \''${CMAKE_INSTALL_LIBDIR}/cmake/VulkanLoader NAMESPACE Vulkan::)" \
                                 ""
              '';
            });
          };
          # ocl-icd 2.3.4: Makefile.am builda `noinst_PROGRAMS=run_dummy_
          # icd_through_our_ICDL` que linka contra libOpenCL.a (forte)
          # JUNTO com `run_dummy_icd_weak_gen.o` (mesmas funções, weak).
          # Em glibc/shared, ld resolve weak<strong via versioning. Em
          # musl-static, ld é estrito → "multiple definition" pra ~600
          # funções OpenCL. Esses noinst são só pra UPDATE_DATABASE
          # workflow do upstream, fastfetch não usa. Esvazia o var.
          oclIcdOverlay = final: prev: {
            ocl-icd = prev.ocl-icd.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                # Esvaziar noinst_PROGRAMS e deletar todo o bloco
                # `if UPDATE_DATABASE … endif` (que referencia o test
                # binary deletado e que automake -Werror não aceita
                # sintaxe órfã). Sed range entre marcadores.
                sed -i \
                  -e 's|^noinst_PROGRAMS=run_dummy_icd_through_our_ICDL|noinst_PROGRAMS =|' \
                  -e '/run_dummy_icd_through_our_ICDL/d' \
                  -e '/^[[:space:]]*run_dummy_icd_gen\.c run_dummy_icd_weak_gen\.c$/d' \
                  -e '/^if UPDATE_DATABASE$/,/^endif$/d' \
                  Makefile.am
              '';
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
          # ImageMagick: cortar 19 codec supports pra evitar a cadeia
          # de overlays profunda (~10+ patches) requerida pra full-codec
          # em musl-static. Ver
          # [[feedback_pkgsstatic_imagemagick_chain_patches]] pra
          # inventário. fastfetch precisa só de decode PNG/JPEG pra logo.
          imagemagickOverlay = final: prev: {
            imagemagick = (prev.imagemagick.override {
              bzip2Support = false;
              fontconfigSupport = false;
              freetypeSupport = false;
              djvulibreSupport = false;
              lcms2Support = false;
              openexrSupport = false;
              libjxlSupport = false;
              liblqr1Support = false;
              libraqmSupport = false;
              librawSupport = false;
              librsvgSupport = false;
              libtiffSupport = false;
              libxml2Support = false;
              openjpegSupport = false;
              libheifSupport = false;
              libX11Support = false;
              libXtSupport = false;
              libwebpSupport = false;
              fftwSupport = false;
            }).overrideAttrs (old:
              # darwin: imagemagick still links libxml2.a (core config
              # parsing), whose encoding.o references iconv_open. On darwin
              # iconv lives in a separate libiconv (not libc as on glibc/musl),
              # and imagemagick's static link omits -liconv -> "_iconv_open
              # symbol(s) not found". Add libiconv + -liconv. darwin-only;
              # linux/musl carry iconv in libc so this stays off there.
              prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
                buildInputs = (old.buildInputs or [ ]) ++ [ final.libiconv ];
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
              postPatch = (old.postPatch or "") + ''
                substituteInPlace CMakeLists.txt \
                  --replace-fail 'message(FATAL_ERROR "Architecture: ''${CMAKE_SYSTEM_PROCESSOR} not recognized")' \
                                 'set(ARCH "generic")'
              '';
              cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DUHDR_ENABLE_INTRINSICS=0" ];
            });
          };
          # libjpeg-turbo (pulled via imagemagick's JPEG reader) miscompiles its
          # `simdcoverage` helper on riscv64 (RVV port misses a jsimd_can_*
          # decl). Reuse the catalog's shared nativeFix — same one avif /
          # libwebp / jpeg-tools apply, gated to riscv — which drops only the
          # unused helper and keeps the RVV SIMD in libjpeg.a. Identity off riscv.
          libjpegturboOverlay = final: prev:
            prev.lib.optionalAttrs prev.stdenv.hostPlatform.isRiscV {
              libjpeg = unpins-lib.lib.nativeFixes."libjpeg-turbo" prev;
            };
          p = pkgs.pkgsStatic.extend (final: prev:
            (ddcutilOverlay final prev)
            // (chafaOverlay final prev)
            // (imagemagickOverlay final prev)
            // (vulkanLoaderOverlay final prev)
            // (oclIcdOverlay final prev)
            // (potraceOverlay final prev)
            // (libultrahdrOverlay final prev)
            // (libjpegturboOverlay final prev)
          );
          dropDeps = [
            "libpulseaudio" "dconf"
            "libglvnd"
            "xfconf"
            # efl (Enlightenment Foundation Libraries): new buildInput in
            # fastfetch 2.63.1 (26.05), used only to detect the Enlightenment
            # desktop/WM. It propagates libpulseaudio (meta.badPlatforms on
            # musl-static -> refuses to evaluate) and is a heavy multimedia
            # stack. Enlightenment is a niche DE; drop it (user-approved
            # 2026-06-04). All other DE/WM detection (GNOME/KDE/wlroots/...)
            # is unaffected.
            "efl"
          ];
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
          dconfStatic = pkgs.pkgsStatic.dconf.overrideAttrs (o: {
            pname = "dconf-static-libs";
            outputs = [ "out" ];
            meta = (o.meta or { }) // { badPlatforms = [ ]; };
            mesonFlags = (o.mesonFlags or [ ]) ++ [
              "-Dbash_completion=false" "-Dman=false" "-Dvapi=false" "-Dgtk_doc=false"
            ];
            postPatch = (o.postPatch or "") + ''
              sed -i \
                -e "/subdir('service')/d" \
                -e "/subdir('bin')/d" \
                -e "/subdir('docs')/d" \
                -e "/subdir('tests')/d" \
                -e "/subdir('client')/d" \
                -e "/meson.add_install_script/d" \
                meson.build
              sed -i \
                -e "s/shared_library(/static_library(/" \
                -e "/install: true,/d" \
                -e "/install_dir: gio_module_dir,/d" \
                -e "/link_args: ldflags,/d" \
                -e "/link_depends: symbol_map,/d" \
                -e "s/c_args: dconf_c_args,/c_args: dconf_c_args, pic: true,/" \
                gsettings/meson.build
              {
                printf '\n__attribute__((visibility("default")))\n'
                printf 'void dconf_register_static_gsettings_backend (void) {\n'
                printf '  g_io_extension_point_register (G_SETTINGS_BACKEND_EXTENSION_POINT_NAME);\n'
                printf '  g_io_extension_point_implement (G_SETTINGS_BACKEND_EXTENSION_POINT_NAME,\n'
                printf '                                  dconf_settings_backend_get_type (),\n'
                printf '                                  "dconf", 100);\n}\n'
              } >> gsettings/dconfsettingsbackend.c
            '';
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
          pd = pkgs.pkgsStatic.extend (final: prev:
            (chafaOverlay final prev)
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
              graphite2  = unpins-lib.lib.nativeFixes.graphite2  prev;
              fontconfig = unpins-lib.lib.nativeFixes.fontconfig prev;
              pango      = unpins-lib.lib.nativeFixes.pango      prev;
              cairo      = unpins-lib.lib.nativeFixes.cairo      prev;
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
        ((pd.fastfetch.override { python3 = pkgs.buildPackages.python3; }).overrideAttrs (old: {
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
          postFixup = ''
            if [ -e $out/bin/.fastfetch-wrapped ]; then
              mv -f $out/bin/.fastfetch-wrapped $out/bin/fastfetch
            fi
          '' + (old.postFixup or "");
          # MoltenVK lives in fastfetch's propagatedBuildInputs (buildInputs
          # is empty on darwin). Drop it there — it has no pkgsStatic build
          # (spirv-tools/MoltenVK static fails), and ENABLE_VULKAN=Off below
          # means fastfetch doesn't need it. GPU still comes from IOKit/Metal.
          propagatedBuildInputs = builtins.filter
            (x: (x.pname or x.name or "") != "MoltenVK")
            (old.propagatedBuildInputs or [ ]);
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
            "-DENABLE_VULKAN=Off"
            "-DENABLE_IMAGEMAGICK7=On"
            "-DENABLE_IMAGEMAGICK6=Off"
            "-DENABLE_CHAFA=On"
          ];
        }))
        else if useDlopen
        then
        (p.fastfetch.overrideAttrs (old: {
          # nixpkgs wraps fastfetch with `makeWrapper` for system-PATH
          # niceties (pciutils/dmidecode lookup, etc) — that wrapper is
          # dynamically linked and points at /nix/store paths absent on
          # the user's host. Move the real static binary on top of it
          # so the shipped artifact is the bare ELF.
          postFixup = ''
            if [ -e $out/bin/.fastfetch-wrapped ]; then
              mv -f $out/bin/.fastfetch-wrapped $out/bin/fastfetch
            fi
          '' + (old.postFixup or "");
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
            ];
          preConfigure = (old.preConfigure or "") + ''
            mkdir -p build
            cp ${p.hwdata}/share/hwdata/pci.ids build/pci.ids
            cp ${p.libdrm}/share/libdrm/amdgpu.ids build/amdgpu.ids
            chmod +w build/pci.ids build/amdgpu.ids
            # Round 9: força wayland.c em static-mode via FF_DISABLE_DLOPEN
            # (vê library.h branch #else). Outros TUs continuam em dlopen-mode
            # (struct shape idêntica). Linker pulls libwayland-client.a via
            # NIX_LDFLAGS -l:libwayland-client.a abaixo.
            sed -i '1i #define FF_DISABLE_DLOPEN 1' \
              src/detection/displayserver/linux/wayland/wayland.c

            # Round 10: make the binary truly self-contained — static-link the
            # self-contained optional libs (FF_DISABLE_DLOPEN per-TU) instead
            # of dlopen'ing them from the host. Only the host GPU driver/ICD
            # libs (vulkan/opencl/egl/glx/nvidia-ml/mtml) stay dlopen via the
            # trampoline below — those are machine-specific, can't be bundled.
            # Logo: image.c loads BOTH chafa and zlib; im7.c loads MagickCore.
            # zlib is also loaded by lm_linux.c (display-manager) and
            # networking_common.c (gzip decode) — same static libz.a covers all.
            sed -i '1i #define FF_DISABLE_DLOPEN 1' src/logo/image/image.c
            sed -i '1i #define FF_DISABLE_DLOPEN 1' src/logo/image/im7.c
            sed -i '1i #define FF_DISABLE_DLOPEN 1' src/detection/lm/lm_linux.c
            sed -i '1i #define FF_DISABLE_DLOPEN 1' src/common/impl/networking_common.c
            # MagickCore.a pulls C++ transitive deps (e.g. libultrahdr), so the
            # otherwise-C binary needs the C++ runtime — -lstdc++ last so it
            # resolves the C++ archives' std::/operator new/vtable refs.
            r10Logo="$($PKG_CONFIG --static --libs-only-L chafa zlib MagickCore) $($PKG_CONFIG --static --libs-only-l chafa zlib MagickCore)"
            export NIX_LDFLAGS="$NIX_LDFLAGS $r10Logo -lstdc++"

            # Round 10 (cont.): the remaining self-contained libs the binary
            # used to dlopen from the host. Each leaf TU loads exactly one of
            # these (verified), so FF_DISABLE_DLOPEN per-file is safe and only
            # makes that lib's refs direct. All are plain C (no extra runtime).
            #   dbus-1   -> common/impl/dbus.c
            #   ddcutil  -> detection/brightness/brightness_linux.c
            #   libdrm   -> detection/displayserver/linux/drm.c
            #   drm_amdgpu -> detection/gpu/gpu_drm.c
            #   xcb-randr -> detection/displayserver/linux/xcb.c
            #   Xrandr   -> detection/displayserver/linux/xlib.c
            #   libelf   -> common/impl/binary_linux.c
            # xfconf/libxfce4util is handled separately below (it needs a source
            # patch + a new xfce4 dep, not just a per-TU flip).
            for f in \
              src/common/impl/dbus.c \
              src/detection/brightness/brightness_linux.c \
              src/detection/displayserver/linux/drm.c \
              src/detection/gpu/gpu_drm.c \
              src/detection/displayserver/linux/xcb.c \
              src/detection/displayserver/linux/xlib.c \
              src/common/impl/binary_linux.c ; do
              sed -i '1i #define FF_DISABLE_DLOPEN 1' "$f"
            done
            # xfce4util: fastfetch stubs the static path out ("dlopen is
            # disabled", unique in this file). Replace it with a direct call to
            # the self-declared xfce_version_string(), then flip the TU static.
            sed -i 's#return "dlopen is disabled";#{ const char* xfce_version_string(void); ffStrbufSetS(result, xfce_version_string()); return NULL; }#' \
              src/detection/de/de_linux.c
            sed -i '1i #define FF_DISABLE_DLOPEN 1' src/detection/de/de_linux.c
            # libdrm_amdgpu is a separate .pc/.a from libdrm (amdgpu_* syms,
            # used by gpu_drm.c). ddcutil.a drags a closure that ddcutil.pc
            # does NOT declare (its Requires line is commented out, Libs is
            # just -lddcutil): glib-2.0, jansson, libacl, gudev-1.0, libusb-1.0,
            # libudev, and backtrace (libexecinfo on musl) — list them all.
            r10pcs="dbus-1 ddcutil libdrm libdrm_amdgpu glib-2.0 jansson libacl gudev-1.0 libusb-1.0 libudev xcb-randr xrandr libelf libxfce4util-1.0"
            r10Rest="$($PKG_CONFIG --static --libs-only-L $r10pcs) $($PKG_CONFIG --static --libs-only-l $r10pcs)"
            export NIX_LDFLAGS="$NIX_LDFLAGS $r10Rest -lexecinfo"

            # GSettings (Theme/Icons/Font/Cursor/WMTheme/TerminalFont) via the
            # embedded static dconf backend instead of dlopen'ing host libgio.
            # FF_DISABLE_DLOPEN on settings.c makes its g_settings_*/g_variant_*
            # refs link directly from our static glib; the dconf backend is
            # pulled from dconfStatic below. Register it once at main() entry
            # (before any GSettings use — g_settings_backend_get_default caches
            # the default on first call).
            sed -i '1i #define FF_DISABLE_DLOPEN 1' src/common/impl/settings.c
            awk '/^int main\(int argc, char\*\* argv\)/{print; getline; print; print "    { extern void dconf_register_static_gsettings_backend(void); dconf_register_static_gsettings_backend(); }"; next} {print}' \
              src/fastfetch.c > src/fastfetch.c.new && mv src/fastfetch.c.new src/fastfetch.c
            # FF_DISABLE_DLOPEN flips the WHOLE settings.c, so its GSettings,
            # GVariant and sqlite3 refs all become direct — link glib + sqlite3
            # statically. ($PKG_CONFIG is the cross wrapper; bare `pkg-config`
            # isn't on PATH in pkgsStatic.)
            # NIX_LDFLAGS goes straight to ld, so take only -L/-l from
            # pkg-config (the "other" category carries compiler-driver flags
            # like -pthread / -Wl,... that ld rejects; both are unneeded here,
            # pthread living in libc under musl).
            gtkLibs="$($PKG_CONFIG --static --libs-only-L gio-2.0 gio-unix-2.0 sqlite3) $($PKG_CONFIG --static --libs-only-l gio-2.0 gio-unix-2.0 sqlite3)"
            export NIX_LDFLAGS="$NIX_LDFLAGS -L${dconfStatic}/lib -l:libdconfsettings.a -l:libdconf-engine.a -l:libdconf-gdbus-thread.a -l:libdconf-common.a -l:libgvdb.a -l:libdconf-shm.a $gtkLibs"
          '';
          # Round 9: -l:libwayland-client.a força static-pull mesmo com
          # BINARY_LINK_TYPE=dlopen (CMake default, mantido). Resolve crash
          # de libwayland-client carregado via trampoline em sessão Wayland.
          # libffi: dep transitive de libwayland (protocol marshalling).
          # Trampoline continua pra libvulkan/libOpenCL/libdbus/libchafa/etc.
          NIX_LDFLAGS = "-L${tlsTrampoline}/lib -l:foreign_dlopen.a -l:libwayland-client.a -lffi --wrap=dlopen --wrap=dlsym --wrap=dlclose --wrap=dlerror";
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
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
            "-DENABLE_EGL=Off"
            "-DENABLE_GLX=Off"
            "-DENABLE_XCB_RANDR=On"
            "-DENABLE_XRANDR=On"
            "-DENABLE_XFCONF=Off"
            "-DENABLE_WAYLAND=On"
            "-DENABLE_DRM=On"
            "-DENABLE_DRM_AMDGPU=On"
            "-DENABLE_LUA=Off"
            "-DENABLE_QUICKJS=Off"
            "-DENABLE_DBUS=On"
            "-DENABLE_PULSE=Off"
            "-DENABLE_DCONF=Off"
            "-DENABLE_GIO=On"
            "-DENABLE_DDCUTIL=On"
            "-DENABLE_IMAGEMAGICK7=On"
            "-DENABLE_IMAGEMAGICK6=Off"
            "-DENABLE_CHAFA=On"
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
        (p.fastfetch.overrideAttrs (old: {
          postFixup = ''
            if [ -e $out/bin/.fastfetch-wrapped ]; then
              mv -f $out/bin/.fastfetch-wrapped $out/bin/fastfetch
            fi
          '' + (old.postFixup or "");
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
          preConfigure = (old.preConfigure or "") + ''
            mkdir -p build
            cp ${p.hwdata}/share/hwdata/pci.ids build/pci.ids
            cp ${p.libdrm}/share/libdrm/amdgpu.ids build/amdgpu.ids
            chmod +w build/pci.ids build/amdgpu.ids
            # BINARY_LINK_TYPE=static makes CMakeLists add GNU ld's
            # -Wl,--copy-dt-needed-entries, which our lld linker rejects
            # ("unknown argument"). It only matters for indirect DT_NEEDED of
            # shared libs; this is a fully static link, so drop the flag.
            substituteInPlace CMakeLists.txt \
              --replace-fail ' -Wl,--copy-dt-needed-entries' ""
            # GSettings (theme/icons/font/cursor/WMTheme) via the embedded
            # static dconf backend — same as the primary targets.
            # BINARY_LINK_TYPE=static already direct-links settings.c's
            # glib/gio/sqlite3 refs; register the dconf backend at main() so
            # user-db values resolve (not just schema defaults).
            awk '/^int main\(int argc, char\*\* argv\)/{print; getline; print; print "    { extern void dconf_register_static_gsettings_backend(void); dconf_register_static_gsettings_backend(); }"; next} {print}' \
              src/fastfetch.c > src/fastfetch.c.new && mv src/fastfetch.c.new src/fastfetch.c
            gtkLibs="$($PKG_CONFIG --static --libs-only-L gio-2.0 gio-unix-2.0 sqlite3) $($PKG_CONFIG --static --libs-only-l gio-2.0 gio-unix-2.0 sqlite3)"
            # -lstdc++ last: MagickCore.a's C++ transitive deps (libultrahdr)
            # need the C++ runtime in this otherwise-C binary.
            export NIX_LDFLAGS="$NIX_LDFLAGS -L${dconfStatic}/lib -l:libdconfsettings.a -l:libdconf-engine.a -l:libdconf-gdbus-thread.a -l:libdconf-common.a -l:libgvdb.a -l:libdconf-shm.a $gtkLibs -lstdc++"
          '';
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
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
            "-DENABLE_DCONF=On"
            "-DENABLE_DDCUTIL=On"
            "-DENABLE_IMAGEMAGICK7=On"
            "-DENABLE_IMAGEMAGICK6=Off"
            "-DENABLE_CHAFA=On"
            # host-ICD/driver — genuinely need runtime dlopen, no .a to link
            "-DENABLE_VULKAN=Off"
            "-DENABLE_OPENCL=Off"
            "-DENABLE_EGL=Off"
            "-DENABLE_GLX=Off"
            "-DENABLE_XFCONF=Off"
            "-DENABLE_PULSE=Off"
          ];
        }));
    };
}
