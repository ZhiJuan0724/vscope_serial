/// 绘图数据层使用的渲染后端。
enum PlotRenderEngine {
  /// Flutter Canvas，兼容所有平台并作为故障回退。
  canvas,

  /// Windows D3D11 外部纹理，只接管曲线数据层。
  d3d11,
}
