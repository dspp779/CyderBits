#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>

int main(void)
{
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL feature_level = 0;
    HRESULT hr;

    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
            D3D11_SDK_VERSION, &device, &feature_level, &context);
    printf("D3D11CreateDevice hr=0x%08lx feature_level=0x%04x\n",
            (unsigned long)hr, (unsigned int)feature_level);

    if (context) ID3D11DeviceContext_Release(context);
    if (device) ID3D11Device_Release(device);
    return FAILED(hr);
}
