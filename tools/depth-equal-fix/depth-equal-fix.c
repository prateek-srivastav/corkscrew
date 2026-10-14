/* d3d11.dll for God of War (2018) on DXMT: turns EQUAL depth tests into GREATER_EQUAL.
 *
 * The game fills its G-buffer after a depth prepass, with an EQUAL depth test and depth writes off.
 * On Metal the two passes don't always compute bit-identical vertex positions, so some of Kratos's
 * pixels fail the test, keep the cleared G-buffer and show as white specks. The game uses reverse
 * Z, so GREATER_EQUAL lets those pixels pass. The prepass already holds the nearest depth, so only
 * geometry missing from the prepass could now draw where EQUAL would hide it.
 *
 * Corkscrew puts this file next to the game as d3d11.dll, and DXMT's own d3d11.dll next to it as
 * corkscrew_dxmt_d3d11.dll, which does all the work. CORKSCREW_DEPTH_EQUAL picks the replacement:
 * greater_equal (the default), less_equal (for games with standard Z) or off.
 *
 * Cause found by a CrossOver user who bisected the game's shaders with a d3d11 proxy
 * (r/Codeweavers_Crossover, "God Of War 2018 White Dot Fix"). The root fix belongs in the shader
 * translator: positions must be invariant across shaders. */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#define REAL_DLL L"corkscrew_dxmt_d3d11.dll"

/* Also how Corkscrew tells its own d3d11.dll from one a game or mod ships. */
static const char banner[] = "Corkscrew depth-equal fix";

typedef HRESULT (STDMETHODCALLTYPE *create_state_fn)(ID3D11Device *, const D3D11_DEPTH_STENCIL_DESC *,
                                                     ID3D11DepthStencilState **);
typedef HRESULT (WINAPI *create_device_fn)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT, const D3D_FEATURE_LEVEL *,
                                           UINT, UINT, ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
typedef HRESULT (WINAPI *create_device_swapchain_fn)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT,
                                                     const D3D_FEATURE_LEVEL *, UINT, UINT, const DXGI_SWAP_CHAIN_DESC *,
                                                     IDXGISwapChain **, ID3D11Device **, D3D_FEATURE_LEVEL *,
                                                     ID3D11DeviceContext **);

static HMODULE our_module, real;
static SRWLOCK lock = SRWLOCK_INIT;
/* 0 = off. */
static D3D11_COMPARISON_FUNC replacement = D3D11_COMPARISON_GREATER_EQUAL;
static create_state_fn real_create_state;
static LONG replaced;

static HRESULT STDMETHODCALLTYPE create_state(ID3D11Device *device, const D3D11_DEPTH_STENCIL_DESC *desc,
                                              ID3D11DepthStencilState **state)
{
    if (desc && desc->DepthEnable && desc->DepthFunc == D3D11_COMPARISON_EQUAL)
    {
        D3D11_DEPTH_STENCIL_DESC copy = *desc;
        copy.DepthFunc = replacement;
        if (InterlockedIncrement(&replaced) == 1) fprintf(stderr, "%s: replacing EQUAL depth tests\n", banner);
        return real_create_state(device, &copy, state);
    }
    return real_create_state(device, desc, state);
}

/* Points the device class's CreateDepthStencilState at create_state. Every DXMT device shares one
 * vtable, so this happens once. */
static void hook(ID3D11Device *device)
{
    void **slot;
    DWORD old;

    if (!device || !replacement) return;
    AcquireSRWLockExclusive(&lock);
    slot = (void **)&device->lpVtbl->CreateDepthStencilState;
    if (*slot == (void *)create_state) goto done;
    if (real_create_state && *slot != (void *)real_create_state)
    {
        fprintf(stderr, "%s: a device with another vtable, left alone\n", banner);
        goto done;
    }
    if (!VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &old))
    {
        fprintf(stderr, "%s: can't patch the device vtable (error %lu)\n", banner, GetLastError());
        goto done;
    }
    real_create_state = (create_state_fn)*slot;
    *slot = (void *)create_state;
    VirtualProtect(slot, sizeof(*slot), old, &old);
    fprintf(stderr, "%s: on, EQUAL becomes %s\n", banner,
            replacement == D3D11_COMPARISON_GREATER_EQUAL ? "GREATER_EQUAL" : "LESS_EQUAL");
