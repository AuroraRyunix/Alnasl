/*
 * Alnasl.exe - what an arbiter double-clicks on Windows.
 *
 * Built by build_launcher.ps1 with `zig cc`. It stands at the root of the
 * release, beside Alnasl.bat, and it is the executable Velopack's installer
 * makes the Start menu entry for.
 *
 * It follows OpenPairings' launcher in everything an arbiter can see, so
 * that the two programs behave alike on the same desk: no console window, a
 * small window that says what is happening, the browser opened once the
 * site really answers, and "closing this window stops the program".
 *
 * ## What it does
 *
 *   1. Works out where it is (never the working directory: a Start menu
 *      shortcut has none worth the name).
 *   2. Says where the data goes: %LOCALAPPDATA%\AlnaslData, unless
 *      ALNASL_DATA already says otherwise. Not in the install folder, not
 *      in a folder with the installer's name - see "The data" below.
 *   3. Starts `bin\alnasl.bat start` with no window, in a job object, so
 *      that the server cannot outlive this process however it ends.
 *   4. Waits until the port answers, then opens the browser.
 *   5. Stays, as the stop button. Closing it asks first: while Alnasl is
 *      stopped the boards are not read, and a move not read is a move the
 *      arbiter types in later.
 *
 * ## The data
 *
 * Velopack removes %LOCALAPPDATA%\<pack id> whole when the program is
 * uninstalled - everything in it, not only what it put there - and replaces
 * `current\` on every update. The pack id is AlnaslApp. The data is in
 * AlnaslData, which no installer has heard of. That is the whole defence,
 * and it is checked in three places that do not trust each other:
 * `Alnasl.DataHome` (the program refuses to start on a forbidden
 * directory), build_installer.ps1 (refuses to pack) and a test.
 *
 * ## Updates
 *
 * The program cannot replace itself: it is a child of this process, and
 * Velopack's "wait for exit, then apply" is built around the process the
 * installer started - this one. So when the arbiter has said yes in the
 * browser (Setup, Updates), the program stops cleanly with exit code
 * ALNASL_UPDATE_EXIT_CODE and this file does the rest: asks Velopack for
 * the update, downloads it, and hands over to Velopack's Update.exe, which
 * swaps `current\` and starts this launcher again.
 *
 * Nothing here checks for updates or downloads anything unasked.
 * velopack_libc.dll is loaded at that moment and at no other. And every way
 * the update can fail - no network, no newer version, the DLL quarantined -
 * ends the same way: the version that was running is started again. An
 * arbiter is never left with nothing.
 *
 * ## Velopack's hooks
 *
 * Setup.exe and Update.exe run this executable with --veloapp-install,
 * --veloapp-updated, --veloapp-obsolete and --veloapp-uninstall, and wait
 * for it. Those are not a reason to start a server. The uninstall hook
 * removes the "start with Windows" value this program may have written
 * (`Alnasl.Autostart`) and nothing else: no file, and never the data.
 */

#define UNICODE
#define _UNICODE
#ifndef WINVER
#define WINVER 0x0601
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <shellapi.h>
#include <commctrl.h>
#include <stdint.h>
#include <stdbool.h>
/* strstr, for the one array of the details answer that is read. */
#include <string.h>
/* The Details panel: the request to the server, and the secret it carries. */
#include <winhttp.h>
#include <bcrypt.h>

#define IDC_STATUS 101
#define IDC_URL 102
#define IDC_HINT 103
#define IDC_OPEN 104
#define IDC_STOP 105
#define IDC_DETAILS 106
#define IDC_STATS 107
#define IDC_LOG 108
#define IDC_COPY 109
#define IDC_FOLDER 110

#define WM_APP_READY (WM_APP + 1)
#define WM_APP_SLOW (WM_APP + 2)
#define WM_APP_FAILED (WM_APP + 3)
#define WM_APP_EXITED (WM_APP + 4)
/* From the Details poller: lParam is the numbers as text (HeapAlloc'd, the
 * window procedure frees it), or NULL when the server did not answer. */
#define WM_APP_STATS (WM_APP + 5)

/* `Alnasl.Updates` stops the program with this code when the arbiter has
 * confirmed an update (@update_exit_code there). Two files that cannot
 * share a constant share a comment. */
#define ALNASL_UPDATE_EXIT_CODE 90

/* Long, for the first start on a slow laptop: the runtime boots, the
 * database is made, and an antivirus reads every DLL while that happens. A
 * start that died is noticed in a second by watching the child, so this is
 * rarely the bound that speaks. */
#define START_TIMEOUT_MS 120000
#define SLOW_HINT_MS 20000
#define POLL_MS 250
#define DEFAULT_PORT 4040
#define MAXP 1024

#define REPO_URL "https://github.com/AuroraRyunix/Alnasl"
#define RUN_KEY L"Software\\Microsoft\\Windows\\CurrentVersion\\Run"
#define RUN_VALUE L"Alnasl"

static HINSTANCE g_inst;
static HWND g_wnd, g_status, g_hint, g_url_label, g_open, g_stop;
static HFONT g_font, g_bold;
static HANDLE g_job, g_child;
static int g_dpi = 96, g_port = DEFAULT_PORT;
static BOOL g_background, g_running, g_dutch;
static WCHAR g_root[MAXP], g_log[MAXP], g_url[64], g_title[64] = L"Alnasl";
/* The Details panel's secret for this start, 48 hex digits - see "Details"
 * below. Empty if Windows would not give us randomness, in which case the
 * panel shows its waiting line and nothing else changes. */
static WCHAR g_token[64];

#define S(x) MulDiv((x), g_dpi, 96)

/* --- words ---------------------------------------------------------------
 * English, and Dutch when Windows is set to Dutch. The management site has
 * its own language setting; this window is on screen before anything could
 * read it. */
enum {
    T_STARTING, T_STARTING_HINT, T_SLOW, T_RUNNING, T_RUNNING_HINT, T_OPEN, T_STOP,
    T_CLOSE, T_CONFIRM_STOP, T_STOPPED, T_STOPPED_HINT, T_FAILED, T_TIMEOUT,
    T_INCOMPLETE, T_PORT_BUSY, T_UPD_CHECK, T_UPD_WAIT, T_UPD_DOWNLOAD, T_UPD_DOWNLOAD_HINT,
    T_UPD_INSTALL, T_UPD_INSTALL_HINT, T_UPD_FAILED, T_UPD_FAILED_HINT,
    T_DETAILS, T_DETAILS_COPY, T_DETAILS_COPIED, T_DETAILS_FOLDER, T_DETAILS_NOLOG,
    T_DETAILS_WAITING, T_COUNT
};

static const WCHAR *const EN[T_COUNT] = {
    L"Starting Alnasl...",
    L"The first start takes a little longer.",
    L"Still starting. An antivirus scan of a new program can take a minute.",
    L"Alnasl is running.",
    L"Closing this window stops Alnasl. The boards are not read while it is stopped.",
    L"Open in browser",
    L"Stop Alnasl",
    L"Close",
    L"Stop Alnasl?\n\nThe boards are not read while it is stopped: moves played "
    L"meanwhile have to be put right by hand.",
    L"Alnasl has stopped.",
    L"It stopped by itself. The reason is at the end of this file:",
    L"Alnasl could not start. The reason is at the end of this file:",
    L"Alnasl did not answer within two minutes. This file says how far it got:",
    L"Alnasl is incomplete: the program was expected beside this file, in the folder "
    L"\"bin\". Unzip the whole download and start Alnasl.exe from inside it.",
    L"Something is already using port %d on this computer - most likely Alnasl "
    L"itself, started another way.\n\nOpen it in your browser?",
    L"Looking for the update...",
    L"Please wait.",
    L"Downloading the update...",
    L"This can take a few minutes on a slow connection.",
    L"Installing the update...",
    L"Alnasl starts again in a moment.",
    L"The update could not be installed.",
    L"Starting the version you had. Nothing was changed.",
    L"Details",
    L"Copy",
    L"Copied",
    L"Open log folder",
    L"No log yet:",
    L"Waiting for Alnasl to answer...",
};

