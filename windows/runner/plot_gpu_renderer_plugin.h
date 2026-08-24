#ifndef RUNNER_PLOT_GPU_RENDERER_PLUGIN_H_
#define RUNNER_PLOT_GPU_RENDERER_PLUGIN_H_

#include <flutter_plugin_registrar.h>

// 注册仅负责绘图数据层的 Windows D3D11 外部纹理后端。
void PlotGpuRendererPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#endif  // RUNNER_PLOT_GPU_RENDERER_PLUGIN_H_
