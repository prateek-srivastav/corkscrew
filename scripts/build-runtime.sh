#!/bin/bash
# Builds CrossOver's open-source Wine (winecx) for x86_64 (run by Rosetta) into
# build/runtime/winecx-<version>. Needs scripts/bootstrap.sh and scripts/build-deps.sh first.
#
# The result differs from a stock build in these ways:
#  - Wine's own Direct3D DLLs move to lib/wine-backends/wined3d, so the app picks a backend per
#    launch with WINEDLLPATH (Wine searches lib/wine before WINEDLLPATH).
#  - Wine Mono comes along as a shared install (share/wine/mono), so .NET programs run with no download.
#  - The loader declares the games category, and programs run from an app bundle that carries it,
#    so macOS Game Mode turns on for them.
#  - Libraries load through @rpath, so the folder can be moved anywhere.
#  - The Windows files carry no debug info, which more than halves the runtime's size.
#  - With EmulateModeset on, programs may pick display modes up to the panel's pixel size, so an
#    exclusive full screen larger than the desktop in points fills the screen instead of cropping.
#  - Full-screen windows stay at the normal window level, so Mission Control can move them to
#    another desktop and they don't cover other programs' windows; the menu bar and Dock hide
#    while the program is active instead.
#  - With CORKSCREW_PRIVATE_LOOPBACK set, wineserver connects only to loopback servers of its own
#    bottle, so offline bottles can use loopback without reaching services on the Mac. Programs
#    there log their first blocked internet name lookup and connect (ws2_32).
#  - A program that destroys a D3DMetal window on another thread no longer hangs the window's
#    input (winemac).
#  - With CORKSCREW_HOST_MEMORY_PROTECT=1, VirtualProtect also works on memory outside Wine's own,
#    such as D3DMetal's functions, so mods can hook a game's graphics (ntdll).
#  - The Install Engine (inseng) reads CIF files and downloads (Wine Staging), so Microsoft's
#    DirectX web installer works instead of crashing.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEPS="$BUILD/deps-x86_64"
WORK="$BUILD/work-wine"
LOGS="$BUILD/logs"
RUNTIME="$BUILD/runtime/winecx-$CROSSOVER_VERSION"
SWITCHABLE_DLLS=(d3d9 d3d10 d3d10_1 d3d10core d3d11 d3d12 d3d12core dxgi nvapi64 nvngx atidxx64)

[[ -f $DEPS/.done-sdl2 ]] || { echo "Run scripts/build-deps.sh first." >&2; exit 1; }
command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "Run scripts/bootstrap.sh first." >&2; exit 1; }
mkdir -p "$WORK" "$LOGS"

CX=$(crossover_sources)
WINE_SRC="$CX/wine"
# Wine only looks for a shared Wine Mono of its own version.
grep -qF "#define WINE_MONO_VERSION \"$WINE_MONO_VERSION\"" "$WINE_SRC/dlls/mscoree/mscoree_private.h" \
  || { echo "This Wine wants another Wine Mono than $WINE_MONO_VERSION (dlls/mscoree/mscoree_private.h); update the pins." >&2; exit 1; }

log "Patching the loader's Info.plist (Game Mode, own identity)"
python3 - "$WINE_SRC/loader/wine_info.plist.in" <<'EOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if "LSApplicationCategoryType" not in s:
    s = s.replace("com.codeweavers.CrossOver.wineloader", "io.github.prateek-srivastav.Corkscrew.wineloader")
    # Padding lets winecx rename the process to longer game names for the Dock.
    s = s.replace("<string>CrossOver-Hosted Application</string><!-- CrossOver Hack 10913 -->",
                  "<string>CrossOver-Hosted Application</string><!-- bundle name padding -->")
    s = s.replace("    <key>LSUIElement</key>",
                  "    <key>LSApplicationCategoryType</key>\n    <string>public.app-category.games</string>\n"
                  "    <key>LSSupportsGameMode</key>\n    <true/>\n    <key>LSUIElement</key>")
    p.write_text(s)
EOF

log "Patching the loader: optional opt-out of the Dock-name link (isolated bottles)"
# winecx re-runs itself through a link in $TMPDIR named after the game, for the Dock. The sandbox
# only lets programs inside the runtime run (allowing $TMPDIR would let malware run files it drops
# there), so isolated bottles set CORKSCREW_NO_LOADER_LINK=1 to skip the link.
python3 - "$WINE_SRC/dlls/ntdll/unix/loader.c" <<'PATCH'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = '    if (getenv("WINEDLLPATH"))\n        replace_wineloader_path_with_link( &(argv[1]), image_path );'
new = '    if (getenv("WINEDLLPATH") && !getenv("CORKSCREW_NO_LOADER_LINK"))\n        replace_wineloader_path_with_link( &(argv[1]), image_path );'
if new not in s:
    assert old in s, "loader.c changed upstream; update this patch"
    p.write_text(s.replace(old, new))
PATCH

