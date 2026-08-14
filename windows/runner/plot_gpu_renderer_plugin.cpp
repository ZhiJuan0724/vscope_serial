#include "plot_gpu_renderer_plugin.h"

#include <d3d11.h>
#include <d3dcompiler.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kChannelName[] = "vscope_serial/plot_gpu_renderer";
constexpr UINT kPrimitiveStride = sizeof(float) * 6;
constexpr size_t kMaxChannels = 20;

constexpr char kShaderSource[] = R"(
cbuffer FrameData : register(b0) {
  float2 targetSize;
  float2 xTransform;
  float2 yTransform;
  float2 padding;
  float4 channelGeometry[20];
  float4 channelColor[20];
  float4 channelFlags[20];
};

struct Primitive {
  float2 p0 : POSITION0;
  float2 p1 : POSITION1;
  float kind : TEXCOORD0;
  float channel : TEXCOORD1;
};

struct VertexOutput {
  float4 position : SV_POSITION;
  float2 localPosition : TEXCOORD0;
  nointerpolation float segmentLength : TEXCOORD1;
  nointerpolation float radius : TEXCOORD2;
  nointerpolation float visible : TEXCOORD3;
  float4 color : COLOR0;
};

VertexOutput vertexMain(Primitive input, uint vertexId : SV_VertexID) {
  VertexOutput output;
  uint channelIndex = min((uint)round(input.channel), 19u);
  float4 geometry = channelGeometry[channelIndex];
  float4 flags = channelFlags[channelIndex];
  bool isPoint = input.kind > 0.5;
  float enabled = flags.x * (isPoint ? flags.z : flags.y);
  float2 p0 = float2(input.p0.x * xTransform.x + xTransform.y,
                     (input.p0.y * geometry.x + geometry.y) * yTransform.x +
                         yTransform.y);
  float2 p1 = float2(input.p1.x * xTransform.x + xTransform.y,
                     (input.p1.y * geometry.x + geometry.y) * yTransform.x +
                         yTransform.y);
  float2 delta = p1 - p0;
  float rawLength = length(delta);
  float lengthValue = isPoint ? 0.0 : rawLength;
  // 点仍复用实例化线段缓冲，但以零长度图元编码。为零长度指定稳定的
  // 基向量，避免四个顶点全部塌缩到同一位置。
  float2 direction = isPoint ? float2(1.0, 0.0) : delta / rawLength;
  float2 normal = float2(-direction.y, direction.x);
  float width = isPoint ? geometry.w : geometry.z;
  float radius = max(width * 0.5, 0.5);
  float expansion = radius + 1.0;
  float along = vertexId >= 2 ? lengthValue + expansion : -expansion;
  float side = (vertexId & 1) == 0 ? -expansion : expansion;
  float2 pixelPosition = p0 + direction * along + normal * side;
  output.position = float4(
      pixelPosition.x * 2.0 / targetSize.x - 1.0,
      1.0 - pixelPosition.y * 2.0 / targetSize.y,
      0.0,
      1.0);
  output.localPosition = float2(along, side);
  output.segmentLength = lengthValue;
  output.radius = radius;
  output.visible = enabled;
  output.color = channelColor[channelIndex];
  return output;
}

float4 pixelMain(VertexOutput input) : SV_TARGET {
  clip(input.visible - 0.5);
  float beyond = max(max(-input.localPosition.x,
                         input.localPosition.x - input.segmentLength), 0.0);
  // 普通线段保持圆帽抗锯齿；零长度实例绘制为与Canvas点一致的方形。
  float distanceToShape = input.segmentLength <= 0.0001
      ? max(abs(input.localPosition.x), abs(input.localPosition.y))
      : length(float2(beyond, input.localPosition.y));
  float coverage = saturate(input.radius + 0.75 - distanceToShape);
  float alpha = input.color.a * coverage;
  return float4(input.color.rgb * alpha, alpha);
}
)";

const EncodableValue* FindValue(const EncodableMap& map, const char* key) {
  const auto iterator = map.find(EncodableValue(key));
  return iterator == map.end() ? nullptr : &iterator->second;
}