static const WCHAR *const NL[T_COUNT] = {
    L"Alnasl start...",
    L"De eerste keer duurt het iets langer.",
    L"Nog bezig. Een virusscan van een nieuw programma kan een minuut duren.",
    L"Alnasl draait.",
    L"Dit venster sluiten stopt Alnasl. Zolang het gestopt is, worden de borden niet gelezen.",
    L"Openen in browser",
    L"Alnasl stoppen",
    L"Sluiten",
    L"Alnasl stoppen?\n\nZolang het gestopt is, worden de borden niet gelezen: zetten die "
    L"intussen gespeeld worden, moet u achteraf met de hand rechtzetten.",
    L"Alnasl is gestopt.",
    L"Het is vanzelf gestopt. De reden staat aan het einde van dit bestand:",
    L"Alnasl kon niet starten. De reden staat aan het einde van dit bestand:",
    L"Alnasl antwoordde niet binnen twee minuten. In dit bestand staat hoe ver het kwam:",
    L"Alnasl is onvolledig: het programma werd naast dit bestand verwacht, in de map "
    L"\"bin\". Pak de hele download uit en start Alnasl.exe van daaruit.",
    L"Poort %d is op deze computer al in gebruik - waarschijnlijk door Alnasl zelf, op "
    L"een andere manier gestart.\n\nOpenen in uw browser?",
    L"De update wordt gezocht...",
    L"Even geduld.",
    L"De update wordt gedownload...",
    L"Dat kan op een trage verbinding enkele minuten duren.",
    L"De update wordt ge\x00EFnstalleerd...",
    L"Alnasl start zo meteen opnieuw.",
    L"De update kon niet worden ge\x00EFnstalleerd.",
    L"De versie die u had wordt gestart. Er is niets veranderd.",
    L"Details",
    L"Kopi\x00EBren",
    L"Gekopieerd",
    L"Open logmap",
    L"Nog geen logboek:",
    L"Wachten tot Alnasl antwoordt...",
};

static const WCHAR *T(int id) { return g_dutch ? NL[id] : EN[id]; }

/* --- small things -------------------------------------------------------- */

static void fatal(const WCHAR *text)
{
    MessageBoxW(NULL, text, L"Alnasl", MB_OK | MB_ICONERROR);
    ExitProcess(1);
}

static void join(WCHAR *out, const WCHAR *dir, const WCHAR *tail)
{
    lstrcpynW(out, dir, MAXP);
    lstrcpynW(out + lstrlenW(out), tail, MAXP - lstrlenW(out));
}

static BOOL exists(const WCHAR *path)
{
    return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

static void open_browser(void)
{
    ShellExecuteW(NULL, L"open", g_url, NULL, NULL, SW_SHOWNORMAL);
}

static void set_status(const WCHAR *status, const WCHAR *hint)
{
    SetWindowTextW(g_status, status);
    SetWindowTextW(g_hint, hint);
}

static BOOL has_arg(const WCHAR *prefix, BOOL exact)
{
    int argc = 0, i;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    BOOL found = FALSE;

    if (!argv)
        return FALSE;

    for (i = 1; i < argc; i++) {
        int n = lstrlenW(prefix);
        if (exact ? lstrcmpiW(argv[i], prefix) == 0
                  : (lstrlenW(argv[i]) >= n &&
                     CompareStringW(LOCALE_INVARIANT, NORM_IGNORECASE, argv[i], n, prefix, n) ==
                         CSTR_EQUAL))
            found = TRUE;
    }

    LocalFree(argv);
    return found;
}

/* The executable's own folder, with a trailing backslash. */
static void resolve_root(void)
{
    DWORD n = GetModuleFileNameW(NULL, g_root, MAXP);

    if (n == 0 || n >= MAXP)
        fatal(L"Alnasl could not work out where it is installed.");

    while (n > 0 && g_root[n - 1] != L'\\')
        n--;
    g_root[n] = 0;
}

/* "Alnasl 0.2.0" for the title bar, from the release on disk
 * (`releases\start_erl.data` is "<erts> <release version>"), so the window
 * says which version it is also when the server never answers. */
static void read_version(void)
{
    WCHAR path[MAXP], version[32];
    char buf[96];
    DWORD got = 0;
    HANDLE file;
    int i = 0;
    char *p = buf;

    join(path, g_root, L"releases\\start_erl.data");
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE)
        return;

    if (ReadFile(file, buf, sizeof buf - 1, &got, NULL)) {
        buf[got] = 0;
        while (*p && *p != ' ')
            p++;
        while (*p == ' ')
            p++;
        while (i < 31 && p[i] && p[i] != ' ' && p[i] != '\r' && p[i] != '\n') {
            version[i] = (WCHAR)(unsigned char)p[i];
            i++;
        }
        version[i] = 0;
        if (i > 0)
            wsprintfW(g_title, L"Alnasl %s", version);
    }

    CloseHandle(file);
}

/* PORT when it is set and makes sense, 4040 otherwise. A typo in an
 * environment variable is not a reason for a round to start late. */
static int read_port(void)
{
    WCHAR buf[16];
    DWORD n = GetEnvironmentVariableW(L"PORT", buf, 16), i;
    int value = 0;

    if (n == 0 || n >= 16)
        return DEFAULT_PORT;

    for (i = 0; i < n; i++) {
        if (buf[i] < L'0' || buf[i] > L'9')
            return DEFAULT_PORT;
        value = value * 10 + (buf[i] - L'0');
        if (value > 65535)
            return DEFAULT_PORT;
    }

    return value > 0 ? value : DEFAULT_PORT;
}

/* Where the data goes, and with it this launcher's log. ALNASL_DATA is left
 * alone when it is set; when it is not, it is set here, so that the program
 * and this file cannot disagree about the place. The folder's name is in
 * `Alnasl.DataHome` too, and a test holds the two together. */
static void resolve_data(void)
{
    WCHAR dir[MAXP], local[MAXP];
    DWORD n = GetEnvironmentVariableW(L"ALNASL_DATA", dir, MAXP);

    if (n == 0 || n >= MAXP) {
        n = GetEnvironmentVariableW(L"LOCALAPPDATA", local, MAXP);
        if (n > 0 && n < MAXP) {
            join(dir, local, L"\\AlnaslData");
            SetEnvironmentVariableW(L"ALNASL_DATA", dir);
        } else if (GetTempPathW(MAXP, dir) == 0) {
            /* No profile and no temp: the program will say where it cannot
             * write. The log goes nowhere. */
            dir[0] = 0;
        }
    }

    if (dir[0]) {
        WCHAR tmp[MAXP];

        CreateDirectoryW(dir, NULL);
        join(g_log, dir, L"\\launcher.log");

        /* The release writes the configuration it started with to a file -
         * the cookie secret in it - and by default into its own folder.
         * Beside the data is the better place: it is the user's, it is
         * writable when the program's folder is not, and nothing packs it. */
        if (GetEnvironmentVariableW(L"RELEASE_TMP", NULL, 0) == 0) {
            join(tmp, dir, L"\\tmp");
            CreateDirectoryW(tmp, NULL);
            SetEnvironmentVariableW(L"RELEASE_TMP", tmp);
        }
    }
}

static BOOL port_open(void)
{
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    struct sockaddr_in addr;
    BOOL ok;

    if (s == INVALID_SOCKET)
        return FALSE;

    ZeroMemory(&addr, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)g_port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    ok = connect(s, (struct sockaddr *)&addr, sizeof addr) == 0;
    closesocket(s);
    return ok;
}