log "Patching the loader: programs run from an app bundle, so macOS Game Mode turns on"
# winecx starts each program through a link named after it in $TMPDIR (for the Dock). macOS Game
# Mode only follows programs that LaunchServices knows as games, and it doesn't read the Info.plist
# embedded in an executable outside an app bundle: the game ran as an anonymous process and Game
# Mode never turned on. Programs outside C:\windows now run from <name>.app/Contents/MacOS/<name>
# in the same folder, with the loader's keys (games category, LSSupportsGameMode). Verified
# 2026-10-10: "Full screen gaming session is now active" in gamepolicyd's log, which never appeared
# for the plain link. Wine's own programs keep the plain link, and any failure falls back to it.
python3 - "$WINE_SRC/dlls/ntdll/unix/loader.c" <<'PATCH'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
anchor = "static void replace_wineloader_path_with_link(char **wineloader_path, const char *image_path)\n{\n"
helper = r'''/* Corkscrew: macOS Game Mode only follows programs LaunchServices knows as games, and it doesn't
 * read the Info.plist embedded in an executable outside an app bundle. Returns the path of the
 * loader linked as <tempdir>/<exe>.app/Contents/MacOS/<exe>, or NULL to use the plain link. */
static const char corkscrew_bundle_plist[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\">\n"
    "<dict>\n"
    "    <key>CFBundleAllowMixedLocalizations</key>\n    <true/>\n"
    "    <key>CFBundleDevelopmentRegion</key>\n    <string>English</string>\n"
    "    <key>CFBundleExecutable</key>\n    <string>%s</string>\n"
    "    <key>CFBundleIdentifier</key>\n    <string>io.github.prateek-srivastav.Corkscrew.wineloader</string>\n"
    "    <key>CFBundleInfoDictionaryVersion</key>\n    <string>6.0</string>\n"
    "    <key>CFBundleName</key>\n    <string>%.*s</string>\n"
    "    <key>CFBundlePackageType</key>\n    <string>APPL</string>\n"
    "    <key>CFBundleShortVersionString</key>\n    <string>" PACKAGE_VERSION "</string>\n"
    "    <key>CFBundleVersion</key>\n    <string>" PACKAGE_VERSION "</string>\n"
    "    <key>NSPrincipalClass</key>\n    <string>WineApplication</string>\n"
    "    <key>LSApplicationCategoryType</key>\n    <string>public.app-category.games</string>\n"
    "    <key>LSSupportsGameMode</key>\n    <true/>\n"
    "    <key>LSUIElement</key>\n    <string>1</string>\n"
    "</dict>\n"
    "</plist>\n";

static char *corkscrew_create_bundle_link(const char *wineloader_path, const char *exe_name, const char *image_path)
{
    char *dir, *exe = NULL, *bundle = NULL, *plist = NULL, *tmp = NULL, *ntdll = NULL, *p;
    const char *dot = strrchr(exe_name, '.');
    int name_len = dot && dot != exe_name ? dot - exe_name : strlen(exe_name);
    struct stat st;
    FILE *file;

    /* Only programs started by path (not wineboot, reg …), and not Wine's own. */
    if (!strpbrk(image_path, "\\/") || !strncasecmp(image_path, "C:\\windows\\", 11)) return NULL;
    if (strpbrk(exe_name, "&<>\"'")) return NULL;  /* kept out of the XML */
    if (!(dir = create_tempdir(wineloader_path))) return NULL;
    if (asprintf(&bundle, "%s%s.app", dir, exe_name) < 0) bundle = NULL;
    if (!bundle || asprintf(&exe, "%s/Contents/MacOS/%s", bundle, exe_name) < 0) exe = NULL;
    if (!exe) goto done;
    /* The executable is linked last, so a bundle that has it is complete. */
    if (!stat(exe, &st)) goto done;

    for (p = exe + strlen(dir); (p = strchr(p, '/')); *p++ = '/')
    {
        *p = 0;
        mkdir(exe, 0700);
    }
    /* The loader loads the ntdll.so next to itself. */
    if (asprintf(&ntdll, "%s", wineloader_path) >= 0 && (p = strrchr(ntdll, '/')))
    {
        *p = 0;
        if (asprintf(&tmp, "%s/ntdll.so", ntdll) >= 0)
        {
            free(ntdll);
            ntdll = tmp;
            tmp = NULL;
            if (asprintf(&tmp, "%s/Contents/MacOS/ntdll.so", bundle) >= 0) symlink(ntdll, tmp);
            free(tmp);
            tmp = NULL;
        }
    }
    if (asprintf(&plist, "%s/Contents/Info.plist", bundle) < 0 || asprintf(&tmp, "%s.%d", plist, getpid()) < 0 ||
        !(file = fopen(tmp, "w")))
        goto fail;
    fprintf(file, corkscrew_bundle_plist, exe_name, name_len, exe_name);
    if (fclose(file) || rename(tmp, plist)) goto fail;
    /* A hard link, or the process's path is outside the bundle (another volume: use the plain link). */
    if (!link(wineloader_path, exe) || errno == EEXIST) goto done;

fail:
    if (tmp) unlink(tmp);
    free(exe);
    exe = NULL;
done:
    free(dir);
    free(bundle);
    free(plist);
    free(tmp);
    free(ntdll);
    return exe;
}

'''
old = '''        char *preloader_path = create_preloader_link(*wineloader_path, app_name);
'''
new = '''        char *preloader_path = corkscrew_create_bundle_link(*wineloader_path, app_name, image_path);
        if (!preloader_path) preloader_path = create_preloader_link(*wineloader_path, app_name);
'''
if "corkscrew_create_bundle_link" not in s:
    assert s.count(anchor) == 1 and s.count(old) == 1, "loader.c changed upstream; update this patch"
    s = s.replace(anchor, helper + anchor).replace(old, new)
    p.write_text(s)
PATCH

log "Patching the loader: Game Mode bundles for isolated bottles"
# An isolated bottle's sandbox only runs programs from the runtime and from folders the app names,
# so its games can't get the bundle above (CORKSCREW_NO_LOADER_LINK). The app makes the game's
# bundle before the launch in CORKSCREW_LOADER_BUNDLE_DIR (read-only to the sandbox), and the loader
# only runs it, while its executable is still the loader's own file. A game started directly runs
# in the process Wine re-runs itself as (`wine` as the program, the game as its first argument), so
# the argument's name counts too. (The same re-run is why other bottles get a `wine.app` bundle:
# for a game started directly, that bundle is the game's.)
python3 - "$WINE_SRC/dlls/ntdll/unix/loader.c" <<'PATCH'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
anchor = "static void replace_wineloader_path_with_link(char **wineloader_path, const char *image_path)\n{\n"
helper = r'''/* Corkscrew: isolated bottles. Runs the program from <CORKSCREW_LOADER_BUNDLE_DIR>/<name>.app, made
 * by the app, when that bundle's executable is this loader (a hard link). */
static int corkscrew_try_prebuilt_bundle(char **wineloader_path, const char *dir, const char *path)
{
    char *app_name = path ? extract_exe_name(path) : NULL, *exe = NULL;
    struct stat st, loader;
    int found = 0;

    if (!app_name) return 0;
    if (asprintf(&exe, "%s/%s.app/Contents/MacOS/%s", dir, app_name, app_name) < 0) exe = NULL;
    if (exe && !stat(exe, &st) && !stat(*wineloader_path, &loader) && st.st_dev == loader.st_dev && st.st_ino == loader.st_ino)
    {
        free(*wineloader_path);
        *wineloader_path = exe;
        exe = NULL;
        setenv("WINEPRELOADERAPPNAME", app_name, 1);
        found = 1;
    }
    free(exe);
    free(app_name);
    return found;
}

static void corkscrew_use_prebuilt_bundle(char **wineloader_path, const char *image_path, const char *first_arg)
{
    const char *dir = getenv("CORKSCREW_LOADER_BUNDLE_DIR");

    if (!dir || !*dir) return;
    if (!corkscrew_try_prebuilt_bundle(wineloader_path, dir, image_path))
        corkscrew_try_prebuilt_bundle(wineloader_path, dir, first_arg);
}

'''
call_old = """    if (getenv("WINEDLLPATH") && !getenv("CORKSCREW_NO_LOADER_LINK"))
        replace_wineloader_path_with_link( &(argv[1]), image_path );
"""
call_new = call_old + """    else if (getenv("WINEDLLPATH"))
        corkscrew_use_prebuilt_bundle( &(argv[1]), image_path, argv[2] );
"""
if "corkscrew_use_prebuilt_bundle" not in s:
    assert s.count(anchor) == 1 and s.count(call_old) == 1, "loader.c changed upstream; update this patch"
    s = s.replace(anchor, helper + anchor).replace(call_old, call_new)
    p.write_text(s)