int64_t ReadInt(const EncodableMap& map, const char* key, int64_t fallback) {
  const EncodableValue* value = FindValue(map, key);
  if (value == nullptr) return fallback;
  if (const auto* int32_value = std::get_if<int32_t>(value)) {
    return *int32_value;
  }
  if (const auto* int64_value = std::get_if<int64_t>(value)) {
    return *int64_value;
  }
  return fallback;
}

double ReadDouble(const EncodableMap& map, const char* key, double fallback) {
  const EncodableValue* value = FindValue(map, key);
  if (value == nullptr) return fallback;
  if (const auto* double_value = std::get_if<double>(value)) {
    return *double_value;
  }
  if (const auto* int32_value = std::get_if<int32_t>(value)) {
    return static_cast<double>(*int32_value);
  }
  if (const auto* int64_value = std::get_if<int64_t>(value)) {
    return static_cast<double>(*int64_value);
  }
  return fallback;
}

class PlotGpuRendererPlugin final : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<PlotGpuRendererPlugin>(registrar);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit PlotGpuRendererPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar),
        texture_registrar_(registrar->texture_registrar()),
        channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
            registrar->messenger(), kChannelName,
            &flutter::StandardMethodCodec::GetInstance())) {
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) {
          HandleMethodCall(call, std::move(result));
        });
  }

  ~PlotGpuRendererPlugin() override { DisposeTexture(); }

 private:
  struct FrameConstants {
    float target_width;
    float target_height;
    float x_scale;
    float x_offset;
    float y_scale;
    float y_offset;
    float padding_x;
    float padding_y;
    std::array<float, kMaxChannels * 4> channel_geometry;
    std::array<float, kMaxChannels * 4> channel_color;
    std::array<float, kMaxChannels * 4> channel_flags;
  };

  bool Initialize(std::string* error) {
    if (device_ != nullptr) return true;
    ComPtr<IDXGIAdapter> adapter;
    if (!registrar_->GetGraphicsAdapter(adapter.GetAddressOf()) ||
        adapter == nullptr) {
      *error = "无法取得 Flutter 使用的 DXGI 适配器";
      return false;
    }
    constexpr std::array<D3D_FEATURE_LEVEL, 4> feature_levels = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    D3D_FEATURE_LEVEL selected_level;
    const HRESULT device_result = D3D11CreateDevice(
        adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, feature_levels.data(),
        static_cast<UINT>(feature_levels.size()), D3D11_SDK_VERSION,
        device_.GetAddressOf(), &selected_level, context_.GetAddressOf());
    if (FAILED(device_result)) {
      *error = "无法在 Flutter 图形适配器上创建 D3D11 设备";
      return false;
    }
    return CreatePipeline(error);
  }

  bool CreatePipeline(std::string* error) {
    ComPtr<ID3DBlob> vertex_blob;
    ComPtr<ID3DBlob> pixel_blob;
    ComPtr<ID3DBlob> compile_error;
    HRESULT result = D3DCompile(
        kShaderSource, sizeof(kShaderSource), nullptr, nullptr, nullptr,
        "vertexMain", "vs_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0,
        vertex_blob.GetAddressOf(), compile_error.GetAddressOf());
    if (FAILED(result)) {
      *error = "D3D11 顶点着色器编译失败";
      return false;
    }
    compile_error.Reset();
    result = D3DCompile(
        kShaderSource, sizeof(kShaderSource), nullptr, nullptr, nullptr,
        "pixelMain", "ps_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0,
        pixel_blob.GetAddressOf(), compile_error.GetAddressOf());
    if (FAILED(result)) {
      *error = "D3D11 像素着色器编译失败";
      return false;
    }
    if (FAILED(device_->CreateVertexShader(
            vertex_blob->GetBufferPointer(), vertex_blob->GetBufferSize(),
            nullptr, vertex_shader_.GetAddressOf())) ||
        FAILED(device_->CreatePixelShader(
            pixel_blob->GetBufferPointer(), pixel_blob->GetBufferSize(),
            nullptr, pixel_shader_.GetAddressOf()))) {
      *error = "D3D11 着色器创建失败";
      return false;
    }
    const D3D11_INPUT_ELEMENT_DESC elements[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0,
         D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"POSITION", 1, DXGI_FORMAT_R32G32_FLOAT, 0, 8,
         D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"TEXCOORD", 0, DXGI_FORMAT_R32_FLOAT, 0, 16,
         D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"TEXCOORD", 1, DXGI_FORMAT_R32_FLOAT, 0, 20,
         D3D11_INPUT_PER_INSTANCE_DATA, 1},
    };
    if (FAILED(device_->CreateInputLayout(
            elements, static_cast<UINT>(std::size(elements)),
            vertex_blob->GetBufferPointer(), vertex_blob->GetBufferSize(),
            input_layout_.GetAddressOf()))) {
      *error = "D3D11 输入布局创建失败";
      return false;
    }

    D3D11_BUFFER_DESC constants_desc = {};
    constants_desc.ByteWidth = sizeof(FrameConstants);
    constants_desc.Usage = D3D11_USAGE_DYNAMIC;
    constants_desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    constants_desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(device_->CreateBuffer(&constants_desc, nullptr,
                                     constants_.GetAddressOf()))) {
      *error = "D3D11 常量缓冲创建失败";
      return false;
    }

    D3D11_BLEND_DESC blend_desc = {};
    blend_desc.RenderTarget[0].BlendEnable = TRUE;
    blend_desc.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
    blend_desc.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blend_desc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blend_desc.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blend_desc.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    blend_desc.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blend_desc.RenderTarget[0].RenderTargetWriteMask =
        D3D11_COLOR_WRITE_ENABLE_ALL;
    if (FAILED(device_->CreateBlendState(&blend_desc,
                                         blend_state_.GetAddressOf()))) {
      *error = "D3D11 混合状态创建失败";
      return false;
    }

    D3D11_RASTERIZER_DESC rasterizer_desc = {};
    rasterizer_desc.FillMode = D3D11_FILL_SOLID;
    rasterizer_desc.CullMode = D3D11_CULL_NONE;
    rasterizer_desc.ScissorEnable = TRUE;
    rasterizer_desc.DepthClipEnable = TRUE;
    if (FAILED(device_->CreateRasterizerState(
            &rasterizer_desc, rasterizer_state_.GetAddressOf()))) {
      *error = "D3D11 光栅化状态创建失败";
      return false;
    }
    return true;
  }

  bool EnsureTargets(UINT width, UINT height, std::string* error) {
    width = std::max<UINT>(1, width);
    height = std::max<UINT>(1, height);
    if (width == target_width_ && height == target_height_ &&
        targets_[0] != nullptr) {
      return true;
    }
    std::array<ComPtr<ID3D11Texture2D>, 2> targets;
    std::array<ComPtr<ID3D11RenderTargetView>, 2> views;
    std::array<HANDLE, 2> shared_handles = {nullptr, nullptr};
    D3D11_TEXTURE2D_DESC description = {};
    description.Width = width;
    description.Height = height;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = D3D11_BIND_RENDER_TARGET |
                            D3D11_BIND_SHADER_RESOURCE;
    description.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    for (size_t i = 0; i < targets.size(); i++) {
      if (FAILED(device_->CreateTexture2D(&description, nullptr,
                                          targets[i].GetAddressOf())) ||
          FAILED(device_->CreateRenderTargetView(
              targets[i].Get(), nullptr, views[i].GetAddressOf()))) {
        *error = "D3D11 外部纹理创建失败";
        return false;
      }
      ComPtr<IDXGIResource> shared_resource;
      if (FAILED(targets[i].As(&shared_resource)) ||
          FAILED(shared_resource->GetSharedHandle(&shared_handles[i])) ||
          shared_handles[i] == nullptr) {
        *error = "D3D11 纹理共享句柄创建失败";
        return false;
      }
    }
    {
      std::scoped_lock lock(texture_mutex_);
      targets_ = std::move(targets);
      target_views_ = std::move(views);
      shared_handles_ = shared_handles;
      target_width_ = width;
      target_height_ = height;
      front_target_ = 0;
    }
    return true;
  }

  bool EnsureSegmentBuffer(size_t byte_length, std::string* error) {
    if (segment_buffer_ != nullptr && segment_buffer_size_ >= byte_length) {
      return true;
    }
    size_t capacity = std::max<size_t>(4096, segment_buffer_size_);
    while (capacity < byte_length) capacity *= 2;
    D3D11_BUFFER_DESC description = {};
    description.ByteWidth = static_cast<UINT>(capacity);
    description.Usage = D3D11_USAGE_DYNAMIC;
    description.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    description.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    ComPtr<ID3D11Buffer> buffer;
    if (FAILED(device_->CreateBuffer(&description, nullptr,
                                     buffer.GetAddressOf()))) {
      *error = "D3D11 线段缓冲创建失败";
      return false;
    }
    segment_buffer_ = std::move(buffer);
    segment_buffer_size_ = capacity;
    return true;
  }

  bool UploadGeometry(const EncodableMap& arguments, std::string* error) {
    if (!Initialize(error)) return false;
    if (ReadInt(arguments, "clientId", 0) != active_client_id_) {
      *error = "D3D11绘图客户端已失效";
      return false;
    }
    const EncodableValue* primitive_value =
        FindValue(arguments, "primitives");
    const auto* primitives =
        primitive_value == nullptr
            ? nullptr
            : std::get_if<std::vector<float>>(primitive_value);
    if (primitives == nullptr || primitives->size() % 6 != 0) {
      *error = "D3D11 常驻几何数据格式无效";
      return false;
    }
    const size_t byte_length = primitives->size() * sizeof(float);
    if (byte_length > 0 && !EnsureSegmentBuffer(byte_length, error)) {
      return false;
    }
    if (byte_length > 0) {
      D3D11_MAPPED_SUBRESOURCE mapped = {};
      if (FAILED(context_->Map(segment_buffer_.Get(), 0,
                               D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
        *error = "D3D11 常驻几何上传失败";
        return false;
      }
      memcpy(mapped.pData, primitives->data(), byte_length);
      context_->Unmap(segment_buffer_.Get(), 0);
    }
    primitive_count_ = primitives->size() / 6;
    geometry_generation_ = ReadInt(arguments, "generation", 0);
    geometry_upload_count_++;
    return true;
  }

  bool Present(const EncodableMap& arguments, int64_t* frame_id,
               std::string* error) {
    if (!Initialize(error)) return false;
    if (ReadInt(arguments, "clientId", 0) != active_client_id_) {
      *error = "D3D11绘图客户端已失效";
      return false;
    }
    const int64_t requested_generation =
        ReadInt(arguments, "generation", 0);
    if (requested_generation != geometry_generation_) {
      *error = "D3D11 几何代次已失效";
      return false;
    }
    const UINT width = static_cast<UINT>(
        std::max<int64_t>(1, ReadInt(arguments, "width", 1)));
    const UINT height = static_cast<UINT>(
        std::max<int64_t>(1, ReadInt(arguments, "height", 1)));
    if (!EnsureTargets(width, height, error)) return false;
    const EncodableValue* style_value = FindValue(arguments, "styles");
    const auto* styles = style_value == nullptr
                             ? nullptr
                             : std::get_if<std::vector<float>>(style_value);
    if (styles == nullptr || styles->size() != kMaxChannels * 12) {
      *error = "D3D11 通道样式数据格式无效";
      return false;
    }

    D3D11_MAPPED_SUBRESOURCE constants_mapped = {};
    if (FAILED(context_->Map(constants_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0,
                             &constants_mapped))) {
      *error = "D3D11 视口参数上传失败";
      return false;
    }
    auto* frame = static_cast<FrameConstants*>(constants_mapped.pData);
    frame->target_width = static_cast<float>(width);
    frame->target_height = static_cast<float>(height);
    frame->x_scale = static_cast<float>(ReadDouble(arguments, "xScale", 1));
    frame->x_offset = static_cast<float>(ReadDouble(arguments, "xOffset", 0));
    frame->y_scale = static_cast<float>(ReadDouble(arguments, "yScale", 1));
    frame->y_offset = static_cast<float>(ReadDouble(arguments, "yOffset", 0));
    frame->padding_x = 0;
    frame->padding_y = 0;
    std::copy_n(styles->data(), kMaxChannels * 4,
                frame->channel_geometry.data());
    std::copy_n(styles->data() + kMaxChannels * 4, kMaxChannels * 4,
                frame->channel_color.data());
    std::copy_n(styles->data() + kMaxChannels * 8, kMaxChannels * 4,
                frame->channel_flags.data());
    context_->Unmap(constants_.Get(), 0);

    int render_index;
    ComPtr<ID3D11RenderTargetView> target_view;
    {
      std::scoped_lock lock(texture_mutex_);
      render_index = 1 - front_target_;
      target_view = target_views_[render_index];
    }
    constexpr float clear_color[] = {0, 0, 0, 0};
    context_->ClearRenderTargetView(target_view.Get(), clear_color);
    ID3D11RenderTargetView* raw_target = target_view.Get();
    context_->OMSetRenderTargets(1, &raw_target, nullptr);
    const float blend_factor[] = {0, 0, 0, 0};
    context_->OMSetBlendState(blend_state_.Get(), blend_factor, 0xffffffff);
    context_->RSSetState(rasterizer_state_.Get());
    D3D11_VIEWPORT viewport = {0, 0, static_cast<float>(width),
                               static_cast<float>(height), 0, 1};
    context_->RSSetViewports(1, &viewport);
    const LONG left = static_cast<LONG>(
        std::clamp<int64_t>(ReadInt(arguments, "clipLeft", 0), 0, width));
    const LONG top = static_cast<LONG>(
        std::clamp<int64_t>(ReadInt(arguments, "clipTop", 0), 0, height));
    const LONG right = static_cast<LONG>(std::clamp<int64_t>(
        ReadInt(arguments, "clipRight", width), left, width));
    const LONG bottom = static_cast<LONG>(std::clamp<int64_t>(
        ReadInt(arguments, "clipBottom", height), top, height));
    const D3D11_RECT scissor = {left, top, right, bottom};
    context_->RSSetScissorRects(1, &scissor);
    context_->IASetInputLayout(input_layout_.Get());
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
    if (primitive_count_ > 0) {
      const UINT stride = kPrimitiveStride;
      const UINT offset = 0;
      ID3D11Buffer* raw_buffer = segment_buffer_.Get();
      context_->IASetVertexBuffers(0, 1, &raw_buffer, &stride, &offset);
    }
    context_->VSSetShader(vertex_shader_.Get(), nullptr, 0);
    ID3D11Buffer* raw_constants = constants_.Get();
    context_->VSSetConstantBuffers(0, 1, &raw_constants);
    context_->PSSetShader(pixel_shader_.Get(), nullptr, 0);
    if (primitive_count_ > 0) {
      context_->DrawInstanced(4, static_cast<UINT>(primitive_count_), 0, 0);
    }
    context_->Flush();
    {
      std::scoped_lock lock(texture_mutex_);
      front_target_ = render_index;
    }
    if (texture_id_ >= 0) {
      texture_registrar_->MarkTextureFrameAvailable(texture_id_);
    }
    *frame_id = ReadInt(arguments, "frameId", 0);
    present_count_++;
    return true;
  }

  // 仅在显式诊断请求时把当前前台纹理读回CPU。正式绘图路径从不调用，
  // 用于自动验收D3D11输出是否保留走势、尖峰和透明背景。
  bool CaptureFrontTarget(EncodableMap* response, std::string* error) {
    ComPtr<ID3D11Texture2D> source;
    UINT width;
    UINT height;
    {
      std::scoped_lock lock(texture_mutex_);
      source = targets_[front_target_];
      width = target_width_;
      height = target_height_;
    }
    if (source == nullptr || width == 0 || height == 0) {
      *error = "D3D11尚无可读取的绘图帧";
      return false;
    }

    D3D11_TEXTURE2D_DESC description = {};
    source->GetDesc(&description);
    description.Usage = D3D11_USAGE_STAGING;
    description.BindFlags = 0;
    description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    description.MiscFlags = 0;
    ComPtr<ID3D11Texture2D> staging;
    if (FAILED(device_->CreateTexture2D(&description, nullptr,
                                        staging.GetAddressOf()))) {
      *error = "D3D11诊断纹理创建失败";
      return false;
    }
    context_->CopyResource(staging.Get(), source.Get());
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    if (FAILED(context_->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
      *error = "D3D11诊断纹理读取失败";
      return false;
    }
    std::vector<uint8_t> rgba(static_cast<size_t>(width) * height * 4);
    for (UINT y = 0; y < height; y++) {
      const auto* input = static_cast<const uint8_t*>(mapped.pData) +
                          static_cast<size_t>(y) * mapped.RowPitch;
      auto* output = rgba.data() + static_cast<size_t>(y) * width * 4;
      for (UINT x = 0; x < width; x++) {
        output[x * 4] = input[x * 4 + 2];
        output[x * 4 + 1] = input[x * 4 + 1];
        output[x * 4 + 2] = input[x * 4];
        output[x * 4 + 3] = input[x * 4 + 3];
      }
    }
    context_->Unmap(staging.Get(), 0);
    (*response)[EncodableValue("width")] =
        EncodableValue(static_cast<int64_t>(width));
    (*response)[EncodableValue("height")] =
        EncodableValue(static_cast<int64_t>(height));
    (*response)[EncodableValue("pixels")] = EncodableValue(std::move(rgba));
    return true;
  }

  const FlutterDesktopGpuSurfaceDescriptor* ObtainDescriptor(size_t,
                                                               size_t) {
    std::scoped_lock lock(texture_mutex_);
    const HANDLE handle = shared_handles_[front_target_];
    if (handle == nullptr) return nullptr;
    descriptor_ = {};
    descriptor_.struct_size = sizeof(descriptor_);
    descriptor_.handle = handle;
    descriptor_.width = descriptor_.visible_width = target_width_;
    descriptor_.height = descriptor_.visible_height = target_height_;
    descriptor_.format = kFlutterDesktopPixelFormatBGRA8888;
    return &descriptor_;
  }

  bool EnsureTextureRegistered(std::string* error) {
    if (texture_id_ >= 0) return true;
    texture_variant_ = std::make_unique<flutter::TextureVariant>(
        flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
            [this](size_t width, size_t height) {
              return ObtainDescriptor(width, height);
            }));
    texture_id_ = texture_registrar_->RegisterTexture(texture_variant_.get());
    if (texture_id_ < 0) {
      texture_variant_.reset();
      *error = "Flutter 无法注册 D3D11 外部纹理";
      return false;
    }
    return true;
  }

  void DisposeTexture() {
    if (texture_id_ >= 0) {
      texture_registrar_->UnregisterTexture(texture_id_);
      texture_id_ = -1;
    }
    texture_variant_.reset();
  }

  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (call.method_name() == "initialize") {
      const auto* arguments =
          call.arguments() == nullptr
              ? nullptr
              : std::get_if<EncodableMap>(call.arguments());
      std::string error;
      if (!Initialize(&error) || !EnsureTextureRegistered(&error)) {
        result->Error("d3d11_unavailable", error);
        return;
      }
      active_client_id_ =
          arguments == nullptr ? 0 : ReadInt(*arguments, "clientId", 0);
      EncodableMap response;
      response[EncodableValue("textureId")] = EncodableValue(texture_id_);
      response[EncodableValue("backend")] = EncodableValue("D3D11");
      result->Success(EncodableValue(response));
      return;
    }
    if (call.method_name() == "uploadGeometry") {
      const auto* arguments =
          call.arguments() == nullptr
              ? nullptr
              : std::get_if<EncodableMap>(call.arguments());
      if (arguments == nullptr) {
        result->Error("invalid_arguments", "缺少 D3D11 常驻几何参数");
        return;
      }
      std::string error;
      if (!UploadGeometry(*arguments, &error)) {
        result->Error("d3d11_upload_failed", error);
        return;
      }
      result->Success();
      return;
    }
    if (call.method_name() == "present") {
      const auto* arguments =
          call.arguments() == nullptr
              ? nullptr
              : std::get_if<EncodableMap>(call.arguments());
      if (arguments == nullptr) {
        result->Error("invalid_arguments", "缺少 D3D11 呈现参数");
        return;
      }
      std::string error;
      int64_t frame_id = 0;
      if (!EnsureTextureRegistered(&error) ||
          !Present(*arguments, &frame_id, &error)) {
        result->Error("d3d11_present_failed", error);
        return;
      }
      EncodableMap response;
      response[EncodableValue("frameId")] = EncodableValue(frame_id);
      response[EncodableValue("generation")] =
          EncodableValue(geometry_generation_);
      result->Success(EncodableValue(response));
      return;
    }
    if (call.method_name() == "capture") {
      EncodableMap response;
      std::string error;
      if (!CaptureFrontTarget(&response, &error)) {
        result->Error("d3d11_capture_failed", error);
        return;
      }
      result->Success(EncodableValue(response));
      return;
    }
    if (call.method_name() == "stats") {
      EncodableMap response;
      response[EncodableValue("geometryUploadCount")] =
          EncodableValue(geometry_upload_count_);
      response[EncodableValue("presentCount")] =
          EncodableValue(present_count_);
      response[EncodableValue("geometryBytes")] = EncodableValue(
          static_cast<int64_t>(primitive_count_ * kPrimitiveStride));
      response[EncodableValue("generation")] =
          EncodableValue(geometry_generation_);
      result->Success(EncodableValue(response));
      return;
    }
    if (call.method_name() == "dispose") {
      const auto* arguments =
          call.arguments() == nullptr
              ? nullptr
              : std::get_if<EncodableMap>(call.arguments());
      const int64_t client_id =
          arguments == nullptr ? 0 : ReadInt(*arguments, "clientId", 0);
      if (client_id == active_client_id_) {
        DisposeTexture();
        segment_buffer_.Reset();
        segment_buffer_size_ = 0;
        primitive_count_ = 0;
        geometry_generation_ = 0;
        active_client_id_ = 0;
      }
      result->Success();
      return;
    }
    result->NotImplemented();
  }

  flutter::PluginRegistrarWindows* registrar_;
  flutter::TextureRegistrar* texture_registrar_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::unique_ptr<flutter::TextureVariant> texture_variant_;
  int64_t texture_id_ = -1;

  ComPtr<ID3D11Device> device_;
  ComPtr<ID3D11DeviceContext> context_;
  ComPtr<ID3D11VertexShader> vertex_shader_;
  ComPtr<ID3D11PixelShader> pixel_shader_;
  ComPtr<ID3D11InputLayout> input_layout_;
  ComPtr<ID3D11Buffer> constants_;
  ComPtr<ID3D11Buffer> segment_buffer_;
  ComPtr<ID3D11BlendState> blend_state_;
  ComPtr<ID3D11RasterizerState> rasterizer_state_;
  size_t segment_buffer_size_ = 0;
  size_t primitive_count_ = 0;
  int64_t geometry_generation_ = 0;
  int64_t geometry_upload_count_ = 0;
  int64_t present_count_ = 0;
  int64_t active_client_id_ = 0;

  std::mutex texture_mutex_;
  std::array<ComPtr<ID3D11Texture2D>, 2> targets_;
  std::array<ComPtr<ID3D11RenderTargetView>, 2> target_views_;
  std::array<HANDLE, 2> shared_handles_ = {nullptr, nullptr};
  int front_target_ = 0;
  UINT target_width_ = 0;
  UINT target_height_ = 0;
  FlutterDesktopGpuSurfaceDescriptor descriptor_ = {};
};

}  // namespace

void PlotGpuRendererPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  PlotGpuRendererPlugin::RegisterWithRegistrar(windows_registrar);
}
