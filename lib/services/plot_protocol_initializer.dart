import '../core/utils/app_logger.dart';
import '../data/protocol/send_protocol.dart';
import 'data_connection_service.dart';

class PlotProtocolInitializationResult {
  const PlotProtocolInitializationResult._({
    required this.succeeded,
    this.failureMessage,
  });

  const PlotProtocolInitializationResult.success() : this._(succeeded: true);

  const PlotProtocolInitializationResult.failure(String message)
    : this._(succeeded: false, failureMessage: message);

  final bool succeeded;
  final String? failureMessage;
}

/// 绘图启动前协议命令的发送边界。
///
/// ViewModel 提供不可变配置快照；本类负责协议编码、数据连接写入、日志及错误
/// 归一化。通用 [DataConnectionService] 不感知 ZobowDevice 或 r 协议。
class PlotProtocolInitializer {
  PlotProtocolInitializer(this._connectionService);

  final DataConnectionService _connectionService;

  Future<PlotProtocolInitializationResult> initialize<
    TConfig extends SendProtocolInitializationConfig
  >({required SendProtocol<TConfig> protocol, required TConfig config}) async {
    if (!_connectionService.isConnected) {
      final message = '${protocol.initializationName}初始化失败：数据连接未建立，无法发送初始化数据。';
      AppLogger().debug(message, category: 'PLOT');
      return PlotProtocolInitializationResult.failure(message);
    }

    try {
      final bytes = protocol.buildInitializationData(config);
      await _connectionService.send(
        bytes,
        displaySource: SendDisplaySource.plot,
        displayAsHex: protocol.displayAsHex,
      );
      AppLogger().info(
        '${protocol.initializationName}初始化数据已发送: '
        '${protocol.formatForLog(bytes)}',
        category: 'PLOT',
      );
      return const PlotProtocolInitializationResult.success();
    } on FormatException catch (error) {
      final help = protocol.configurationErrorHelp;
      final message =
          '${protocol.initializationName}初始化失败：'
          '${protocol.configurationErrorLabel}，${error.message}。'
          '${help.isEmpty ? '' : help}';
      AppLogger().error(
        '${protocol.initializationName}初始化数据配置错误: $error',
        category: 'PLOT',
      );
      return PlotProtocolInitializationResult.failure(message);
    } on StateError catch (error) {
      final message =
          '${protocol.initializationName}初始化失败：数据连接发送失败，${error.message}。'
          '已停止绘图并断开数据连接，请检查设备连接后重试。';
      AppLogger().error(
        '${protocol.initializationName}初始化数据发送失败: $error',
        category: 'PLOT',
      );
      return PlotProtocolInitializationResult.failure(message);
    } catch (error) {
      final message =
          '${protocol.initializationName}初始化失败：初始化数据发送异常，$error。'
          '已停止绘图，请检查数据连接和通道地址配置。';
      AppLogger().error(
        '${protocol.initializationName}初始化数据发送失败: $error',
        category: 'PLOT',
      );
      return PlotProtocolInitializationResult.failure(message);
    }
  }
}