PATCH

log "Patching ntdll: VirtualProtect on host memory (per-game switch)"
# Mods and overlays hook a game's graphics by patching code: VirtualProtect, write a jump,
# VirtualProtect back. Under D3DMetal the D3D12 methods are in D3DMetal's library, which macOS
# loaded outside every Wine view, and Wine refuses to change its protection. A hook that ignores
# the refusal then writes to read-only code and the game crashes (FIFA 23's Live Editor). The app
# sets CORKSCREW_HOST_MEMORY_PROTECT=1 for games with mod hooks on; then the change is made with
# mprotect (under Rosetta a dylib's maximum protection is rwx; tested: Rosetta runs the patched
# code). Without it the refusal stays, and its first lines go to the log, which the app matches
# against a crash's write address to turn mod hooks on. Never Wine's reserved areas: free memory.
python3 - "$WINE_SRC/dlls/ntdll/unix/virtual.c" <<'PATCH'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
anchor = "/***********************************************************************\n *             NtProtectVirtualMemory   (NTDLL.@)\n"
helper = r'''/* Corkscrew: protection changes outside Wine's views, in memory the host mapped (D3DMetal's code
 * and data). Allowed with CORKSCREW_HOST_MEMORY_PROTECT=1; otherwise refused as before, and logged.
 * virtual_mutex must be held by caller. */
static unsigned int protect_host_memory( char *base, SIZE_T size, ULONG new_prot, DWORD *old_prot )
{
#ifdef __APPLE__
    static int allowed = -1, refusals;
    mach_vm_address_t address = (mach_vm_address_t)base;
    mach_vm_size_t region_size;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    unsigned int vprot;
    const char *env;

    if (mmap_is_in_reserved_area( base, size )) return STATUS_INVALID_PARAMETER;
    if (mach_vm_region( mach_task_self(), &address, &region_size, VM_REGION_BASIC_INFO_64,
                        (vm_region_info_t)&info, &count, &object ) || address > (mach_vm_address_t)base)
        return STATUS_INVALID_PARAMETER;
    if (allowed == -1) allowed = (env = getenv( "CORKSCREW_HOST_MEMORY_PROTECT" )) && !strcmp( env, "1" );
    if (!allowed)
    {
        if (refusals++ < 16) fprintf( stderr, "wine: refused VirtualProtect on host memory %p-%p\n", base, base + size );
        return STATUS_INVALID_PARAMETER;
    }
    if (get_vprot_flags( new_prot, &vprot, FALSE ) || (vprot & VPROT_GUARD)) return STATUS_INVALID_PAGE_PROTECTION;
    if (mprotect( base, size, get_unix_prot( vprot | VPROT_COMMITTED ) )) return STATUS_INVALID_PARAMETER;
    *old_prot = get_win32_prot( info.protection & (VPROT_READ | VPROT_WRITE | VPROT_EXEC), 0 );
    return STATUS_SUCCESS;
#else
    return STATUS_INVALID_PARAMETER;
#endif
}


'''
if "protect_host_memory" not in s:
    assert s.count(anchor) == 1, "virtual.c changed upstream; update this patch"
    s = s.replace(anchor, helper + anchor)
    old = "        else status = STATUS_NOT_COMMITTED;\n    }\n    else status = STATUS_INVALID_PARAMETER;\n\n    if (!status) VIRTUAL_DEBUG_DUMP_VIEW( view );\n"
    new = "        else status = STATUS_NOT_COMMITTED;\n    }\n    else status = protect_host_memory( base, size, new_prot, &old );\n\n    if (!status && view) VIRTUAL_DEBUG_DUMP_VIEW( view );\n"
    assert s.count(old) == 1, "virtual.c changed upstream; update this patch"
    s = s.replace(old, new)
    p.write_text(s)
PATCH

log "Patching kernelbase: Social Club's Chromium draws in its own process"
# Chromium draws a window's contents from its GPU process, but the window belongs to the browser
# process, and winemac only shows what a window's own process draws (GDI, OpenGL and Vulkan alike).
# Rockstar's SocialClubHelper.exe (the Rockstar Games Launcher's pages and prompts) then stays
# white. --in-process-gpu moves that work into the browser process; SwiftShader, because Chromium's
# Direct3D 11 path crashes under Wine and would now take the browser down with it.
# (Steam's web helper has the same problem; tools/steamwebhelper-wrapper handles it.)
python3 - "$WINE_SRC/dlls/kernelbase/process.c" <<'PATCH'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
anchor = '''    /* Warn if unsupported features are used */

    if (flags & (IDLE_PRIORITY_CLASS'''
new = '''    /* Corkscrew: Rockstar's Social Club draws from Chromium's GPU process into windows of its
     * browser process, which winemac can't show; do that work in the browser process. */
    {
        static const WCHAR social_club_flagsW[] = L" --in-process-gpu --use-gl=angle --use-angle=swiftshader";
        const WCHAR *exe = wcsrchr( app_name, '\\\\' ) ? wcsrchr( app_name, '\\\\' ) + 1 : app_name;

        if (!wcsicmp( exe, L"SocialClubHelper.exe" ) && !wcsstr( tidy_cmdline, L"--type=" ))
        {
            SIZE_T len = lstrlenW( tidy_cmdline ) + ARRAY_SIZE(social_club_flagsW);
            WCHAR *new_cmdline = RtlAllocateHeap( GetProcessHeap(), 0, len * sizeof(WCHAR) );

            if (new_cmdline)
            {
                lstrcpyW( new_cmdline, tidy_cmdline );
                lstrcatW( new_cmdline, social_club_flagsW );
                if (tidy_cmdline != cmd_line) HeapFree( GetProcessHeap(), 0, tidy_cmdline );
                tidy_cmdline = new_cmdline;
                WARN( "Social Club browser process: %s\\n", debugstr_w(tidy_cmdline) );
            }
        }
    }

''' + anchor
if new not in s:
    assert s.count(anchor) == 1, "process.c changed upstream; update this patch"
    p.write_text(s.replace(anchor, new))
