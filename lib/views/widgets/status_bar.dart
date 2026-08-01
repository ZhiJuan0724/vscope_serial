import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_strings.dart';
import '../../data/models/parser_config.dart';
import '../../data/models/data_connection_config.dart';
import '../../services/app_settings.dart';
import '../../services/serial_service.dart';
import '../../services/rtt_service.dart';
import '../../viewmodels/plot_viewmodel.dart';
import '../dialogs/app_info_dialog.dart';
import '../dialogs/status_dialog.dart';
import '../dialogs/rtt_connection_dialog.dart';

/// 根据当前页面连接类型生成无歧义的状态文案。
@visibleForTesting
String connectionStatusLabel({
  required bool isProbe,
  required bool connected,
  required bool connecting,
  bool reconnecting = false,
  String? dataConnectionName,
}) {
  final connectionName =
      isProbe
          ? AppStrings.rtt.probe
          : dataConnectionName ?? AppStrings.serial.port;
  final connectionState =
      reconnecting
          ? '重连中...'
          : connected
          ? AppStrings.status.connected
          : connecting
          ? AppStrings.status.connecting
          : AppStrings.status.disconnected;
  return '$connectionName$connectionState';
}

/// 底部共享状态栏
class StatusBar extends StatelessWidget {
  const StatusBar({super.key, this.currentPageId = 'rawData'});

  final String currentPageId;

  @override
  Widget build(BuildContext context) {
    return Consumer2<SerialService, PlotViewModel>(
      builder: (context, service, plotVm, _) {
        if (currentPageId == 'rtt' || currentPageId == 'probePlot') {
          return Consumer<RttService>(
            builder:
                (context, rttService, _) => _buildStatus(
                  context,
                  service,
                  plotVm,
                  rttService: rttService,
                ),
          );
        }
        return _buildStatus(context, service, plotVm);
      },
    );
  }

  Widget _buildStatus(
    BuildContext context,
    SerialService service,
    PlotViewModel plotVm, {
    RttService? rttService,
  }) {
    final isRttPage = rttService != null;
    final connected = isRttPage ? rttService.isConnected : service.isConnected;
    final connecting =
        isRttPage ? rttService.isConnecting : service.isConnecting;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          // 根据当前页面展示串口或探针状态，点击进入对应连接窗口。
          InkWell(
            onTap:
                () =>
                    isRttPage
                        ? showRttConnectionDialog(context)
                        : showSerialConnectionDialog(
                          context,
                          pageId: currentPageId,
                        ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        connected
                            ? Colors.green
                            : connecting
                            ? Colors.orange
                            : Colors.grey,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  connectionStatusLabel(
                    isProbe: isRttPage,
                    connected: connected,
                    connecting: connecting,
                    reconnecting: rttService?.isReconnecting ?? false,
                    dataConnectionName:
                        !isRttPage &&
                                !connected &&
                                !connecting &&
                                AppSettings().networkConnectionsEnabled
                            ? '串口/网络'
                            : service.activeConnectionType.label,
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
                if (isRttPage &&
                    connected &&
                    rttService.activeProbeKind != null) ...[
                  const SizedBox(width: 4),
                  Text(
                    '(${rttService.activeProbeKind!.label})',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (!isRttPage && connected) ...[
                  const SizedBox(width: 4),
                  Text(
                    '(${service.activeConnectionType == DataConnectionType.serial ? service.config.port : service.connectionDescription})',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (!isRttPage &&
                    plotVm.useRandomSource &&
                    plotVm.parserType == ParserType.fireWater) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.auto_graph,
                    size: 13,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    AppStrings.status.randomSource,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
                const SizedBox(width: 4),
                Icon(
                  Icons.edit,
                  size: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          const Spacer(),
          Tooltip(
            message: AppStrings.common.advancedSettings,
            child: IconButton(
              key: const ValueKey('app-advanced-settings-button'),
              onPressed: () => showAppAdvancedSettingsDialog(context),
              icon: const Icon(Icons.tune, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              splashRadius: 14,
            ),
          ),
          Tooltip(
            message: AppStrings.status.appInfo,
            child: IconButton(
              key: const ValueKey('app-info-button'),
              onPressed: () => showAppInfoDialog(context),
              icon: const Icon(Icons.info_outline, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              splashRadius: 14,
            ),
          ),
        ],
      ),
    );
  }
}