done:
    ReleaseSRWLockExclusive(&lock);
}

static void hook_context(ID3D11DeviceContext *context)
{
    ID3D11Device *device = NULL;

    if (!context) return;
    ID3D11DeviceContext_GetDevice(context, &device);
    hook(device);
    if (device) ID3D11Device_Release(device);
}

/* DXMT's d3d11.dll from this DLL's own folder. */
static FARPROC real_proc(const char *name)
{
    if (!real)
    {
        WCHAR path[MAX_PATH];
        DWORD len = GetModuleFileNameW(our_module, path, MAX_PATH);
        WCHAR *slash = len && len < MAX_PATH ? wcsrchr(path, L'\\') : NULL;
        if (!slash || (slash - path) + 1 + wcslen(REAL_DLL) >= MAX_PATH) return NULL;
        wcscpy(slash + 1, REAL_DLL);
        if (!(real = LoadLibraryW(path)))
        {
            fprintf(stderr, "%s: can't load %ls (error %lu)\n", banner, REAL_DLL, GetLastError());
            return NULL;
        }
    }
    return GetProcAddress(real, name);
}

HRESULT WINAPI shim_D3D11CreateDevice(IDXGIAdapter *adapter, D3D_DRIVER_TYPE driver_type, HMODULE software, UINT flags,
                                      const D3D_FEATURE_LEVEL *levels, UINT level_count, UINT sdk_version,
                                      ID3D11Device **device, D3D_FEATURE_LEVEL *level, ID3D11DeviceContext **context)
{
    create_device_fn create = (create_device_fn)real_proc("D3D11CreateDevice");
    HRESULT hr;

    if (!create) return E_FAIL;
    hr = create(adapter, driver_type, software, flags, levels, level_count, sdk_version, device, level, context);
    if (SUCCEEDED(hr))
    {
        if (device && *device) hook(*device);
        else if (context) hook_context(*context);
    }
    return hr;
}

HRESULT WINAPI shim_D3D11CreateDeviceAndSwapChain(IDXGIAdapter *adapter, D3D_DRIVER_TYPE driver_type, HMODULE software,
                                                  UINT flags, const D3D_FEATURE_LEVEL *levels, UINT level_count,
                                                  UINT sdk_version, const DXGI_SWAP_CHAIN_DESC *swapchain_desc,
                                                  IDXGISwapChain **swapchain, ID3D11Device **device,
                                                  D3D_FEATURE_LEVEL *level, ID3D11DeviceContext **context)
{
    create_device_swapchain_fn create = (create_device_swapchain_fn)real_proc("D3D11CreateDeviceAndSwapChain");
    HRESULT hr;

    if (!create) return E_FAIL;
    hr = create(adapter, driver_type, software, flags, levels, level_count, sdk_version, swapchain_desc, swapchain,
                device, level, context);
    if (SUCCEEDED(hr))
    {
        if (device && *device) hook(*device);
        else if (context) hook_context(*context);
    }
    return hr;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    char value[32] = "";
    DWORD len;

    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    our_module = instance;
    DisableThreadLibraryCalls(instance);
    len = GetEnvironmentVariableA("CORKSCREW_DEPTH_EQUAL", value, sizeof(value));
    if (len && len < sizeof(value))
    {
        if (!_stricmp(value, "off") || !strcmp(value, "0")) replacement = 0;
        else if (!_stricmp(value, "less_equal")) replacement = D3D11_COMPARISON_LESS_EQUAL;
    }
    if (!replacement) fprintf(stderr, "%s: off (CORKSCREW_DEPTH_EQUAL=%s)\n", banner, value);
    return TRUE;
}