PATCH

log "Patching win32u: emulated display modes up to the panel's pixel size"
# Direct3D's exclusive full screen with DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH makes D3DMetal ask
# ChangeDisplaySettings for the back buffer's size. With Retina mode off, winemac offers the Mac's
# own modes in points, and 1920x1080 is rarely one of them (MacBooks look like 1470 to 1728 points
# wide). D3DMetal ignores the refusal and sizes the window to 1920x1080 points anyway, so only its
# top-left part shows (FIFA 23: zoomed in and cropped). With EmulateModeset (which the app turns on
# for Retina-off bottles), win32u fakes mode changes and scales windows to the real display, but it
# offers no mode larger than the desktop. Now it offers modes up to the largest host mode (the
# panel's pixel size). Verified 2026-10-19 with a D3D11 test program on a 1512x982-point screen:
# 1920x1080@120 succeeds and the whole frame shows, letterboxed (win32u rounds the scale to an integer
# DPI, so about 0.5% of the right and bottom edges are cut).
python3 - "$WINE_SRC/dlls/win32u/sysparams.c" <<'PATCH'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
anchor = '''        if (!read_source_mode( source->key, ENUM_CURRENT_SETTINGS, &virtual ) || is_detached_mode( &virtual ))
            virtual = physical;

        if ((virtual_modes = get_virtual_modes( current, &physical, host_modes, host_modes_count, &virtual_count )))
'''
new = '''        DEVMODEW maximum = physical;
        const DEVMODEW *host;
        UINT i;

        if (!read_source_mode( source->key, ENUM_CURRENT_SETTINGS, &virtual ) || is_detached_mode( &virtual ))
            virtual = physical;

        /* Corkscrew: on a Retina display the host modes go up to the panel's pixel size, so
         * emulated modes may be larger than the desktop in points (1920x1080 on 1512x982). */
        for (i = 0, host = host_modes; emulate_modeset && host && i < host_modes_count; i++, host = NEXT_DEVMODEW(host))
        {
            if (host->dmPelsWidth * host->dmPelsHeight <= maximum.dmPelsWidth * maximum.dmPelsHeight) continue;
            maximum.dmPelsWidth = host->dmPelsWidth;
            maximum.dmPelsHeight = host->dmPelsHeight;
        }
        TRACE( "Corkscrew: emulated modes up to %ux%u\\n", (UINT)maximum.dmPelsWidth, (UINT)maximum.dmPelsHeight );

        if ((virtual_modes = get_virtual_modes( current, &maximum, host_modes, host_modes_count, &virtual_count )))
'''
if new not in s:
    assert s.count(anchor) == 1, "sysparams.c changed upstream; update this patch"
    p.write_text(s.replace(anchor, new))
PATCH

log "Patching winemac: full-screen windows stay at the normal window level"
# Mission Control moves a window to another desktop only when it is at the normal level (tested
# 2026-10-18 with test windows: levels 21 and 26 stay put, level 0 moves, also when not movable).
# Wine raised a full-screen window to level 26 (27 if topmost) while its program is active, to
# cover the menu bar and Dock. Since Wine ad8a3f5eb2 (2025-08) every topmost window also goes
# above the Dock (level 21) while its program is inactive, which overrode WindowsFloatWhenInactive
# (default: full-screen windows don't float when inactive); Direct3D's exclusive full screen sets
# WS_EX_TOPMOST on the game's window. So after Mission Control, Command-Tab or a switch to another
# desktop, the game covered every window on its desktop, and Mission Control couldn't move it.
# Now a full-screen window stays at level 0 (unless the displays are captured), the menu bar and
# Dock hide while the program is active and has a full-screen window on the current desktop, and
# the topmost floor skips windows at the normal level. Smaller topmost windows still float.
# Verified 2026-10-18 with God of War: Mission Control moves it to another desktop, the menu bar
# and Dock stay hidden while it is active, and Game Mode still turns on (test window).
python3 - "$WINE_SRC/dlls/winemac.drv" <<'PATCH'
import sys, pathlib
d = pathlib.Path(sys.argv[1])

def patch(name, old, new):
    p = d / name; s = p.read_text()
    if new not in s:
        assert s.count(old) == 1, f"{name} changed upstream; update this patch"
        p.write_text(s.replace(old, new))

patch("cocoa_window.m", '''            if (captured || fullscreen)
            {
                if (captured)
                    level = CGShieldingWindowLevel() + 1; /* Need +1 or we don't get mouse moves */
                else
                    level = NSStatusWindowLevel + 1;

                if (self.floating)
                    level++;
            }''', '''            if (captured)
            {
                level = CGShieldingWindowLevel() + 1; /* Need +1 or we don't get mouse moves */

                if (self.floating)
                    level++;
            }
            /* Corkscrew: Mission Control can't move a window above the normal level to another
             * desktop. -updateFullscreenPresentation hides the menu bar and Dock instead. */
            else if (fullscreen)
                level = NSNormalWindowLevel;''')

patch("cocoa_app.m", '''            NSInteger newLevel = [window minimumLevelForActive:active];

            if (window.floating)
            {''', '''            NSInteger newLevel = [window minimumLevelForActive:active];

            /* Corkscrew: a topmost window at the normal level (a full-screen one) stays there. */
            if (window.floating && newLevel != NSNormalWindowLevel)
            {''')

