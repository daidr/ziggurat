/* Runs translated shader programs on Direct3D 11 (WARP, the software
   rasterizer every Windows has) one invocation per pixel, for the GPU/CPU
   parity check. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

int zgpu_hlsl_compile(const char *source, size_t source_len, const char *entry, const char *target, uint8_t **code, size_t *code_len, char *log, size_t log_len);
void zgpu_hlsl_free(uint8_t *code);

static ID3D11Device *device;
static ID3D11DeviceContext *context;

int zsd_init(char *log, size_t log_len) {
    if (device) return 0;
    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, 0, levels, 3, D3D11_SDK_VERSION, &device, NULL, &context);
    if (FAILED(hr)) {
        snprintf(log, log_len, "no WARP device (0x%08lx)", (unsigned long)hr);
        return 1;
    }
    return 0;
}

int zsd_run(const char *source, const uint32_t *words, uint32_t word_count, uint32_t width, uint32_t height, float *result, float *status, char *log, size_t log_len) {
    static const char vertex[] = "float4 main(uint id : SV_VertexID) : SV_Position { float2 p = float2(id == 1 ? 3.0 : -1.0, id == 2 ? 3.0 : -1.0); return float4(p, 0.0, 1.0); }";
    uint8_t *vs_code = NULL, *ps_code = NULL;
    size_t vs_len = 0, ps_len = 0;
    int code = zgpu_hlsl_compile(vertex, sizeof(vertex) - 1, "main", "vs_4_0", &vs_code, &vs_len, log, log_len);
    if (code) return 10 + code;
    code = zgpu_hlsl_compile(source, strlen(source), "main", "ps_4_0", &ps_code, &ps_len, log, log_len);
    if (code) {
        zgpu_hlsl_free(vs_code);
        return 20 + code;
    }
    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader *ps = NULL;
    ID3D11Texture2D *targets[2] = {0}, *staging[2] = {0};
    ID3D11RenderTargetView *views[2] = {0};
    ID3D11Buffer *constants = NULL;
    ID3D11RasterizerState *raster = NULL;
    HRESULT hr = ID3D11Device_CreateVertexShader(device, vs_code, vs_len, NULL, &vs);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreatePixelShader(device, ps_code, ps_len, NULL, &ps);
    zgpu_hlsl_free(vs_code);
    zgpu_hlsl_free(ps_code);
    for (int i = 0; i < 2 && SUCCEEDED(hr); i++) {
        D3D11_TEXTURE2D_DESC desc = {0};
        desc.Width = width;
        desc.Height = height;
        desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
        desc.Format = DXGI_FORMAT_R32G32B32A32_FLOAT;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET;
        hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &targets[i]);
        if (SUCCEEDED(hr)) hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)targets[i], NULL, &views[i]);
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        if (SUCCEEDED(hr)) hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging[i]);
    }
    if (SUCCEEDED(hr)) {
        uint32_t padded[4096] = {0};
        UINT vectors = (word_count + 3) / 4;
        if (vectors == 0) vectors = 1;
        memcpy(padded, words, word_count * sizeof(uint32_t));
        D3D11_BUFFER_DESC desc = {.ByteWidth = vectors * 16, .Usage = D3D11_USAGE_DEFAULT, .BindFlags = D3D11_BIND_CONSTANT_BUFFER};
        D3D11_SUBRESOURCE_DATA data = {.pSysMem = padded};
        hr = ID3D11Device_CreateBuffer(device, &desc, &data, &constants);
    }
    if (SUCCEEDED(hr)) {
        D3D11_RASTERIZER_DESC desc = {.FillMode = D3D11_FILL_SOLID, .CullMode = D3D11_CULL_NONE, .DepthClipEnable = TRUE};
        hr = ID3D11Device_CreateRasterizerState(device, &desc, &raster);
    }
    if (SUCCEEDED(hr)) {
        ID3D11DeviceContext_ClearState(context);
        D3D11_VIEWPORT viewport = {0, 0, (float)width, (float)height, 0, 1};
        ID3D11DeviceContext_RSSetViewports(context, 1, &viewport);
        ID3D11DeviceContext_RSSetState(context, raster);
        ID3D11DeviceContext_IASetPrimitiveTopology(context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D11DeviceContext_VSSetShader(context, vs, NULL, 0);
        ID3D11DeviceContext_PSSetShader(context, ps, NULL, 0);
        ID3D11DeviceContext_PSSetConstantBuffers(context, 0, 1, &constants);
        ID3D11DeviceContext_OMSetRenderTargets(context, 2, views, NULL);
        ID3D11DeviceContext_Draw(context, 3, 0);
        ID3D11DeviceContext_OMSetRenderTargets(context, 0, NULL, NULL);
        float *outputs[2] = {result, status};
        for (int i = 0; i < 2 && SUCCEEDED(hr); i++) {
            ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging[i], (ID3D11Resource *)targets[i]);
            D3D11_MAPPED_SUBRESOURCE map;
            hr = ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging[i], 0, D3D11_MAP_READ, 0, &map);
            if (SUCCEEDED(hr)) {
                for (uint32_t y = 0; y < height; y++) memcpy(outputs[i] + (size_t)y * width * 4, (const uint8_t *)map.pData + (size_t)y * map.RowPitch, (size_t)width * 16);
                ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging[i], 0);
            }
        }
    }
    if (FAILED(hr)) {
        snprintf(log, log_len, "Direct3D failed (0x%08lx)", (unsigned long)hr);
        code = 30;
    }
    if (raster) ID3D11RasterizerState_Release(raster);
    if (constants) ID3D11Buffer_Release(constants);
    for (int i = 0; i < 2; i++) {
        if (views[i]) ID3D11RenderTargetView_Release(views[i]);
        if (targets[i]) ID3D11Texture2D_Release(targets[i]);
        if (staging[i]) ID3D11Texture2D_Release(staging[i]);
    }
    if (ps) ID3D11PixelShader_Release(ps);
    if (vs) ID3D11VertexShader_Release(vs);
    return code;
}
