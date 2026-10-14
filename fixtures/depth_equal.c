/* Checks tools/depth-equal-fix: creates a depth-stencil state with an EQUAL depth test and prints
 * the depth test the device kept. Prints "depth_func=GREATER_EQUAL" with the fix in front of DXMT,
 * "depth_func=EQUAL" without it. Exits 0 when a device and the state were created. */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>

static const char *name(D3D11_COMPARISON_FUNC func)
{
    switch (func)
    {
    case D3D11_COMPARISON_EQUAL: return "EQUAL";
    case D3D11_COMPARISON_GREATER_EQUAL: return "GREATER_EQUAL";
    case D3D11_COMPARISON_LESS_EQUAL: return "LESS_EQUAL";
    default: return "other";
    }
}

int main(void)
{
    ID3D11Device *device = NULL;
    ID3D11DepthStencilState *state = NULL;
    D3D11_DEPTH_STENCIL_DESC desc = {0}, kept;
    HRESULT hr;

    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &device, NULL, NULL);
    if (FAILED(hr)) { printf("FAIL D3D11CreateDevice 0x%08lx\n", hr); return 1; }

    /* The G-buffer pass after a depth prepass: test only, no writes. */
    desc.DepthEnable = TRUE;
    desc.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ZERO;
    desc.DepthFunc = D3D11_COMPARISON_EQUAL;
    hr = ID3D11Device_CreateDepthStencilState(device, &desc, &state);
    if (FAILED(hr)) { printf("FAIL CreateDepthStencilState 0x%08lx\n", hr); return 1; }
    ID3D11DepthStencilState_GetDesc(state, &kept);
    printf("depth_func=%s\n", name(kept.DepthFunc));

    ID3D11DepthStencilState_Release(state);
    ID3D11Device_Release(device);
    return 0;
}