patch("cocoa_app.m", '''    - (void) adjustWindowLevels:(BOOL)active
    {''', '''    /* Corkscrew: full-screen windows stay at the normal level, so hide the menu bar and Dock
     * while one is on the current desktop. macOS applies these only while the program is active. */
    - (void) updateFullscreenPresentation
    {
        static const NSApplicationPresentationOptions hidden = NSApplicationPresentationHideDock |
                                                               NSApplicationPresentationHideMenuBar;
        NSApplicationPresentationOptions current = [NSApp presentationOptions];
        NSApplicationPresentationOptions wanted = NSApplicationPresentationDefault;
        NSWindow* window;

        // Leave other options alone, such as those of a window in native full screen.
        if (current != NSApplicationPresentationDefault && current != hidden)
            return;

        if ([NSApp isActive] && ![NSApp isHidden])
        {
            for (window in [NSApp windows])
            {
                if ([window isKindOfClass:[WineWindow class]] && [(WineWindow*)window isFullscreen] &&
                    [window isVisible] && ![window isMiniaturized] && [window isOnActiveSpace])
                {
                    wanted = hidden;
                    break;
                }
            }
        }

        if (wanted != current)
            [NSApp setPresentationOptions:wanted];
    }

    - (void) adjustWindowLevels:(BOOL)active
    {''')

patch("cocoa_app.m", '''        __block WineWindow* prev = nil;
        WineWindow* window;

        if ([NSApp isHidden]) return;''', '''        __block WineWindow* prev = nil;
        WineWindow* window;

        [self updateFullscreenPresentation];

        if ([NSApp isHidden]) return;''')

patch("cocoa_app.m", '''    - (void) updateFullscreenWindows
    {
        if (capture_displays_for_fullscreen''', '''    - (void) updateFullscreenWindows
    {
        [self updateFullscreenPresentation];

        if (capture_displays_for_fullscreen''')

patch("cocoa_app.m", '''        [nc addObserver:self
               selector:@selector(keyboardSelectionDidChange)''', '''        /* Corkscrew: a window that Mission Control moves to another desktop only changes its
         * occlusion state. */
        [nc addObserverForName:NSWindowDidChangeOcclusionStateNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note){
            if ([[note object] isKindOfClass:[WineWindow class]])
                [self updateFullscreenPresentation];
        }];

        [nc addObserver:self
               selector:@selector(keyboardSelectionDidChange)''')
PATCH

log "Patching winemac: no deadlock when a D3DMetal window is destroyed"
# macdrv_DestroyWindow released the window's D3DMetal client surfaces while it held win_data_mutex.
# Releasing a surface takes win32u's surfaces_lock, and client_surface_present (the message thread,
# from macdrv_handle_event) holds surfaces_lock while it waits for win_data_mutex. A program that
# destroys a D3DMetal window on another thread then hangs both threads; the game gets no more input.
# Seen 2026-10-19 with a mod that makes a hidden D3D12 window to read the swap chain's functions.
# Now the surfaces are released after release_win_data, in the order d3dmetal.c already uses.
python3 - "$WINE_SRC/dlls/winemac.drv/window.c" <<'PATCH'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
decl_old = '''void macdrv_DestroyWindow(HWND hwnd)
{
    struct macdrv_win_data *data;
'''
decl_new = '''void macdrv_DestroyWindow(HWND hwnd)
{
    struct macdrv_win_data *data;
    CFMutableArrayRef d3dmetal_client_surfaces;
'''
old = '''    /* CW HACK 22435 */
    if (data->d3dmetal_client_surfaces) CFRelease(data->d3dmetal_client_surfaces);

    CFDictionaryRemoveValue(win_datas, hwnd);
    release_win_data(data);
    free(data);
}
'''
new = '''    /* CW HACK 22435 */
    /* Corkscrew: released below, without win_data_mutex. Releasing a surface takes surfaces_lock,
       which client_surface_present holds while it waits for win_data_mutex. */
    d3dmetal_client_surfaces = data->d3dmetal_client_surfaces;

    CFDictionaryRemoveValue(win_datas, hwnd);
    release_win_data(data);
    free(data);
    if (d3dmetal_client_surfaces) CFRelease(d3dmetal_client_surfaces);
}
'''
if new not in s:
    assert s.count(decl_old) == 1 and s.count(old) == 1, "window.c changed upstream; update this patch"
    p.write_text(s.replace(decl_old, decl_new).replace(old, new))
PATCH

log "Patching wineserver: private loopback for offline bottles"
# Programs often talk to themselves over loopback: a helper serves 127.0.0.1:3216 inside
# the game, and network libraries make self-connected pairs on random ports. The sandbox of an
# offline bottle denies all IP traffic, and Seatbelt can only filter by address and port, not by
# who listens, so allowing loopback would also open every service on the Mac's localhost.
# Wine makes bind, listen and connect calls in wineserver; programs only send and receive on the
# sockets it hands them. So the app starts an offline bottle's wineserver first, in a sandbox that
# allows loopback, with CORKSCREW_PRIVATE_LOOPBACK set, and the programs in the strict sandbox
# (their own connect calls stay denied). With the variable set, this server connects only to
# loopback addresses where a socket of the same server (the bottle) listens, or for datagrams is
# bound, and binds sockets for all addresses to loopback. Limit: a datagram sent to an address
# (sendto) goes out from the program itself, so the sandbox still denies it on loopback.
python3 - "$WINE_SRC/server/sock.c" <<'PATCH'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

def patch(old, new):
    global s
    if new not in s:
        assert s.count(old) == 1, "sock.c changed upstream; update this patch"
        s = s.replace(old, new)

patch('''static struct list poll_list = LIST_INIT( poll_list );
''', '''static struct list poll_list = LIST_INIT( poll_list );

/* Corkscrew: every socket of this server, for private loopback. */
static struct list all_sockets = LIST_INIT( all_sockets );
''')

patch('''    struct list         accept_list; /* list of pending accept requests */
''', '''    struct list         accept_list; /* list of pending accept requests */
    struct list         all_entry;   /* Corkscrew: entry in all_sockets */
''')