/* --- the installation, as Velopack laid it out ---------------------------
 * <root>\current\Alnasl.exe (this file), <root>\Update.exe. Anything else -
 * the portable zip, a copy of the folder - is not something Velopack can
 * update, and is not offered the button. */
static BOOL install_root(WCHAR *root, WCHAR *update_exe)
{
    WCHAR trimmed[MAXP];
    int len, i;

    lstrcpynW(trimmed, g_root, MAXP);
    len = lstrlenW(trimmed);
    if (len > 0 && trimmed[len - 1] == L'\\')
        trimmed[--len] = 0;

    i = len;
    while (i > 0 && trimmed[i - 1] != L'\\')
        i--;

    if (i == 0 || lstrcmpiW(trimmed + i, L"current") != 0)
        return FALSE;

    trimmed[i - 1] = 0;
    lstrcpynW(root, trimmed, MAXP);
    join(update_exe, root, L"\\Update.exe");
    return exists(update_exe);
}

static BOOL can_update(void)
{
    WCHAR root[MAXP], update_exe[MAXP], dll[MAXP];

    join(dll, g_root, L"velopack_libc.dll");
    return exists(dll) && install_root(root, update_exe);
}

/* --- the server ----------------------------------------------------------- */

static DWORD WINAPI waiter(LPVOID unused)
{
    DWORD started = GetTickCount(), code = 0;
    BOOL told_slow = FALSE;

    (void)unused;

    for (;;) {
        if (port_open()) {
            PostMessageW(g_wnd, WM_APP_READY, 0, 0);
            /* From here this thread watches for the end instead: a clean
             * exit with the update code, or anything else. */
            WaitForSingleObject(g_child, INFINITE);
            GetExitCodeProcess(g_child, &code);
            PostMessageW(g_wnd, WM_APP_EXITED, code, 0);
            return 0;
        }

        if (WaitForSingleObject(g_child, 0) == WAIT_OBJECT_0) {
            PostMessageW(g_wnd, WM_APP_FAILED, 0, 0);
            return 0;
        }

        if (!told_slow && GetTickCount() - started > SLOW_HINT_MS) {
            told_slow = TRUE;
            PostMessageW(g_wnd, WM_APP_SLOW, 0, 0);
        }

        if (GetTickCount() - started > START_TIMEOUT_MS) {
            PostMessageW(g_wnd, WM_APP_FAILED, 1, 0);
            return 0;
        }

        Sleep(POLL_MS);
    }
}

static void start_server(void)
{
    WCHAR bat[MAXP], comspec[MAXP], cmdline[MAXP * 3], port[16];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    SECURITY_ATTRIBUTES sa;
    HANDLE log = INVALID_HANDLE_VALUE, nul, thread;

    join(bat, g_root, L"bin\\alnasl.bat");
    if (!exists(bat))
        fatal(T(T_INCOMPLETE));

    if (GetSystemDirectoryW(comspec, MAXP) == 0)
        fatal(L"Alnasl could not find the Windows system directory.");
    lstrcpynW(comspec + lstrlenW(comspec), L"\\cmd.exe", MAXP - lstrlenW(comspec));

    /* /d: nobody's AutoRun in our process tree. /s with the doubled quotes:
     * cmd strips exactly the outer pair and the path keeps its own. */
    wsprintfW(cmdline, L"\"%s\" /d /s /c \"\"%s\" start\"", comspec, bat);

    wsprintfW(port, L"%d", g_port);
    SetEnvironmentVariableW(L"PORT", port);
    /* No Erlang distribution: no epmd on every interface, no Windows
     * Firewall question from a chess program on first start, and no node
     * whose cookie ships in the download. Set here without asking, because
     * this is the front door; Alnasl.bat lets it be overridden. */
    SetEnvironmentVariableW(L"RELEASE_DISTRIBUTION", L"none");
    /* The Details panel's secret: the server answers `/_launcher/stats`
     * only to a request that carries it. Made once per launcher start, in
     * WinMain, so a restart after a failed update keeps it. */
    if (g_token[0])
        SetEnvironmentVariableW(L"ALNASL_LAUNCHER_TOKEN", g_token);
    /* Whether "Download and install" can work here - `Alnasl.Updates`
     * checks the layout again for itself. */
    SetEnvironmentVariableW(L"ALNASL_UPDATER", can_update() ? L"velopack" : NULL);

    ZeroMemory(&sa, sizeof sa);
    sa.nLength = sizeof sa;
    sa.bInheritHandle = TRUE;

    if (g_log[0])
        log = CreateFileW(g_log, GENERIC_WRITE, FILE_SHARE_READ, &sa, CREATE_ALWAYS,
                          FILE_ATTRIBUTE_NORMAL, NULL);
    nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                      &sa, OPEN_EXISTING, 0, NULL);

    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = nul;
    /* No log is a pity; no server because there was no log would be worse. */
    si.hStdOutput = log == INVALID_HANDLE_VALUE ? nul : log;
    si.hStdError = si.hStdOutput;

    /* The job is the whole defence against a server left running: its
     * handle closes when this process ends for any reason, and the kernel
     * then ends everything in it. */
    if (!g_job) {
        g_job = CreateJobObjectW(NULL, NULL);
        if (g_job) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
            ZeroMemory(&limits, sizeof limits);
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(g_job, JobObjectExtendedLimitInformation, &limits,
                                    sizeof limits);
        }
    }

    /* Suspended until it is in the job: cmd must not get a grandchild out
     * before the door is shut. */
    if (!CreateProcessW(comspec, cmdline, NULL, NULL, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED,
                        NULL, g_root, &si, &pi))
        fatal(L"Alnasl could not start its server process.");

    if (g_job)
        AssignProcessToJobObject(g_job, pi.hProcess);
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);

    if (g_child)
        CloseHandle(g_child);
    g_child = pi.hProcess;

    if (log != INVALID_HANDLE_VALUE)
        CloseHandle(log);
    if (nul != INVALID_HANDLE_VALUE)
        CloseHandle(nul);

    thread = CreateThread(NULL, 0, waiter, NULL, 0, NULL);
    if (thread)
        CloseHandle(thread);
}

/* Abrupt, on purpose. A polite `bin\alnasl stop` is a remote call to a node
 * that, by the line above, does not exist; and the database is SQLite in
 * WAL mode with every commit forced to disk, which is what makes pulling
 * the plug survivable in the first place. */
static void stop_server(void)
{
    if (g_job) {
        TerminateJobObject(g_job, 0);
        if (g_child)
            WaitForSingleObject(g_child, 5000);
    }
}

/* --- Velopack --------------------------------------------------------------
 * velopack_libc.dll's C interface, declared here field for field as its
 * header (Velopack.h, release 1.2.0, MIT) has it: this file needs eight
 * functions and four small structs of a five-hundred-line generated header.
 * The release workflow pins the DLL to that same version by checksum; a DLL
 * that lacks one of the eight is not loaded at all. */

typedef int8_t vpkc_update_check_t;
#define VPKC_UPDATE_AVAILABLE ((vpkc_update_check_t)0)

typedef struct {
    char *PackageId;
    char *Version;
    char *Type;
    char *FileName;
    char *SHA1;
    char *SHA256;
    uint64_t Size;
    char *NotesMarkdown;
    char *NotesHtml;
} vpkc_asset_t;

typedef struct {
    vpkc_asset_t *TargetFullRelease;
    vpkc_asset_t *BaseRelease;
    vpkc_asset_t **DeltasToTarget;
    size_t DeltasToTargetCount;
    bool IsDowngrade;
} vpkc_update_info_t;

/* All five paths are given. With one left out the library goes looking for
 * an installation by itself and reports "not properly installed". */