patch('''static void sock_dump( struct object *obj, int verbose );
''', '''/* Corkscrew: whether this server keeps loopback inside the bottle (see build-runtime.sh). */
static int private_loopback(void)
{
    static int enabled = -1;

    if (enabled == -1) enabled = getenv( "CORKSCREW_PRIVATE_LOOPBACK" ) != NULL;
    return enabled;
}

/* Corkscrew: copies the family, address and port of addr to target (IPv4-mapped IPv6 as IPv4), and
 * returns whether it is a loopback address. */
static int loopback_target( const union unix_sockaddr *addr, union unix_sockaddr *target )
{
    memset( target, 0, sizeof(*target) );
    if (addr->addr.sa_family == AF_INET6 && IN6_IS_ADDR_V4MAPPED( &addr->in6.sin6_addr ))
        ipv4addr_from_v6( target, &addr->in6, 0 );
    else if (addr->addr.sa_family == AF_INET)
    {
        target->in.sin_family = AF_INET;
        target->in.sin_port = addr->in.sin_port;
        target->in.sin_addr = addr->in.sin_addr;
    }
    else if (addr->addr.sa_family == AF_INET6)
    {
        target->in6.sin6_family = AF_INET6;
        target->in6.sin6_port = addr->in6.sin6_port;
        target->in6.sin6_addr = addr->in6.sin6_addr;
    }
    else return 0;

    if (target->addr.sa_family == AF_INET)
        return (ntohl( target->in.sin_addr.s_addr ) >> 24) == 127;
    return IN6_IS_ADDR_LOOPBACK( &target->in6.sin6_addr );
}

/* Corkscrew: whether another socket of this server listens on target (for datagrams: is bound to
 * it). The kernel's own bound address counts, so a port the system picked matches too. */
static int is_bottle_listener( const struct sock *self, const union unix_sockaddr *target )
{
    unsigned int error = get_error();
    struct sock *sock;
    int found = 0;

    LIST_FOR_EACH_ENTRY( sock, &all_sockets, struct sock, all_entry )
    {
        union unix_sockaddr addr, own;
        socklen_t len = sizeof(addr);
        int fd;

        if (sock == self || !sock->fd || !sock->bound || sock->type != self->type) continue;
        if (sock->type == WS_SOCK_STREAM && sock->state != SOCK_LISTENING) continue;
        if ((fd = get_unix_fd( sock->fd )) == -1) continue;
        if (getsockname( fd, &addr.addr, &len ) || !loopback_target( &addr, &own )) continue;
        if (own.addr.sa_family != target->addr.sa_family) continue;
        if (own.addr.sa_family == AF_INET
            ? own.in.sin_port == target->in.sin_port && own.in.sin_addr.s_addr == target->in.sin_addr.s_addr
            : own.in6.sin6_port == target->in6.sin6_port && IN6_ARE_ADDR_EQUAL( &own.in6.sin6_addr, &target->in6.sin6_addr ))
        {
            found = 1;
            break;
        }
    }
    set_error( error );  /* get_unix_fd sets an error for a closed socket */
    return found;
}

static void sock_dump( struct object *obj, int verbose );
''')

patch('''    assert( obj->ops == &sock_ops );

    /* FIXME: special socket shutdown stuff? */
''', '''    assert( obj->ops == &sock_ops );

    list_remove( &sock->all_entry );

    /* FIXME: special socket shutdown stuff? */
''')

patch('''    list_init( &sock->accept_list );
    return sock;
''', '''    list_init( &sock->accept_list );
    list_add_tail( &all_sockets, &sock->all_entry );
    return sock;
''')

# Connect: in the bottle only. Other addresses fail as the sandbox would fail them (access denied);
# loopback ports with no listener of the bottle fail as if nothing listened there.
patch('''        memcpy( &peer_addr, &unix_addr, sizeof(unix_addr) );
        ret = connect( unix_fd, &unix_addr.addr, unix_len );
''', '''        if (private_loopback())
        {
            union unix_sockaddr target;

            if (!loopback_target( &unix_addr, &target ))
            {
                set_error( STATUS_ACCESS_DENIED );
                return;
            }
            if (!is_bottle_listener( sock, &target ))
            {
                set_error( STATUS_CONNECTION_REFUSED );
                return;
            }
        }

        memcpy( &peer_addr, &unix_addr, sizeof(unix_addr) );
        ret = connect( unix_fd, &unix_addr.addr, unix_len );
''')

# Bind: a socket for all addresses listens on loopback only. The bottle has no network, and only
# loopback listeners count as the bottle's own above. Programs still see the address they asked for
# (IPv4; see getsockname below).
patch('''        set_async_pending( async );

#ifdef IPV6_V6ONLY
''', '''        if (private_loopback())
        {
            if (bind_addr.addr.sa_family == AF_INET && bind_addr.in.sin_addr.s_addr == htonl( INADDR_ANY ))
                bind_addr.in.sin_addr.s_addr = htonl( INADDR_LOOPBACK );
            else if (bind_addr.addr.sa_family == AF_INET6 && IN6_IS_ADDR_UNSPECIFIED( &bind_addr.in6.sin6_addr ))
                bind_addr.in6.sin6_addr = in6addr_loopback;
            else if (bind_addr.addr.sa_family == AF_INET6 && IN6_IS_ADDR_V4MAPPED( &bind_addr.in6.sin6_addr ))
            {
                /* ::ffff:0.0.0.0, IPv4's any address on a dual-stack socket */
                in_addr_t any = htonl( INADDR_ANY ), loopback = htonl( INADDR_LOOPBACK );

                if (!memcmp( &bind_addr.in6.sin6_addr.s6_addr[12], &any, sizeof(any) ))
                    memcpy( &bind_addr.in6.sin6_addr.s6_addr[12], &loopback, sizeof(loopback) );
            }
        }

        set_async_pending( async );

#ifdef IPV6_V6ONLY
''')

p.write_text(s)
PATCH

log "Patching ws2_32: offline bottles log blocked internet access"
# A program in an offline bottle that needs the internet fails in its own way: an error box, a
# crash, or it just quits. The sandbox denies its name lookups and wineserver its connects (above)
# without a word. With CORKSCREW_PRIVATE_LOOPBACK set, ws2_32 now logs the first of each per process
# as "corkscrew: no internet: <name or address>", so the app can say why the program failed and
# offer to move it to Online Programs. Not logged: local names (no dot, .local, this Mac's own),
# loopback, and datagrams sent to an address (sendto, denied by the sandbox in the program itself).
python3 - "$WINE_SRC/dlls/ws2_32" <<'PATCH'
import sys, pathlib
d = pathlib.Path(sys.argv[1])

def patch(name, old, new):
    p = d / name; s = p.read_text()
    if new not in s:
        assert s.count(old) == 1, f"{name} changed upstream; update this patch"
        p.write_text(s.replace(old, new))