typedef struct {
    char *RootAppDir;
    char *UpdateExePath;
    char *PackagesDir;
    char *ManifestPath;
    char *CurrentBinaryDir;
    bool IsPortable;
} vpkc_locator_config_t;

typedef void *(*fn_source)(const char *, const char *, bool);
typedef bool (*fn_manager)(void *, void *, vpkc_locator_config_t *, void **);
typedef vpkc_update_check_t (*fn_check)(void *, vpkc_update_info_t **);
typedef bool (*fn_download)(void *, vpkc_update_info_t *, void *, void *);
typedef bool (*fn_apply)(void *, vpkc_asset_t *, bool, bool, char **, size_t);
typedef void (*fn_free_info)(vpkc_update_info_t *);
typedef void (*fn_free)(void *);

static void utf8(char *out, int out_len, const WCHAR *wide)
{
    if (WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, out_len, NULL, NULL) <= 0)
        out[0] = 0;
}

/* Runs between the program's own clean exit and either Velopack's
 * Update.exe taking over, or the old version being started again. There is
 * no third way out of this function. On its own thread: the download is
 * minutes on a hotspot, and a window that does not repaint for minutes is a
 * window that gets killed. */
static DWORD WINAPI update_thread(LPVOID unused)
{
    static char root8[MAXP * 3], exe8[MAXP * 3], cur8[MAXP * 3], man8[MAXP * 3], pkg8[MAXP * 3];
    WCHAR root[MAXP], update_exe[MAXP], path[MAXP];
    vpkc_locator_config_t locator;
    vpkc_update_info_t *update = NULL;
    void *source = NULL, *manager = NULL;
    HMODULE dll = NULL;
    fn_source new_source;
    fn_manager new_manager;
    fn_check check;
    fn_download download;
    fn_apply apply;
    fn_free_info free_info;
    fn_free free_manager, free_source;
    BOOL applied = FALSE;

    (void)unused;

    set_status(T(T_UPD_CHECK), T(T_UPD_WAIT));

    if (!install_root(root, update_exe))
        goto done;

    /* By its full path, beside this executable. Never by name. */
    join(path, g_root, L"velopack_libc.dll");
    dll = LoadLibraryW(path);
    if (!dll)
        goto done;

    new_source = (fn_source)(void *)GetProcAddress(dll, "vpkc_new_source_github");
    new_manager = (fn_manager)(void *)GetProcAddress(dll, "vpkc_new_update_manager_with_source");
    check = (fn_check)(void *)GetProcAddress(dll, "vpkc_check_for_updates");
    download = (fn_download)(void *)GetProcAddress(dll, "vpkc_download_updates");
    apply = (fn_apply)(void *)GetProcAddress(dll, "vpkc_wait_exit_then_apply_updates");
    free_info = (fn_free_info)(void *)GetProcAddress(dll, "vpkc_free_update_info");
    free_manager = (fn_free)(void *)GetProcAddress(dll, "vpkc_free_update_manager");
    free_source = (fn_free)(void *)GetProcAddress(dll, "vpkc_free_source");

    if (!new_source || !new_manager || !check || !download || !apply || !free_info ||
        !free_manager || !free_source)
        goto done;

    /* `current\sq.version` is the manifest Velopack writes into the payload
     * when it packs; `packages` is where it keeps downloads, and need not
     * exist on an installation that has never updated. */
    utf8(root8, sizeof root8, root);
    utf8(exe8, sizeof exe8, update_exe);
    utf8(cur8, sizeof cur8, g_root);
    join(path, g_root, L"sq.version");
    utf8(man8, sizeof man8, path);
    join(path, root, L"\\packages");
    CreateDirectoryW(path, NULL);
    utf8(pkg8, sizeof pkg8, path);

    ZeroMemory(&locator, sizeof locator);
    locator.RootAppDir = root8;
    locator.UpdateExePath = exe8;
    locator.PackagesDir = pkg8;
    locator.ManifestPath = man8;
    locator.CurrentBinaryDir = cur8;
    locator.IsPortable = false;

    source = new_source(REPO_URL, NULL, false);
    if (!source)
        goto cleanup;

    if (!new_manager(source, NULL, &locator, &manager) || !manager)
        goto cleanup;

    if (check(manager, &update) != VPKC_UPDATE_AVAILABLE || !update || !update->TargetFullRelease)
        goto cleanup;

    set_status(T(T_UPD_DOWNLOAD), T(T_UPD_DOWNLOAD_HINT));
    if (!download(manager, update, NULL, NULL))
        goto cleanup;

    set_status(T(T_UPD_INSTALL), T(T_UPD_INSTALL_HINT));
    /* Velopack's Update.exe now waits for this process to end, swaps
     * `current\`, and starts Alnasl.exe again. */
    applied = apply(manager, update->TargetFullRelease, true, true, NULL, 0);

cleanup:
    if (update)
        free_info(update);
    if (manager)
        free_manager(manager);
    if (source)
        free_source(source);

done:
    if (applied) {
        PostMessageW(g_wnd, WM_CLOSE, 1, 0);
        return 0;
    }

    set_status(T(T_UPD_FAILED), T(T_UPD_FAILED_HINT));
    start_server();
    return 0;
}

/* -----------------------------------------------------------------------
 * Details - the panel the window grows when somebody clicks "Details"
 *
 * For the moment something is odd and somebody wants to say what: the
 * server's own output (launcher.log, which this file already writes) and a
 * few numbers about the running server - version, uptime, CPU, memory, how
 * long the database takes to answer - with a button that copies both, ready
 * to paste into a mail. Collapsed by default; while collapsed nothing below
 * runs except one sleeping thread.
 *
 * The numbers come from the server: `GET /_launcher/stats` on 127.0.0.1,
 * answered only to a desktop copy, a loopback peer and the secret this file
 * makes at every start and hands to the server in
 * ALNASL_LAUNCHER_TOKEN - see Alnasl.LauncherDetails and
 * docs/launcher-details.md, which is the contract the Mac launcher reads too.
 * The server words them ("summary": label/value lines); this file only
 * shows them, so there is no number formatting in C to get wrong.
 *
 * The log is read here, from the file, with every share flag: the server's
 * handle holds it open for writing for as long as it runs, and a reader must
 * never be the reason a write fails. Only the end is read (LOG_READ_BYTES),
 * once a second, and only while the panel is open. Somebody who has scrolled
 * up or selected text is reading: the text is left alone until they scroll
 * back to the bottom, the way a terminal behaves.
 *
 * WinHTTP for the request, BCryptGenRandom for the secret: both ship with
 * every Windows this runs on, and both are one -l in build_launcher.ps1.
 * ---------------------------------------------------------------------- */

#define WINDOW_STYLE (WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX)
#define WINDOW_W 460
/* What the window grows by, in design units: the numbers, the log, the two
 * buttons. */
#define DETAILS_H 380
#define LOG_TAIL_LINES 500
#define COPY_LOG_LINES 200
#define LOG_READ_BYTES (128 * 1024)
#define STATS_EVERY_MS 2000
#define LOG_EVERY_MS 1000
#define STATS_MAX_BYTES (256 * 1024)
#define TIMER_LOG 1
#define TIMER_COPIED 2

static HWND g_details_button, g_stats_box, g_log_box, g_copy_button, g_folder_button;
static HFONT g_mono;
static int g_mono_line = 14;
/* The collapsed client height, design units; set before the window exists. */
static int g_base_h = 200;
static volatile LONG g_details_open;
static HANDLE g_poll_wake;
/* What the numbers box shows, for Copy. UI thread only. */
static WCHAR *g_stats_shown;
static LARGE_INTEGER g_log_seen;

static void *mem(SIZE_T n)
{
    return HeapAlloc(GetProcessHeap(), 0, n);
}

static void unmem(void *p)
{
    if (p)
        HeapFree(GetProcessHeap(), 0, p);
}