patch("unixlib.c", '''static NTSTATUS unix_getaddrinfo( void *args )
{
''', '''/* Corkscrew: logs the first lookup of an internet name that failed in an offline bottle (see
 * build-runtime.sh); there the sandbox denies them all. */
static void note_no_internet( const char *name )
{
    static int noted;
    char own[256];
    size_t len;

    if (noted || !name || !getenv( "CORKSCREW_PRIVATE_LOOPBACK" ) || !strchr( name, '.' )) return;
    len = strlen( name );
    if (len >= 6 && !strcasecmp( name + len - 6, ".local" )) return;
    if (!gethostname( own, sizeof(own) ) && !strcasecmp( own, name )) return;
    noted = 1;
    fprintf( stderr, "corkscrew: no internet: %s\\n", name );
}

static NTSTATUS unix_getaddrinfo( void *args )
{
''')

patch("unixlib.c", '''    ret = getaddrinfo( params->node, service, hints ? &unix_hints : NULL, &unix_info );
    if (ret)
        return addrinfo_err_from_unix( ret );
''', '''    ret = getaddrinfo( params->node, service, hints ? &unix_hints : NULL, &unix_info );
    if (ret)
    {
        note_no_internet( params->node );
        return addrinfo_err_from_unix( ret );
    }
''')

# The gethostbyname that macOS builds (no Linux gethostbyname_r).
patch("unixlib.c", '''    if (!(unix_host = gethostbyname( params->name )))
    {
''', '''    if (!(unix_host = gethostbyname( params->name )))
    {
        note_no_internet( params->name );
''')

patch("socket.c", '''/***********************************************************************
 *      connect   (ws2_32.4)
 */
''', '''/* Corkscrew: logs the first connect in an offline bottle that wineserver denied: one to anything
 * but the bottle's own loopback listeners (see build-runtime.sh). */
static void note_no_internet( const struct sockaddr *addr, NTSTATUS status )
{
    static LONG noted;

    if (status != STATUS_ACCESS_DENIED || !GetEnvironmentVariableA( "CORKSCREW_PRIVATE_LOOPBACK", NULL, 0 )) return;
    if (InterlockedExchange( &noted, 1 )) return;
    MESSAGE( "corkscrew: no internet: %s\\n", debugstr_sockaddr( addr ) );
}


/***********************************************************************
 *      connect   (ws2_32.4)
 */
''')

patch("socket.c", '''    if (status)
    {
        /* NtStatusToWSAError() has no mapping for WSAEALREADY */
''', '''    if (status)
    {
        note_no_internet( addr, status );
        /* NtStatusToWSAError() has no mapping for WSAEALREADY */
''')

patch("socket.c", '''    free( params );
    if (ret_len) *ret_len = overlapped->InternalHigh;
    SetLastError( NtStatusToWSAError( status ) );
''', '''    free( params );
    if (ret_len) *ret_len = overlapped->InternalHigh;
    note_no_internet( name, status );
    SetLastError( NtStatusToWSAError( status ) );
''')
PATCH

log "Patching inseng: CIF reader and downloads (Wine Staging)"
# Microsoft's DirectX web installer (dxwebsetup.exe, which program setups often run) drives the
# Install Engine. Wine's is stubs, so the installer releases an engine it still uses and crashes
# (WineHQ bug 39456). Wine Staging's inseng-Implementation patch (pinned in runtime-pins.env)
# implements the CIF reader and the downloads; the installer copies the files itself. Tested: with
# internet it installs; without, it shows "Setup could not download the file" and exits.
inseng_patch=$(fetch "$INSENG_PATCH_URL" "$INSENG_PATCH_SHA256")
if ! patch -d "$WINE_SRC" -p1 -R -s -f --dry-run <"$inseng_patch" >/dev/null 2>&1; then
  patch -d "$WINE_SRC" -p1 -N -s -f --dry-run <"$inseng_patch" >/dev/null \
    || { echo "inseng changed upstream; update INSENG_PATCH_URL in scripts/runtime-pins.env" >&2; exit 1; }
  patch -d "$WINE_SRC" -p1 -N -s -f <"$inseng_patch"
fi

log "Staging MoltenVK $MOLTENVK_VERSION"
if [[ ! -f $DEPS/lib/libMoltenVK.dylib ]]; then
  tarball=$(fetch "$MOLTENVK_URL" "$MOLTENVK_SHA256")
  tmp=$(mktemp -d)
  tar -xf "$tarball" -C "$tmp" MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib
  lipo "$tmp/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" -thin x86_64 -output "$DEPS/lib/libMoltenVK.dylib"
  install_name_tool -id @rpath/libMoltenVK.dylib "$DEPS/lib/libMoltenVK.dylib"
  rm -rf "$tmp"
fi