static void make_token(void)
{
    static const WCHAR hex[] = L"0123456789abcdef";
    unsigned char raw[24];
    int i;

    g_token[0] = 0;
    if (!BCRYPT_SUCCESS(BCryptGenRandom(NULL, raw, sizeof raw, BCRYPT_USE_SYSTEM_PREFERRED_RNG)))
        return;

    for (i = 0; i < (int)sizeof raw; i++) {
        g_token[2 * i] = hex[raw[i] >> 4];
        g_token[2 * i + 1] = hex[raw[i] & 15];
    }
    g_token[2 * sizeof raw] = 0;
}

/* `len` bytes of UTF-8 as a new wide string; invalid bytes become U+FFFD. */
static WCHAR *wide_from_utf8(const char *s, int len)
{
    int n = len > 0 ? MultiByteToWideChar(CP_UTF8, 0, s, len, NULL, 0) : 0;
    WCHAR *w = mem(((SIZE_T)(n > 0 ? n : 0) + 1) * sizeof(WCHAR));

    if (!w)
        return NULL;
    if (n > 0)
        MultiByteToWideChar(CP_UTF8, 0, s, len, w, n);
    w[n > 0 ? n : 0] = 0;
    return w;
}

/* --- the numbers ---------------------------------------------------------- */

static const char *skip_ws(const char *s)
{
    while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n')
        s++;
    return s;
}

static void put_utf8(char *out, int cap, int *n, unsigned long c)
{
    if (c < 0x80) {
        if (*n < cap - 1)
            out[(*n)++] = (char)c;
    } else if (c < 0x800) {
        if (*n < cap - 2) {
            out[(*n)++] = (char)(0xC0 | (c >> 6));
            out[(*n)++] = (char)(0x80 | (c & 0x3F));
        }
    } else if (c < 0x10000) {
        if (*n < cap - 3) {
            out[(*n)++] = (char)(0xE0 | (c >> 12));
            out[(*n)++] = (char)(0x80 | ((c >> 6) & 0x3F));
            out[(*n)++] = (char)(0x80 | (c & 0x3F));
        }
    } else if (*n < cap - 4) {
        out[(*n)++] = (char)(0xF0 | (c >> 18));
        out[(*n)++] = (char)(0x80 | ((c >> 12) & 0x3F));
        out[(*n)++] = (char)(0x80 | ((c >> 6) & 0x3F));
        out[(*n)++] = (char)(0x80 | (c & 0x3F));
    }
}

static BOOL hex4(const char *s, unsigned long *out)
{
    int k;

    *out = 0;
    for (k = 0; k < 4; k++) {
        char h = s[k];
        *out <<= 4;
        if (h >= '0' && h <= '9')
            *out |= (unsigned long)(h - '0');
        else if (h >= 'a' && h <= 'f')
            *out |= (unsigned long)(h - 'a' + 10);
        else if (h >= 'A' && h <= 'F')
            *out |= (unsigned long)(h - 'A' + 10);
        else
            return FALSE; /* a NUL included: nothing past it is read */
    }
    return TRUE;
}

/* The JSON string at *p (its opening quote) into `out` as UTF-8, truncated
 * to `cap`, leaving *p after the closing quote. FALSE when it is not one. */
static BOOL json_string(const char **p, char *out, int cap)
{
    const char *s = *p;
    int n = 0;

    if (*s != '"')
        return FALSE;
    s++;

    while (*s && *s != '"') {
        unsigned long c;

        if (*s != '\\') {
            if (n < cap - 1)
                out[n++] = *s;
            s++;
            continue;
        }

        s++;
        switch (*s) {
        case '"':
        case '\\':
        case '/':
            c = (unsigned char)*s;
            break;
        case 'b':
            c = 8;
            break;
        case 'f':
            c = 12;
            break;
        case 'n':
            c = 10;
            break;
        case 'r':
            c = 13;
            break;
        case 't':
            c = 9;
            break;
        case 'u':
            if (!hex4(s + 1, &c))
                return FALSE;
            s += 4;
            if (c >= 0xD800 && c <= 0xDBFF && s[1] == '\\' && s[2] == 'u') {
                unsigned long low;
                if (!hex4(s + 3, &low))
                    return FALSE;
                if (low >= 0xDC00 && low <= 0xDFFF) {
                    c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
                    s += 6;
                }
            }
            break;
        default:
            return FALSE;
        }
        s++;
        put_utf8(out, cap, &n, c);
    }

    if (*s != '"')
        return FALSE;
    out[n] = 0;
    *p = s + 1;
    return TRUE;
}

static void append(char *out, int cap, int *n, const char *s)
{
    while (*s && *n < cap - 1)
        out[(*n)++] = *s++;
    out[*n] = 0;
}

/* `"summary":[{"label":"…","value":"…"},…]` as "Label: value" lines. Only
 * this one array is read; the rest of the answer is for programs. The
 * top-level key cannot be matched inside a string value: a quote in one is
 * always escaped. */
static BOOL summary_text(const char *json, char *out, int cap)
{
    const char *p = strstr(json, "\"summary\"");
    int n = 0;

    out[0] = 0;
    if (!p)
        return FALSE;
    p = skip_ws(p + 9);
    if (*p++ != ':')
        return FALSE;
    p = skip_ws(p);
    if (*p++ != '[')
        return FALSE;

    for (;;) {
        char key[32], label[160], value[640], ignored[64];

        label[0] = value[0] = 0;
        p = skip_ws(p);
        if (*p == ']')
            break;
        if (*p++ != '{')
            return FALSE;

        for (;;) {
            p = skip_ws(p);
            if (*p == '}') {
                p++;
                break;
            }
            if (!json_string(&p, key, sizeof key))
                return FALSE;
            p = skip_ws(p);
            if (*p++ != ':')
                return FALSE;
            p = skip_ws(p);
            if (!json_string(&p, lstrcmpA(key, "label") == 0   ? label
                                 : lstrcmpA(key, "value") == 0 ? value
                                                               : ignored,
                             lstrcmpA(key, "label") == 0   ? (int)sizeof label
                             : lstrcmpA(key, "value") == 0 ? (int)sizeof value
                                                           : (int)sizeof ignored))
                return FALSE;
            p = skip_ws(p);
            if (*p == ',')
                p++;
        }

        append(out, cap, &n, label);
        append(out, cap, &n, ": ");
        append(out, cap, &n, value);
        append(out, cap, &n, "\r\n");

        p = skip_ws(p);
        if (*p == ',')
            p++;
    }

    return n > 0;
}

/* The body of `GET /_launcher/stats`, NUL-terminated, or NULL for anything
 * but a 200 - not running yet, stopped, or the secret not accepted. The
 * session is kept across polls; it is this thread's alone. */
static HINTERNET g_http;

static char *http_stats(void)
{
    HINTERNET connection = NULL, request = NULL;
    WCHAR header[128];
    DWORD status = 0, size = sizeof status, avail, got, len = 0, cap = 0;
    char *body = NULL;
    BOOL ok = FALSE;

    if (!g_token[0])
        return NULL;

    if (!g_http) {
        /* No proxy: 127.0.0.1 is this machine whatever a proxy setting says. */
        g_http = WinHttpOpen(L"Alnasl launcher", WINHTTP_ACCESS_TYPE_NO_PROXY,
                             WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (!g_http)
            return NULL;
        WinHttpSetTimeouts(g_http, 1000, 1000, 2000, 3000);
    }

    connection = WinHttpConnect(g_http, L"127.0.0.1", (INTERNET_PORT)g_port, 0);
    if (connection)
        request = WinHttpOpenRequest(connection, L"GET",
                                     g_dutch ? L"/_launcher/stats?lang=nl"
                                             : L"/_launcher/stats?lang=en",
                                     NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
    if (!request)
        goto done;

    wsprintfW(header, L"X-Launcher-Token: %s\r\n", g_token);
    if (!WinHttpSendRequest(request, header, (DWORD)-1L, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(request, NULL))
        goto done;

    if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX, &status, &size,
                             WINHTTP_NO_HEADER_INDEX) ||
        status != 200)
        goto done;

    for (;;) {
        avail = 0;
        if (!WinHttpQueryDataAvailable(request, &avail))
            goto done;
        if (avail == 0)
            break;
        if (len + avail + 1 > STATS_MAX_BYTES)
            goto done;
        if (len + avail + 1 > cap) {
            char *grown;
            cap = len + avail + 1 + 4096;
            grown = body ? HeapReAlloc(GetProcessHeap(), 0, body, cap) : mem(cap);
            if (!grown)
                goto done;
            body = grown;
        }
        got = 0;
        if (!WinHttpReadData(request, body + len, avail, &got))
            goto done;
        if (got == 0)
            break;
        len += got;
    }

    if (body) {
        body[len] = 0;
        ok = TRUE;
    }

done:
    if (request)
        WinHttpCloseHandle(request);
    if (connection)
        WinHttpCloseHandle(connection);
    if (!ok) {
        unmem(body);
        body = NULL;
    }
    return body;
}

/* What the box says while there is no server to ask: a line saying so. */
static WCHAR *stats_placeholder(void)
{
    WCHAR *text = mem(256 * sizeof(WCHAR));

    if (!text)
        return NULL;
    lstrcpynW(text, T(T_DETAILS_WAITING), 256);
    return text;
}

/* Asks every STATS_EVERY_MS while the panel is open, and at once when it
 * opens (g_poll_wake). Posts the text, or NULL for "nobody answered"; the
 * window procedure owns it from there. Sleeps, and asks nothing, while the
 * panel is closed. */
static DWORD WINAPI stats_poller(LPVOID unused)
{
    (void)unused;

    for (;;) {
        WaitForSingleObject(g_poll_wake, STATS_EVERY_MS);
        if (!InterlockedCompareExchange(&g_details_open, 0, 0))
            continue;

        {
            char *body = http_stats();
            WCHAR *text = NULL;

            if (body) {
                char *summary = mem(16 * 1024);
                if (summary && summary_text(body, summary, 16 * 1024))
                    text = wide_from_utf8(summary, lstrlenA(summary));
                unmem(summary);
                unmem(body);
            }

            if (!PostMessageW(g_wnd, WM_APP_STATS, 0, (LPARAM)text))
                unmem(text);
        }
    }
}

/* --- the log ---------------------------------------------------------------- */

/* The last `max_lines` lines of launcher.log, with CRLF line ends and
 * without control characters or colour codes, or NULL when there is no file
 * to read. */
static WCHAR *log_tail(int max_lines, LARGE_INTEGER *size_out)
{
    HANDLE file;
    LARGE_INTEGER size, from;
    DWORD want, got = 0;
    char *raw, *clean, *start, *end, *p;
    int lines = 0, n = 0;
    WCHAR *text;

    file = CreateFileW(g_log, GENERIC_READ,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                       OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE)
        return NULL;

    if (!GetFileSizeEx(file, &size)) {
        CloseHandle(file);
        return NULL;
    }
    if (size_out)
        *size_out = size;

    from.QuadPart = size.QuadPart > LOG_READ_BYTES ? size.QuadPart - LOG_READ_BYTES : 0;
    want = (DWORD)(size.QuadPart - from.QuadPart);
    raw = mem((SIZE_T)want + 1);
    /* Every \n may become \r\n. */
    clean = mem((SIZE_T)want * 2 + 3);

    if (!raw || !clean || !SetFilePointerEx(file, from, NULL, FILE_BEGIN) ||
        !ReadFile(file, raw, want, &got, NULL)) {
        CloseHandle(file);
        unmem(raw);
        unmem(clean);
        return NULL;
    }
    CloseHandle(file);

    start = raw;
    end = raw + got;

    /* Read from the middle of a line: begin at the next one. */
    if (from.QuadPart > 0) {
        while (start < end && *start != '\n')
            start++;
        if (start < end)
            start++;
    }

    /* Back from the end to where the last `max_lines` lines begin. */
    p = end;
    if (p > start && p[-1] == '\n')
        p--;
    while (p > start) {
        if (p[-1] == '\n' && ++lines >= max_lines)
            break;
        p--;
    }

    for (; p < end; p++) {
        unsigned char c = (unsigned char)*p;

        if (c == '\n') {
            clean[n++] = '\r';
            clean[n++] = '\n';
        } else if (c == 0x1B) {
            /* ESC [ ... final byte: a colour code, if anything ever writes
             * one into a file. */
            if (p + 1 < end && p[1] == '[') {
                p += 2;
                while (p < end && !(*p >= '@' && *p <= '~'))
                    p++;
            }
        } else if (c == '\t' || c >= 0x20) {
            clean[n++] = (char)c;
        }
    }
    clean[n] = 0;

    text = wide_from_utf8(clean, n);
    unmem(raw);
    unmem(clean);
    return text;
}

static void refresh_log(BOOL force)
{
    LARGE_INTEGER size;
    WCHAR *text;

    if (!force) {
        DWORD sel_start = 0, sel_end = 0;
        int first, total, visible;
        RECT client;

        /* Somebody is selecting, or has scrolled up to read: leave it. */
        SendMessageW(g_log_box, EM_GETSEL, (WPARAM)&sel_start, (LPARAM)&sel_end);
        if (sel_start != sel_end)
            return;
        first = (int)SendMessageW(g_log_box, EM_GETFIRSTVISIBLELINE, 0, 0);
        total = (int)SendMessageW(g_log_box, EM_GETLINECOUNT, 0, 0);
        GetClientRect(g_log_box, &client);
        visible = (client.bottom - client.top) / (g_mono_line > 0 ? g_mono_line : 14);
        if (first + visible < total - 1)
            return;
    }

    size.QuadPart = -1;
    text = log_tail(LOG_TAIL_LINES, &size);
    if (!text) {
        if (force) {
            WCHAR missing[MAXP + 64];
            wsprintfW(missing, L"%s\r\n%s", T(T_DETAILS_NOLOG), g_log);
            SetWindowTextW(g_log_box, missing);
        }
        return;
    }

    if (!force && size.QuadPart == g_log_seen.QuadPart) {
        unmem(text);
        return;
    }

    g_log_seen = size;
    SetWindowTextW(g_log_box, text);
    unmem(text);
    SendMessageW(g_log_box, WM_VSCROLL, SB_BOTTOM, 0);
}

/* --- the two buttons and the toggle ----------------------------------------- */

static void copy_details(void)
{
    WCHAR *log = log_tail(COPY_LOG_LINES, NULL);
    SIZE_T chars = (SIZE_T)lstrlenW(g_title) + (g_stats_shown ? lstrlenW(g_stats_shown) : 0) +
                   (log ? lstrlenW(log) : 0) + lstrlenW(g_log) + 16;
    HGLOBAL block = GlobalAlloc(GMEM_MOVEABLE, chars * sizeof(WCHAR));
    WCHAR *text = block ? GlobalLock(block) : NULL;

    if (text) {
        lstrcpyW(text, g_title);
        lstrcatW(text, L"\r\n\r\n");
        if (g_stats_shown)
            lstrcatW(text, g_stats_shown);
        lstrcatW(text, L"\r\n");
        lstrcatW(text, g_log);
        lstrcatW(text, L"\r\n");
        if (log)
            lstrcatW(text, log);
        GlobalUnlock(block);

        if (OpenClipboard(g_wnd)) {
            EmptyClipboard();
            /* From here the clipboard owns it. */
            if (SetClipboardData(CF_UNICODETEXT, block)) {
                block = NULL;
                SetWindowTextW(g_copy_button, T(T_DETAILS_COPIED));
                SetTimer(g_wnd, TIMER_COPIED, 1500, NULL);
            }
            CloseClipboard();
        }
    }

    if (block)
        GlobalFree(block);
    unmem(log);
}

static void open_log_folder(void)
{
    WCHAR args[MAXP + 16], dir[MAXP];
    int n;

    if (exists(g_log)) {
        /* The folder, with the file already selected in it. */
        wsprintfW(args, L"/select,\"%s\"", g_log);
        ShellExecuteW(NULL, L"open", L"explorer.exe", args, NULL, SW_SHOWNORMAL);
        return;
    }

    lstrcpynW(dir, g_log, MAXP);
    n = lstrlenW(dir);
    while (n > 0 && dir[n - 1] != L'\\')
        n--;
    dir[n] = 0;
    ShellExecuteW(NULL, L"open", dir, NULL, NULL, SW_SHOWNORMAL);
}

static void set_details(BOOL open)
{
    RECT rect;
    int show = open ? SW_SHOW : SW_HIDE;
    HMONITOR monitor;
    MONITORINFO info;

    InterlockedExchange(&g_details_open, open ? 1 : 0);
    ShowWindow(g_stats_box, show);
    ShowWindow(g_log_box, show);
    ShowWindow(g_copy_button, show);
    ShowWindow(g_folder_button, show);
    {
        WCHAR label[64];
        wsprintfW(label, open ? L"%s \x25B4" : L"%s \x25BE", T(T_DETAILS));
        SetWindowTextW(g_details_button, label);
    }

    SetRect(&rect, 0, 0, S(WINDOW_W), S(g_base_h + (open ? DETAILS_H : 0)));
    AdjustWindowRect(&rect, WINDOW_STYLE, FALSE);
    SetWindowPos(g_wnd, NULL, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);

    /* Grown past the bottom of the screen: up, as far as the top allows. */
    GetWindowRect(g_wnd, &rect);
    monitor = MonitorFromWindow(g_wnd, MONITOR_DEFAULTTONEAREST);
    info.cbSize = sizeof info;
    if (monitor && GetMonitorInfoW(monitor, &info) && rect.bottom > info.rcWork.bottom) {
        int top = info.rcWork.bottom - (rect.bottom - rect.top);
        if (top < info.rcWork.top)
            top = info.rcWork.top;
        SetWindowPos(g_wnd, NULL, rect.left, top, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    if (open) {
        if (!g_stats_shown) {
            g_stats_shown = stats_placeholder();
            if (g_stats_shown)
                SetWindowTextW(g_stats_box, g_stats_shown);
        }
        refresh_log(TRUE);
        SetTimer(g_wnd, TIMER_LOG, LOG_EVERY_MS, NULL);
        SetEvent(g_poll_wake);
    } else {
        KillTimer(g_wnd, TIMER_LOG);
    }
}

static void build_details(HWND wnd)
{
    int y = g_base_h;
    LOGFONTW lf;
    HDC dc;
    TEXTMETRICW metrics;

    ZeroMemory(&lf, sizeof lf);
    lf.lfHeight = -MulDiv(9, g_dpi, 72);
    lf.lfWeight = FW_NORMAL;
    lf.lfCharSet = DEFAULT_CHARSET;
    lf.lfPitchAndFamily = FIXED_PITCH | FF_MODERN;
    lstrcpynW(lf.lfFaceName, L"Consolas", LF_FACESIZE);
    g_mono = CreateFontIndirectW(&lf);

    dc = GetDC(wnd);
    if (dc) {
        HGDIOBJ previous = SelectObject(dc, g_mono);
        if (GetTextMetricsW(dc, &metrics))
            g_mono_line = metrics.tmHeight + metrics.tmExternalLeading;
        SelectObject(dc, previous);
        ReleaseDC(wnd, dc);
    }

    {
        WCHAR label[64];

        wsprintfW(label, L"%s \x25BE", T(T_DETAILS));
        g_details_button = CreateWindowExW(0, L"BUTTON", label,
                                           WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                                           S(198), S(152), S(66), S(30), wnd,
                                           (HMENU)(INT_PTR)IDC_DETAILS, g_inst, NULL);
    }
    SendMessageW(g_details_button, WM_SETFONT, (WPARAM)g_font, TRUE);

    /* Read-only edit controls, not labels: the text can be selected and
     * scrolled. Hidden until the panel opens. */
    g_stats_box = CreateWindowExW(0, L"EDIT", L"",
                                  WS_CHILD | WS_VSCROLL | ES_MULTILINE | ES_READONLY |
                                      ES_AUTOVSCROLL,
                                  S(20), S(y + 2), S(420), S(156), wnd,
                                  (HMENU)(INT_PTR)IDC_STATS, g_inst, NULL);
    SendMessageW(g_stats_box, WM_SETFONT, (WPARAM)g_font, TRUE);

    g_log_box = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                WS_CHILD | WS_VSCROLL | WS_HSCROLL | ES_MULTILINE | ES_READONLY |
                                    ES_AUTOVSCROLL | ES_AUTOHSCROLL,
                                S(20), S(y + 166), S(420), S(164), wnd,
                                (HMENU)(INT_PTR)IDC_LOG, g_inst, NULL);
    SendMessageW(g_log_box, WM_SETFONT, (WPARAM)g_mono, TRUE);
    /* The default limit is 30,000 characters; 500 log lines can be more. */
    SendMessageW(g_log_box, EM_SETLIMITTEXT, 0, 0);

    g_copy_button = CreateWindowExW(0, L"BUTTON", T(T_DETAILS_COPY), WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
                                    S(20), S(y + 340), S(200), S(28), wnd,
                                    (HMENU)(INT_PTR)IDC_COPY, g_inst, NULL);
    g_folder_button = CreateWindowExW(0, L"BUTTON", T(T_DETAILS_FOLDER),
                                      WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON, S(240), S(y + 340),
                                      S(200), S(28), wnd, (HMENU)(INT_PTR)IDC_FOLDER, g_inst,
                                      NULL);
    SendMessageW(g_copy_button, WM_SETFONT, (WPARAM)g_font, TRUE);
    SendMessageW(g_folder_button, WM_SETFONT, (WPARAM)g_font, TRUE);
}
/* --- the window ------------------------------------------------------------ */

static HWND control(const WCHAR *class, const WCHAR *text, DWORD style, int id, int x, int y,
                    int w, int h, HFONT font)
{
    HWND c = CreateWindowExW(0, class, text, WS_CHILD | WS_VISIBLE | style, S(x), S(y), S(w),
                             S(h), g_wnd, (HMENU)(INT_PTR)id, g_inst, NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)font, TRUE);
    return c;
}

static void show_log_path(int text)
{
    WCHAR hint[MAXP + 256];

    wsprintfW(hint, L"%s\n%s", T(text), g_log);
    SetWindowTextW(g_hint, hint);
}

static LRESULT CALLBACK window_proc(HWND wnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_CREATE: {
        NONCLIENTMETRICSW metrics;

        g_wnd = wnd;
        metrics.cbSize = sizeof metrics;
        SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof metrics, &metrics, 0);
        g_font = CreateFontIndirectW(&metrics.lfMessageFont);
        metrics.lfMessageFont.lfWeight = FW_SEMIBOLD;
        metrics.lfMessageFont.lfHeight = metrics.lfMessageFont.lfHeight * 5 / 4;
        g_bold = CreateFontIndirectW(&metrics.lfMessageFont);

        g_status = control(L"STATIC", T(T_STARTING), SS_NOPREFIX, IDC_STATUS, 20, 18, 420, 26,
                           g_bold);
        g_url_label = control(L"STATIC", g_url, SS_NOPREFIX, IDC_URL, 20, 48, 420, 20, g_font);
        g_hint = control(L"STATIC", T(T_STARTING_HINT), SS_NOPREFIX, IDC_HINT, 20, 76, 420, 66,
                         g_font);
        g_open = control(L"BUTTON", T(T_OPEN), BS_DEFPUSHBUTTON | WS_TABSTOP | WS_DISABLED,
                         IDC_OPEN, 20, 152, 170, 30, g_font);
        g_stop = control(L"BUTTON", T(T_STOP), BS_PUSHBUTTON | WS_TABSTOP, IDC_STOP, 270, 152,
                         170, 30, g_font);
        build_details(wnd);
        return 0;
    }

    case WM_CTLCOLORSTATIC:
        /* The Details panel's read-only edit controls ask here too, and they
         * scroll: a transparent background would smear. The labels keep the
         * default. */
        if ((HWND)lp == g_stats_box || (HWND)lp == g_log_box) {
            SetTextColor((HDC)wp, GetSysColor(COLOR_WINDOWTEXT));
            SetBkColor((HDC)wp, GetSysColor(COLOR_WINDOW));
            return (LRESULT)GetSysColorBrush(COLOR_WINDOW);
        }
        break;

    case WM_APP_READY:
        g_running = TRUE;
        set_status(T(T_RUNNING), T(T_RUNNING_HINT));
        EnableWindow(g_open, TRUE);
        if (!g_background)
            open_browser();
        /* Only the first start opens a browser by itself. */
        g_background = TRUE;
        return 0;

    case WM_APP_SLOW:
        SetWindowTextW(g_hint, T(T_SLOW));
        return 0;

    case WM_APP_FAILED:
        g_running = FALSE;
        SetWindowTextW(g_status, T(T_STOPPED));
        show_log_path(wp ? T_TIMEOUT : T_FAILED);
        SetWindowTextW(g_stop, T(T_CLOSE));
        ShowWindow(wnd, SW_RESTORE);
        return 0;

    case WM_APP_EXITED:
        g_running = FALSE;
        EnableWindow(g_open, FALSE);

        if (wp == ALNASL_UPDATE_EXIT_CODE) {
            HANDLE thread = CreateThread(NULL, 0, update_thread, NULL, 0, NULL);
            ShowWindow(wnd, SW_RESTORE);
            if (thread)
                CloseHandle(thread);
        } else {
            SetWindowTextW(g_status, T(T_STOPPED));
            show_log_path(T_STOPPED_HINT);
            SetWindowTextW(g_stop, T(T_CLOSE));
            ShowWindow(wnd, SW_RESTORE);
        }
        return 0;

    case WM_COMMAND:
        if (LOWORD(wp) == IDC_OPEN)
            open_browser();
        else if (LOWORD(wp) == IDC_STOP)
            SendMessageW(wnd, WM_CLOSE, 0, 0);
        else if (LOWORD(wp) == IDC_DETAILS)
            set_details(!InterlockedCompareExchange(&g_details_open, 0, 0));
        else if (LOWORD(wp) == IDC_COPY)
            copy_details();
        else if (LOWORD(wp) == IDC_FOLDER)
            open_log_folder();
        return 0;

    case WM_TIMER:
        if (wp == TIMER_LOG) {
            refresh_log(FALSE);
        } else if (wp == TIMER_COPIED) {
            KillTimer(wnd, TIMER_COPIED);
            SetWindowTextW(g_copy_button, T(T_DETAILS_COPY));
        }
        return 0;

    case WM_APP_STATS: {
        WCHAR *text = lp ? (WCHAR *)lp : stats_placeholder();

        /* Unchanged text is not set again: setting it scrolls the box back
         * to the top under somebody reading the bottom of it. */
        if (text && (!g_stats_shown || lstrcmpW(g_stats_shown, text) != 0)) {
            SetWindowTextW(g_stats_box, text);
            unmem(g_stats_shown);
            g_stats_shown = text;
        } else {
            unmem(text);
        }
        return 0;
    }

    case WM_CLOSE:
        /* wp == 1 is the update handing over: nobody is asked twice. */
        if (wp != 1 && g_running &&
            MessageBoxW(wnd, T(T_CONFIRM_STOP), g_title,
                        MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) != IDYES)
            return 0;
        DestroyWindow(wnd);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }

    return DefWindowProcW(wnd, msg, wp, lp);
}