log "Making the x86_64 libraries relocatable (@rpath)"
# Must happen before configure: Wine records each library's install name as the name it dlopens.
for lib in "$DEPS"/lib/*.dylib; do
  [[ -L $lib ]] && continue
  name=$(basename "$lib")
  install_name_tool -id "@rpath/$name" "$lib" 2>/dev/null
  otool -L "$lib" | awk 'NR>1 {print $1}' | { grep -F "$DEPS/lib/" || true; } | while read -r dep; do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$lib" 2>/dev/null
  done
  otool -l "$lib" | grep -q "path @loader_path " || install_name_tool -add_rpath @loader_path "$lib" 2>/dev/null
  codesign --force --sign - "$lib" 2>/dev/null
done

log "Configuring Wine $CROSSOVER_VERSION (log: $LOGS/wine-configure.log)"
export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$(brew --prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CC="clang -arch x86_64" CXX="clang++ -arch x86_64"
export x86_64_CC=x86_64-w64-mingw32-gcc i386_CC=i686-w64-mingw32-gcc   # gcc, not llvm-mingw
export CPPFLAGS="-I$DEPS/include" CFLAGS="-O2 -Wno-error=implicit-function-declaration"
export LDFLAGS="-L$DEPS/lib -Wl,-rpath,@loader_path -Wl,-headerpad_max_install_names"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" PKG_CONFIG_PATH=""
unset CPATH LIBRARY_PATH C_INCLUDE_PATH
CONFIGURE_ARGS=(
  --build=x86_64-apple-darwin --host=x86_64-apple-darwin --prefix=/
  --enable-archs=i386,x86_64 --disable-tests
  --with-gnutls --with-freetype --with-sdl --with-vulkan
  --without-x --without-wayland --without-gstreamer --without-ffmpeg --without-cups --without-sane
  --without-usb --without-v4l2 --without-pcap --without-capi --without-krb5 --without-netapi
  --without-inotify --without-dbus --without-oss --without-alsa --without-pulse
  ac_cv_lib_soname_MoltenVK=libMoltenVK.dylib
  # configure links against the build Mac's SDK and finds functions newer than
  # MACOSX_DEPLOYMENT_TARGET. They become weak imports that are NULL on older macOS, and calling one
  # crashes (SIGSEGV). pipe2 is macOS 27+; ntdll calls it at startup.
  ac_cv_func_pipe2=no
)
# Reconfigure when the arguments change; a stale Makefile would keep the old results.
if [[ ! -f $WORK/Makefile || "$(cat "$WORK/.configure-args" 2>/dev/null)" != "${CONFIGURE_ARGS[*]}" ]]; then
  rm -f "$WORK/Makefile" "$WORK/config.cache"
  (cd "$WORK" && "$WINE_SRC/configure" "${CONFIGURE_ARGS[@]}") >"$LOGS/wine-configure.log" 2>&1 \
    || { tail -40 "$LOGS/wine-configure.log" >&2; rm -f "$WORK/Makefile"; exit 1; }
  echo "${CONFIGURE_ARGS[*]}" >"$WORK/.configure-args"
fi
grep -E "^configure: (WARNING|error)|SONAME_LIB(GNUTLS|FREETYPE|SDL2|MOLTENVK|VULKAN)" \
  "$LOGS/wine-configure.log" "$WORK/include/config.h" 2>/dev/null || true

# sfnt2fon (builds Wine's bitmap fonts) finds FreeType via @loader_path, i.e. its own folder.
mkdir -p "$WORK/tools/sfnt2fon"
ln -sf "$DEPS/lib/libfreetype.6.dylib" "$WORK/tools/sfnt2fon/libfreetype.6.dylib"
log "Building Wine with $JOBS jobs (log: $LOGS/wine-build.log)"
make -C "$WORK" -j"$JOBS" >"$LOGS/wine-build.log" 2>&1 || { tail -40 "$LOGS/wine-build.log" >&2; exit 1; }

log "Installing into $RUNTIME"
rm -rf "$RUNTIME"
make -C "$WORK" install-lib DESTDIR="$RUNTIME" >"$LOGS/wine-install.log" 2>&1 || { tail -40 "$LOGS/wine-install.log" >&2; exit 1; }

log "Bundling x86_64 libraries"
for lib in "$DEPS"/lib/*.dylib; do
  cp -a "$lib" "$RUNTIME/lib/"                                      # keeps version symlinks
  [[ -L $lib ]] || ln -sf "../../$(basename "$lib")" "$RUNTIME/lib/wine/x86_64-unix/$(basename "$lib")"
done

log "Moving Wine's Direct3D DLLs to lib/wine-backends/wined3d"
for arch in x86_64-windows i386-windows x86_64-unix; do
  mkdir -p "$RUNTIME/lib/wine-backends/wined3d/$arch"
  for dll in "${SWITCHABLE_DLLS[@]}"; do
    for f in "$RUNTIME/lib/wine/$arch/$dll".{dll,so}; do
      [[ -e $f ]] && mv "$f" "$RUNTIME/lib/wine-backends/wined3d/$arch/"
    done
  done
done

log "Stripping debug info from the Windows files"
# Wine builds its Windows (PE) files with -g, and the debug info was more than half of the runtime
# (1.6 GB → 0.87 GB without it, 2026-10-19). --strip-debug keeps the code, exports, relocations,
# unwind data and the "Wine builtin DLL" mark. The unstripped files stay in build/work-wine.
for arch in x86_64 i386; do
  strip=x86_64-w64-mingw32-strip; [[ $arch == i386 ]] && strip=i686-w64-mingw32-strip
  find "$RUNTIME/lib/wine/$arch-windows" "$RUNTIME/lib/wine-backends/wined3d/$arch-windows" -type f -exec "$strip" --strip-debug {} +
done

log "Checking that nothing points back into the build folder"
leaks=$(find "$RUNTIME" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -exec sh -c \
  'otool -L "$1" 2>/dev/null | tail -n +2 | grep -F "'"$BUILD"'" >/dev/null && echo "$1"' _ {} \; || true)
[[ -z $leaks ]] || { echo "Absolute build paths remain in:" >&2; echo "$leaks" >&2; exit 1; }

log "Checking for system functions newer than macOS $MACOSX_DEPLOYMENT_TARGET"
# A weak import from libSystem is a function the build SDK has but the deployment target may not;
# on an older macOS it is NULL and calling it crashes. These ones exist on every supported macOS
# (or the caller checks for NULL); anything else must be turned off in CONFIGURE_ARGS.
KNOWN_WEAK=(___ulock_wait2 __availability_version_check _dispatch_once_f)
weak=$(find "$RUNTIME" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) ! -name '*.dll' ! -name '*.exe' \
  -exec sh -c 'file "$1" | grep -q Mach-O && nm -m "$1" 2>/dev/null \
    | awk -v f="$1" '"'"'/\(undefined\) weak external .* \(from libSystem\)/ {print f": "$4}'"'"'' _ {} \; \
  | grep -vwF "$(printf '%s\n' "${KNOWN_WEAK[@]}")" || true)
[[ -z $weak ]] || { echo "Functions that may be missing on macOS $MACOSX_DEPLOYMENT_TARGET:" >&2; echo "$weak" >&2; exit 1; }

log "Adding Wine Mono $WINE_MONO_VERSION"
# mscoree finds it at WINEDATADIR\mono\wine-mono-<version> (dlls/mscoree/metahost.c), and wineboot
# installs its support package from there, so no bottle shows Wine's Mono download box.
mono=$(fetch "$WINE_MONO_URL" "$WINE_MONO_SHA256")
mkdir -p "$RUNTIME/share/wine/mono"
tar -xJf "$mono" -C "$RUNTIME/share/wine/mono"

cat >"$RUNTIME/manifest.json" <<EOF
{
  "id": "winecx-$CROSSOVER_VERSION-x86_64",
  "architecture": "x86_64",
  "source": "$CROSSOVER_URL",
  "sourceSHA256": "$CROSSOVER_SHA256",
  "moltenVK": "$MOLTENVK_VERSION",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
log "Runtime ready: $RUNTIME ($(du -sh "$RUNTIME" | cut -f1))"
[[ -d $BUILD/components/dxmt-$DXMT_VERSION ]] \
  && echo "Run scripts/install-components.sh again: it puts DXMT's winemetal back into the rebuilt runtime."
"$RUNTIME/bin/wine" --version