static void create_window(void)
{
    WNDCLASSEXW wc;
    RECT rect;
    HDC dc = GetDC(NULL);
    DWORD style = WINDOW_STYLE;

    g_dpi = GetDeviceCaps(dc, LOGPIXELSX);
    ReleaseDC(NULL, dc);

    ZeroMemory(&wc, sizeof wc);
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = window_proc;
    wc.hInstance = g_inst;
    wc.hIcon = LoadIconW(g_inst, MAKEINTRESOURCEW(1));
    wc.hIconSm = wc.hIcon;
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = L"AlnaslLauncher";
    RegisterClassExW(&wc);

    SetRect(&rect, 0, 0, S(WINDOW_W), S(g_base_h));
    AdjustWindowRect(&rect, style, FALSE);

    if (!CreateWindowExW(0, wc.lpszClassName, g_title, style, CW_USEDEFAULT, CW_USEDEFAULT,
                         rect.right - rect.left, rect.bottom - rect.top, NULL, NULL, g_inst,
                         NULL))
        fatal(L"Alnasl could not open its window.");

    /* Started with Windows: there, in the taskbar, and not in anybody's
     * face. */
    ShowWindow(g_wnd, g_background ? SW_SHOWMINNOACTIVE : SW_SHOWNORMAL);
    UpdateWindow(g_wnd);
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show)
{
    WSADATA wsa;
    HANDLE mutex;
    WCHAR name[64], message[512];
    INITCOMMONCONTROLSEX icc;
    MSG msg;

    (void)prev;
    (void)cmdline;
    (void)show;

    g_inst = inst;

    /* Velopack's hooks: answer and leave. See the top of this file. */
    if (has_arg(L"--veloapp-", FALSE) || has_arg(L"--squirrel-", FALSE)) {
        if (has_arg(L"--veloapp-uninstall", TRUE))
            RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_KEY, RUN_VALUE);
        return 0;
    }

    g_dutch = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_DUTCH;
    g_background = has_arg(L"--background", TRUE);

    icc.dwSize = sizeof icc;
    icc.dwICC = ICC_STANDARD_CLASSES;
    InitCommonControlsEx(&icc);

    resolve_root();
    read_version();
    g_port = read_port();
    wsprintfW(g_url, L"http://localhost:%d", g_port);
    resolve_data();

    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0)
        fatal(L"Alnasl could not start Windows networking.");

    /* A second double-click shows the Alnasl that is running; it does not
     * start one that cannot have the port. */
    wsprintfW(name, L"Local\\Alnasl.Launcher.%d", g_port);
    mutex = CreateMutexW(NULL, TRUE, name);
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        open_browser();
        return 0;
    }

    if (port_open()) {
        wsprintfW(message, T(T_PORT_BUSY), g_port);
        if (!g_background &&
            MessageBoxW(NULL, message, L"Alnasl", MB_YESNO | MB_ICONINFORMATION) == IDYES)
            open_browser();
        return 0;
    }

    make_token();
    g_poll_wake = CreateEventW(NULL, FALSE, FALSE, NULL);

    create_window();
    start_server();

    /* After the window exists, so the thread always has somewhere to post
     * to. It asks nothing while the panel is closed. */
    {
        HANDLE thread = CreateThread(NULL, 0, stats_poller, NULL, 0, NULL);
        if (thread)
            CloseHandle(thread);
    }

    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (!IsDialogMessageW(g_wnd, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    stop_server();
    return 0;
}
