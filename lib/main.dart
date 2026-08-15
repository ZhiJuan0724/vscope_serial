import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/constants/window_configuration.dart';
import 'core/localization/app_strings.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/app_logger.dart';
import 'data/models/probe_connection_config.dart';
import 'data/models/data_connection_config.dart';
import 'data/models/main_page_policy.dart';
import 'data/models/modbus_models.dart';
import 'data/models/ssh_connection_config.dart';
import 'services/app_notifications.dart';
import 'services/app_info.dart';
import 'services/app_settings.dart';
import 'services/bundled_openocd_runtime.dart';
import 'services/connection_owner_service.dart';
import 'services/crash_dump_service.dart';
import 'services/flash_programming_service.dart';
import 'services/modbus_client_service.dart';
import 'services/modbus_window_manager.dart';
import 'services/native_serial_reader.dart';
import 'services/probe_connection_service.dart';
import 'services/ssh_connection_service.dart';
import 'services/data_connection_service.dart';
import 'services/update_checker.dart';
import 'services/update_service.dart';
import 'views/dialogs/app_info_dialog.dart';
import 'views/dialogs/probe_connection_dialog.dart';
import 'views/dialogs/ssh_connection_dialog.dart';
import 'views/dialogs/data_connection_dialog.dart';
import 'views/dialogs/flash_connection_dialog.dart';
import 'viewmodels/plot_viewmodel.dart';
import 'viewmodels/probe_plot_viewmodel.dart';
import 'viewmodels/rtt_viewmodel.dart';
import 'viewmodels/shell_viewmodel.dart';
import 'views/pages/plot_page.dart';
import 'views/pages/modbus_page.dart';
import 'views/pages/modbus_detached_page.dart';
import 'views/pages/flash_programming_page.dart';
import 'views/pages/probe_plot_page.dart';
import 'views/pages/raw_data_page.dart';
import 'views/pages/rtt_page.dart';
import 'views/pages/shell_page.dart';
import 'views/widgets/app_icon.dart';
import 'views/widgets/openocd_runtime_preparation_overlay.dart';
import 'views/widgets/status_bar.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.isNotEmpty && args.first == 'multi_window') {
    final windowId = int.tryParse(args.elementAtOrNull(1) ?? '');
    final payload =
        args.length > 2 && args[2].isNotEmpty
            ? jsonDecode(args[2]) as Map<String, dynamic>
            : const <String, dynamic>{};
    if (windowId == null || payload['business'] != 'modbusPage') return;
    final controller = WindowController.fromWindowId(windowId);
    final windowTitle = '${payload['windowTitle'] ?? 'Modbus页面'}';
    await controller.setFrame(const ui.Rect.fromLTWH(120, 120, 1080, 720));
    await controller.setTitle(windowTitle);
    runApp(
      MaterialApp(
        title: 'Modbus页面',
        theme: AppTheme.buildLightTheme(),
        debugShowCheckedModeBanner: false,
        home: ModbusDetachedPage(
          windowId: windowId,
          pageKey: '${payload['pageKey'] ?? ''}',
        ),
      ),
    );
    await controller.show();
    return;
  }
  Object? serialFfiWarmUpError;
  StackTrace? serialFfiWarmUpStackTrace;
  try {
    // 必须早于日志初始化和串口发现，避免首次连接承担 FFI 延迟初始化。
    NativeSerialReader.warmUpNativeBinding();
  } catch (error, stackTrace) {
    // 预热失败不得阻止应用启动；日志系统就绪后再补记诊断信息。
    serialFfiWarmUpError = error;
    serialFfiWarmUpStackTrace = stackTrace;
  }
  Provider.debugCheckInvalidValueType = null;
  await AppLogger().init();
  if (serialFfiWarmUpError != null) {
    AppLogger().error(
      '串口 FFI 启动预热失败: $serialFfiWarmUpError',
      category: 'SERIAL',
      error: serialFfiWarmUpError,
      stackTrace: serialFfiWarmUpStackTrace,
    );
  }
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    AppLogger().error(
      'Flutter 框架异常: ${details.exceptionAsString()}',
      category: 'APP',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  ui.PlatformDispatcher.instance.onError = (error, stackTrace) {
    AppLogger().error(
      'Flutter 平台异常: $error',
      category: 'APP',
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  };
  await AppSettings().init();
  AppLogger().setDiagnosticEnabled(AppSettings().diagnosticLoggingEnabled);
  try {
    await CrashDumpService().setEnabled(AppSettings().crashDumpEnabled);
  } catch (error, stackTrace) {
    AppLogger().warning('同步原生崩溃转储开关失败: $error\n$stackTrace', category: 'APP');
  }
  DataConnectionService().loadSettings();
  DataConnectionService().initializePortDiscovery();
  await AppIcon.precacheAll();

  // 初始化窗口管理
  await windowManager.ensureInitialized();
  final windowOptions = const WindowOptions(
    size: Size(
      WindowConfiguration.defaultWidth,
      WindowConfiguration.defaultHeight,
    ),
    minimumSize: Size(
      WindowConfiguration.minWidth,
      WindowConfiguration.minHeight,
    ),
    center: true,
    title: AppStrings.appName,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  Widget app = const MyApp();
  if (Platform.isWindows) {
    // 临时规避 Flutter Windows Tooltip 触发的 AXTree 更新错误日志洪泛。
    app = ExcludeSemantics(child: app);
  }
  runApp(app);
}

/// 应用根节点，统一注入全局服务、主题和 Windows 语义兼容配置。
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // DataConnectionService 是全局单例，使用 Provider.value 避免 Provider
    // 在重建时 dispose 单例导致连接被意外断开。
    final connectionService = DataConnectionService();
    final sshService = SshConnectionService();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: ConnectionOwnerService()),
        ChangeNotifierProvider.value(value: connectionService),
        ChangeNotifierProvider.value(value: sshService),
        ChangeNotifierProvider(
          create: (_) {
            final service = ModbusClientService(
              DataConnectionModbusLink(connectionService),
              initialMode: ModbusMode.fromString(AppSettings().modbusMode),
              timeoutMs: AppSettings().modbusTimeoutMs,
              initialLayoutMode: ModbusRegisterLayoutMode.fromValue(
                AppSettings().modbusLayoutMode,
              ),
              initialByteOrder: AppSettings().modbusByteOrder,
              initialWordOrder: AppSettings().modbusWordOrder,
              initialLogMaxLines: AppSettings().modbusLogMaxLines,
              initialPages: AppSettings().modbusPages,
              onPagesChanged: (pages) {
                AppSettings().modbusPages = List.of(pages);
                unawaited(AppSettings().save());
              },
              onLayoutModeChanged: (value) {
                AppSettings().modbusLayoutMode = value.value;
                unawaited(AppSettings().save());
              },
              onModeChanged: (value) {
                AppSettings().modbusMode = value.value;
                unawaited(AppSettings().save());
              },
              onTimeoutChanged: (value) {
                AppSettings().modbusTimeoutMs = value;
                unawaited(AppSettings().save());
              },
              onByteOrderChanged: (value) {
                AppSettings().modbusByteOrder = value;
                unawaited(AppSettings().save());
              },
              onWordOrderChanged: (value) {
                AppSettings().modbusWordOrder = value;
                unawaited(AppSettings().save());
              },
              onLogMaxLinesChanged: (value) {
                AppSettings().modbusLogMaxLines = value;
                unawaited(AppSettings().save());
              },
              onSelectedProfileChanged: (value) {
                AppSettings().modbusProfileId = value;
                unawaited(AppSettings().save());
              },
            );
            unawaited(
              service
                  .initializeProfiles(
                    selectedProfileId: AppSettings().modbusProfileId,
                  )
                  .catchError((Object error, StackTrace stackTrace) {
                    AppLogger().error(
                      '初始化Modbus配置库失败: $error',
                      category: 'MODBUS',
                      error: error,
                      stackTrace: stackTrace,
                    );
                  }),
            );
            return service;
          },
        ),
        ChangeNotifierProvider(
          create:
              (context) =>
                  ModbusWindowManager(context.read<ModbusClientService>()),
        ),
        ChangeNotifierProvider.value(value: BundledOpenOcdRuntime()),
        ChangeNotifierProvider(create: (_) => FlashProgrammingService()),
        ChangeNotifierProvider(create: (_) => ProbeConnectionService()),
        ChangeNotifierProvider(
          create: (context) => PlotViewModel(connectionService),
        ),
        ChangeNotifierProvider(
          create: (context) => ShellViewModel(connectionService, sshService),
        ),
        ChangeNotifierProvider(
          create:
              (context) => RttViewModel(context.read<ProbeConnectionService>()),
        ),
        ChangeNotifierProvider(
          create:
              (context) =>
                  ProbePlotViewModel(context.read<ProbeConnectionService>()),
        ),
      ],
      child: MaterialApp(
        title: AppStrings.appName,
        scaffoldMessengerKey: AppNotifications.scaffoldMessengerKey,
        theme: AppTheme.buildLightTheme(),
        home: const MainFrame(),
        builder:
            (context, child) => Stack(
              children: [
                if (child != null) child,
                const OpenOcdRuntimePreparationOverlay(),
              ],
            ),
      ),
    );
  }
}

/// 主页面标签容器，负责恢复上次页面并遵守串口与 RTT 活动锁。
class MainFrame extends StatefulWidget {
  const MainFrame({super.key});

  @override
  State<MainFrame> createState() => _MainFrameState();
}

class _MainFrameState extends State<MainFrame> with WidgetsBindingObserver {
  String _currentTabId = 'rawData';
  final ScrollController _tabScrollController = ScrollController();
  final LayerLink _addPageMenuLink = LayerLink();
  OverlayEntry? _tabMenuOverlay;
  _WindowCloseListener? _windowCloseListener;
  bool _connectionShortcutBusy = false;

  @override
  void initState() {
    super.initState();
    final savedPage = AppSettings().lastMainPage;
    final settings = AppSettings();
    _currentTabId =
        settings.visibleMainPages.contains(savedPage)
            ? savedPage
            : settings.visibleMainPages.first;
    WidgetsBinding.instance.addObserver(this);
    // 注册窗口关闭处理：关闭前收敛数据连接与探针连接。
    _setupWindowCloseHandler();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_handleStartupNotices());
    });
  }

  Future<void> _handleStartupNotices() async {
    final recoveryNotice = AppSettings().takeRecoveryNotice();
    if (recoveryNotice != null) AppNotifications.show(recoveryNotice);
    await _showPendingCrashDumpNotice();
    if (mounted) await _handleStartupUpdates();
  }

  Future<void> _showPendingCrashDumpNotice() async {
    final service = CrashDumpService();
    List<CrashDumpRecord> records;
    try {
      records = await service.pendingRecords();
    } catch (error, stackTrace) {
      AppLogger().warning('读取原生崩溃转储记录失败: $error\n$stackTrace', category: 'APP');
      return;
    }
    if (!mounted || records.isEmpty) return;

    final latest = records.first;
    final localTime = latest.timestampUtc?.toLocal();
    final timeText =
        localTime == null ? AppStrings.appInfo.unknown : localTime.toString();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (dialogContext) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(AppStrings.appInfo.crashDumpDetectedTitle),
            content: SelectableText(
              AppStrings.appInfo.crashDumpDetectedMessage(
                records.length,
                timeText,
                latest.exceptionCode ?? AppStrings.appInfo.unknown,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(
                  MaterialLocalizations.of(dialogContext).closeButtonLabel,
                ),
              ),
              FilledButton.icon(
                onPressed: () async {
                  try {
                    await service.openCrashDumpDirectory();
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  } catch (error, stackTrace) {
                    AppLogger().error(
                      '打开原生崩溃转储目录失败: $error',
                      category: 'APP',
                      error: error,
                      stackTrace: stackTrace,
                    );
                    AppNotifications.show('无法打开崩溃转储目录，请检查程序目录权限');
                  }
                },
                icon: const Icon(Icons.folder_open),
                label: Text(AppStrings.appInfo.openCrashDumpDirectory),
              ),
            ],
          ),
    );
    try {
      await service.markReported(records);
    } catch (error, stackTrace) {
      AppLogger().warning('标记原生崩溃转储记录失败: $error\n$stackTrace', category: 'APP');
    }
  }

  Future<void> _handleStartupUpdates() async {
    final service = UpdateService();
    final channel = UpdateChannel.fromString(AppSettings().updateChannel);
    final sourcePreference = UpdateSourcePreference.fromString(
      AppSettings().updateSource,
    );
    final message = await service.consumeLastResult();
    if (message != null && mounted) AppNotifications.show(message);
    final prepared = await service.findLatestPreparedUpdate(
      newerThanVersion: await AppInfo.version(),
      channel: channel,
    );
    if (prepared != null && mounted) {
      await showUpdateAvailableDialog(
        context,
        prepared.release,
        sourcePreference: sourcePreference,
      );
    } else if (AppSettings().autoUpdateCheckEnabled) {
      await _checkForUpdatesOnStartup();
    }
    await service.cleanupOldUpdates();
  }

  void _setupWindowCloseHandler() {
    windowManager.setPreventClose(true);
    final listener = _WindowCloseListener(context);
    _windowCloseListener = listener;
    windowManager.addListener(listener);
  }

  Future<void> _checkForUpdatesOnStartup() async {
    final result = await UpdateChecker().check(
      channel: UpdateChannel.fromString(AppSettings().updateChannel),
      source:
          UpdateSourcePreference.fromString(
            AppSettings().updateSource,
          ).releaseSource,
    );
    if (!mounted) return;
    if (result.hasUpdate && result.latestRelease != null) {
      await showUpdateAvailableDialog(
        context,
        result.latestRelease!,
        sourcePreference: UpdateSourcePreference.fromString(
          AppSettings().updateSource,
        ),
      );
    } else if (result.error != null) {
      AppLogger().warning('自动检查更新失败: ${result.error}', category: 'UPDATE');
    }
  }

  @override
  void dispose() {
    _hideTabMenu();
    final listener = _windowCloseListener;
    if (listener != null) windowManager.removeListener(listener);
    _tabScrollController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _hideTabMenu() {
    _tabMenuOverlay?.remove();
    _tabMenuOverlay = null;
  }

  void _showTabContextMenu(Offset position, String tabId) {
    _hideTabMenu();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final capturedThemes = InheritedTheme.capture(
      from: context,
      to: overlay.context,
    );
    final screen = MediaQuery.sizeOf(context);
    const width = 132.0;
    const height = 38.0;
    final left = position.dx.clamp(4.0, screen.width - width - 4.0);
    final top = position.dy.clamp(4.0, screen.height - height - 4.0);
    _tabMenuOverlay = OverlayEntry(
      builder:
          (overlayContext) => capturedThemes.wrap(
            Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _hideTabMenu,
                    onSecondaryTap: _hideTabMenu,
                  ),
                ),
                Positioned(
                  left: left,
                  top: top,
                  width: width,
                  child: _FastTabMenu(
                    items: [
                      _FastTabMenuItemData(
                        icon: Icons.close,
                        label: '关闭页面',
                        onTap: () {
                          _hideTabMenu();
                          _closeTab(tabId);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
    );
    overlay.insert(_tabMenuOverlay!);
  }

  void _toggleAddPageMenu() {
    if (_tabMenuOverlay != null) {
      _hideTabMenu();
      return;
    }
    final missing = [
      for (final entry in _pageCatalog.entries)
        if (!AppSettings().visibleMainPages.contains(entry.key)) entry,
    ];
    if (missing.isEmpty) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final capturedThemes = InheritedTheme.capture(
      from: context,
      to: overlay.context,
    );
    _tabMenuOverlay = OverlayEntry(
      builder:
          (overlayContext) => capturedThemes.wrap(
            Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _hideTabMenu,
                    onSecondaryTap: _hideTabMenu,
                  ),
                ),
                CompositedTransformFollower(
                  link: _addPageMenuLink,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.bottomRight,
                  followerAnchor: Alignment.topRight,
                  offset: const Offset(0, 2),
                  child: SizedBox(
                    width: 170,
                    child: _FastTabMenu(
                      items: [
                        for (final entry in missing)
                          _FastTabMenuItemData(
                            icon: entry.value.icon,
                            label: entry.value.label,
                            onTap: () {
                              _hideTabMenu();
                              _addTab(entry.key);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
    );
    overlay.insert(_tabMenuOverlay!);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      AppLogger().disposeLogger();
    }
  }

  List<({String id, String label, IconData icon, Widget page})> get _tabs {
    final available =
        <String, ({String id, String label, IconData icon, Widget page})>{
          'rawData': (
            id: 'rawData',
            label: AppStrings.nav.rawData,
            icon: Icons.data_object,
            page: const RawDataPage(),
          ),
          'shell': (
            id: 'shell',
            label: AppStrings.nav.shell,
            icon: Icons.terminal,
            page: ShellPage(onConnectionShortcut: _handleConnectionShortcut),
          ),
          'plot': (
            id: 'plot',
            label: AppStrings.nav.plot,
            icon: Icons.show_chart,
            page: const PlotPage(),
          ),
          'rtt': (
            id: 'rtt',
            label: AppStrings.nav.rtt,
            icon: Icons.developer_board,
            page: const RttPage(),
          ),
          'probePlot': (
            id: 'probePlot',
            label: '探针绘图',
            icon: Icons.monitor_heart_outlined,
            page: const ProbePlotPage(),
          ),
          'modbus': (
            id: 'modbus',
            label: 'Modbus',
            icon: Icons.swap_horiz,
            page: const ModbusPage(),
          ),
          'flash': (
            id: 'flash',
            label: 'Flash',
            icon: Icons.memory,
            page: const FlashProgrammingPage(),
          ),
        };
    return [
      for (final id in AppSettings().mainTabOrder)
        if (AppSettings().visibleMainPages.contains(id))
          if (available[id] case final tab?) tab,
    ];
  }

  Map<String, ({String label, IconData icon})> get _pageCatalog => {
    'rawData': (label: AppStrings.nav.rawData, icon: Icons.data_object),
    'shell': (label: AppStrings.nav.shell, icon: Icons.terminal),
    'plot': (label: AppStrings.nav.plot, icon: Icons.show_chart),
    'rtt': (label: AppStrings.nav.rtt, icon: Icons.developer_board),
    'probePlot': (label: '探针绘图', icon: Icons.monitor_heart_outlined),
    'modbus': (label: 'Modbus', icon: Icons.swap_horiz),
    'flash': (label: 'Flash', icon: Icons.memory),
  };

  void _persistVisiblePages(List<String> pages) {
    final settings = AppSettings();
    final pageSet = pages.toSet();
    final visibleOrder = [
      for (final id in settings.mainTabOrder)
        if (pageSet.contains(id)) id,
      for (final id in pages)
        if (!settings.mainTabOrder.contains(id)) id,
    ];
    settings
      ..visibleMainPages = visibleOrder
      ..mainTabOrder = visibleOrder;
    unawaited(settings.save());
  }

  void _addTab(String id) {
    final settings = AppSettings();
    final current = settings.visibleMainPages;
    final next = MainPagePolicy.addPage(current, id);
    if (identical(current, next)) return;
    // 用户重新添加的页面始终出现在当前标签末尾；
    // 之后仍可拖动调整，拖动结果继续持久化。
    settings.mainTabOrder = MainPagePolicy.appendPageOrder(
      settings.mainTabOrder,
      id,
    );
    _persistVisiblePages(next);
    setState(() {});
  }

  bool _pagesLocked(
    DataConnectionService connectionService,
    ProbeConnectionService probeConnectionService,
    ConnectionOwnerService owners, [
    SshConnectionService? sshService,
  ]) =>
      owners.owner != ConnectionOwner.none ||
      connectionService.isConnecting ||
      (sshService?.isConnecting ?? false) ||
      probeConnectionService.isConnecting ||
      probeConnectionService.isReconnecting;

  void _closeTab(String id) {
    final pages = AppSettings().visibleMainPages;
    if (pages.length <= 1) {
      AppNotifications.show('至少保留一个页面');
      return;
    }
    final displayedPages = _tabs.map((tab) => tab.id).toList();
    final index = displayedPages.indexOf(id);
    final next = MainPagePolicy.closePage(pages, id, connectionBusy: false);
    final nextDisplayed = displayedPages.where((page) => page != id).toList();
    if (_currentTabId == id) {
      _currentTabId = nextDisplayed[index.clamp(0, nextDisplayed.length - 1)];
      AppSettings().lastMainPage = _currentTabId;
    }
    _persistVisiblePages(next);
    setState(() {});
  }

  bool _tabSupportsConnection(String tabId, DataConnectionService service) {
    return MainPagePolicy.supportsDataConnection(
      tabId,
      service.activeConnectionType,
    );
  }

  void _reorderTabs(int oldIndex, int newIndex) {
    final visibleTabs = _tabs;
    if (oldIndex == newIndex) return;
    final reorderedVisibleIds = visibleTabs.map((tab) => tab.id).toList();
    final movedId = reorderedVisibleIds.removeAt(oldIndex);
    reorderedVisibleIds.insert(newIndex, movedId);
    setState(() {
      AppSettings()
        ..mainTabOrder = reorderedVisibleIds
        ..visibleMainPages = reorderedVisibleIds;
    });
    unawaited(AppSettings().save());
  }

  void _ensureSelectedTabVisible(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tabScrollController.hasClients) return;
      const tabWidth = 180.0;
      final position = _tabScrollController.position;
      final left = index * tabWidth;
      final right = left + tabWidth;
      var target = position.pixels;
      if (left < target) {
        target = left;
      } else if (right > target + position.viewportDimension) {
        target = right - position.viewportDimension;
      }
      target = target.clamp(0.0, position.maxScrollExtent);
      if ((target - position.pixels).abs() > 0.5) {
        _tabScrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _selectTab(String id) {
    if (id == _currentTabId) return;
    setState(() {
      _currentTabId = id;
    });
    final settings = AppSettings();
    settings.lastMainPage = id;
    if (id == 'rawData' || id == 'shell' || id == 'plot' || id == 'modbus') {
      DataConnectionService().selectSerialProfile(id);
    }
    unawaited(settings.save());
  }

  void _handleTabPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_tabScrollController.hasClients) {
      return;
    }
    final position = _tabScrollController.position;
    // 普通鼠标滚轮通常只提供垂直增量；在标签栏中将其转换为横向滚动。
    final delta =
        event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
            ? event.scrollDelta.dx
            : event.scrollDelta.dy;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() > 0.5) {
      _tabScrollController.jumpTo(target);
    }
  }

  bool get _usesProbeConnection =>
      _currentTabId == 'rtt' || _currentTabId == 'probePlot';

  bool get _usesSshConnection =>
      _currentTabId == 'shell' &&
      ShellConnectionMode.fromString(AppSettings().shellConnectionMode) ==
          ShellConnectionMode.ssh;

  bool get _usesFlashProgramming => _currentTabId == 'flash';

  void _handleConnectionShortcut(LogicalKeyboardKey key) {
    if (!AppSettings().connectionShortcutsEnabled) return;
    if (key == LogicalKeyboardKey.f1) {
      unawaited(
        _usesProbeConnection
            ? showProbeConnectionDialog(context)
            : _usesFlashProgramming
            ? showFlashConnectionDialog(context)
            : _usesSshConnection
            ? showSshConnectionDialog(context)
            : showDataConnectionDialog(context, pageId: _currentTabId),
      );
      return;
    }
    if (_connectionShortcutBusy) {
      AppNotifications.show('连接快捷键操作正在进行');
      return;
    }
    unawaited(_runConnectionShortcut(key));
  }

  Future<void> _runConnectionShortcut(LogicalKeyboardKey key) async {
    _connectionShortcutBusy = true;
    try {
      if (_usesProbeConnection) {
        await _runProbeConnectionShortcut(key);
      } else if (_usesFlashProgramming) {
        await _runFlashConnectionShortcut(key);
      } else if (_usesSshConnection) {
        await _runSshConnectionShortcut(key);
      } else {
        await _runSerialConnectionShortcut(key);
      }
    } catch (error) {
      final action = switch (key) {
        LogicalKeyboardKey.f2 => '快捷连接',
        LogicalKeyboardKey.f3 => '快捷断开',
        _ => '快捷重连',
      };
      AppNotifications.show('$action失败：$error');
    } finally {
      _connectionShortcutBusy = false;
    }
  }

  Future<void> _runSerialConnectionShortcut(LogicalKeyboardKey key) async {
    final service = context.read<DataConnectionService>();
    service.selectSerialProfile(_currentTabId);
    final settings = AppSettings();
    final type = settings.connectionTypeForPage(_currentTabId);
    if (key == LogicalKeyboardKey.f2) {
      if (service.isConnected) {
        AppNotifications.show('快捷连接：${service.activeConnectionType.label}已连接');
        return;
      }
      if (type == DataConnectionType.serial &&
          !service.canConnectSelectedPort) {
        AppNotifications.show('快捷连接：请选择当前可用的串口');
        return;
      }
      AppNotifications.show('快捷连接：正在连接${type.label}');
      if (type == DataConnectionType.serial) {
        await service.connect();
      } else {
        await service.connectNetwork(
          settings.networkConfigForPage(_currentTabId).copyWith(type: type),
          pageId: _currentTabId,
        );
      }
      return;
    }
    if (key == LogicalKeyboardKey.f3) {
      if (!service.isConnected && !service.isConnecting) {
        AppNotifications.show('快捷断开：串口当前未连接');
        return;
      }
      AppNotifications.show('快捷断开：正在断开连接');
      if (_currentTabId == 'modbus') {
        await context.read<ModbusClientService>().stop();
      }
      await service.disconnect();
      return;
    }
    if (!service.isConnected && !service.isConnecting) {
      AppNotifications.show('快捷重连：当前未连接，正在连接${type.label}');
      if (type == DataConnectionType.serial) {
        if (!service.canConnectSelectedPort) {
          throw StateError('请选择当前可用的串口');
        }
        await service.connect();
      } else {
        await service.connectNetwork(
          settings.networkConfigForPage(_currentTabId).copyWith(type: type),
          pageId: _currentTabId,
        );
      }
      return;
    }
    final reconnectType = service.activeConnectionType;
    final reconnectNetwork = service.activeNetworkConfig;
    final reconnectPage = service.activeConnectionPage ?? _currentTabId;
    AppNotifications.show('快捷重连：正在断开并重新连接');
    if (_currentTabId == 'modbus') {
      await context.read<ModbusClientService>().stop();
    }
    await service.disconnect();
    if (reconnectType == DataConnectionType.serial &&
        !service.canConnectSelectedPort) {
      throw StateError('请选择当前可用的串口');
    }
    if (reconnectType == DataConnectionType.serial) {
      await service.connect();
    } else if (reconnectNetwork != null) {
      await service.connectNetwork(reconnectNetwork, pageId: reconnectPage);
    }
  }

  Future<void> _runProbeConnectionShortcut(LogicalKeyboardKey key) async {
    final service = context.read<ProbeConnectionService>();
    if (key == LogicalKeyboardKey.f2) {
      if (service.isConnected) {
        AppNotifications.show('快捷连接：探针已连接');
        return;
      }
      AppNotifications.show('快捷连接：正在连接探针');
      await service.connect(savedProbeConnectionConfig());
      return;
    }
    if (key == LogicalKeyboardKey.f3) {
      if (!service.isConnected && !service.isConnecting) {
        AppNotifications.show('快捷断开：探针当前未连接');
        return;
      }
      AppNotifications.show('快捷断开：正在断开探针');
      await service.disconnect();
      return;
    }
    AppNotifications.show('快捷重连：正在断开并重新连接探针');
    await service.disconnect();
    await service.connect(savedProbeConnectionConfig());
  }

  Future<void> _runFlashConnectionShortcut(LogicalKeyboardKey key) async {
    final service = context.read<FlashProgrammingService>();
    if (key == LogicalKeyboardKey.f2) {
      if (service.isConnected) {
        AppNotifications.show('快捷连接：Flash编程会话已连接');
      } else {
        AppNotifications.show('快捷连接：请确认Flash高权限连接配置');
        await showFlashConnectionDialog(context);
      }
      return;
    }
    if (key == LogicalKeyboardKey.f3) {
      if (!service.hasSession) {
        AppNotifications.show('快捷断开：Flash编程会话未连接');
        return;
      }
      if (service.isBusy) throw StateError('Flash操作期间不能普通断开');
      AppNotifications.show('快捷断开：正在断开Flash编程会话');
      await service.disconnect();
      return;
    }
    AppNotifications.show('Flash高权限会话请通过连接窗口确认后显式连接');
  }

  Future<void> _runSshConnectionShortcut(LogicalKeyboardKey key) async {
    final service = context.read<SshConnectionService>();
    if (key == LogicalKeyboardKey.f2) {
      if (service.isConnected) {
        AppNotifications.show('快捷连接：SSH 已连接');
      } else {
        AppNotifications.show('快捷连接：请填写本次 SSH 凭据');
        await showSshConnectionDialog(context);
      }
      return;
    }
    if (key == LogicalKeyboardKey.f3) {
      if (!service.isConnected && !service.isConnecting) {
        AppNotifications.show('快捷断开：SSH 当前未连接');
        return;
      }
      AppNotifications.show('快捷断开：正在断开 SSH');
      await service.disconnect();
      return;
    }
    if (!service.isConnected) {
      AppNotifications.show('快捷重连：请填写本次 SSH 凭据');
      await showSshConnectionDialog(context);
      return;
    }
    AppNotifications.show('快捷重连：正在重新连接 SSH');
    await service.reconnect();
  }

  @override
  Widget build(BuildContext context) {
    final connectionService = Provider.of<DataConnectionService>(context);
    final connectionOwner = Provider.of<ConnectionOwnerService>(context);
    // 探针连接和活动变化会直接影响两个探针页面的切换权限。
    final probeConnectionService = Provider.of<ProbeConnectionService>(context);
    final sshConnectionService = Provider.of<SshConnectionService>(context);
    final tabs = _tabs;
    if (!tabs.any((tab) => tab.id == _currentTabId)) {
      _currentTabId = tabs.first.id;
    }
    final currentIndex = tabs.indexWhere((tab) => tab.id == _currentTabId);
    _ensureSelectedTabVisible(currentIndex);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f1):
            () => _handleConnectionShortcut(LogicalKeyboardKey.f1),
        const SingleActivator(LogicalKeyboardKey.f2):
            () => _handleConnectionShortcut(LogicalKeyboardKey.f2),
        const SingleActivator(LogicalKeyboardKey.f3):
            () => _handleConnectionShortcut(LogicalKeyboardKey.f3),
        const SingleActivator(LogicalKeyboardKey.f5):
            () => _handleConnectionShortcut(LogicalKeyboardKey.f5),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              // 顶部 Tab 切换栏
              ClipRect(
                child: Container(
                  height: 40,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Row(
                      children: [
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final showAddButton =
                                  tabs.length < _pageCatalog.length;
                              const addButtonWidth = 50.0;
                              final maxTabStripWidth = (constraints.maxWidth -
                                      (showAddButton ? addButtonWidth : 0))
                                  .clamp(0.0, double.infinity);
                              final tabStripWidth =
                                  (tabs.length * 180.0)
                                      .clamp(0.0, maxTabStripWidth)
                                      .toDouble();
                              return Row(
                                children: [
                                  SizedBox(
                                    width: tabStripWidth,
                                    child: Listener(
                                      onPointerSignal: _handleTabPointerSignal,
                                      child: ReorderableListView.builder(
                                        scrollController: _tabScrollController,
                                        scrollDirection: Axis.horizontal,
                                        buildDefaultDragHandles: false,
                                        onReorderItem: _reorderTabs,
                                        itemCount: tabs.length,
                                        itemBuilder: (context, index) {
                                          final tab = tabs[index];
                                          final isSelected =
                                              index == currentIndex;
                                          final ownerTab =
                                              switch (connectionService
                                                  .activityOwner) {
                                                DataActivityOwner.rawData =>
                                                  'rawData',
                                                DataActivityOwner.shell =>
                                                  'shell',
                                                DataActivityOwner.plot =>
                                                  'plot',
                                                DataActivityOwner.modbus =>
                                                  'modbus',
                                                DataActivityOwner.none => null,
                                              };
                                          final canSwitch = switch (connectionOwner
                                              .owner) {
                                            ConnectionOwner.probe =>
                                              switch (probeConnectionService
                                                  .activityOwner) {
                                                ProbeActivityOwner.rttViewer =>
                                                  tab.id == 'rtt',
                                                ProbeActivityOwner.probePlot =>
                                                  tab.id == 'probePlot',
                                                ProbeActivityOwner.none =>
                                                  tab.id == 'rtt' ||
                                                      tab.id == 'probePlot',
                                              },
                                            ConnectionOwner.data =>
                                              sshConnectionService
                                                          .isConnected ||
                                                      sshConnectionService
                                                          .isConnecting
                                                  ? tab.id == 'shell'
                                                  : ownerTab != null
                                                  ? tab.id == ownerTab
                                                  : _tabSupportsConnection(
                                                    tab.id,
                                                    connectionService,
                                                  ),
                                            ConnectionOwner.programming =>
                                              tab.id == 'flash',
                                            ConnectionOwner.none =>
                                              !connectionService.isConnecting ||
                                                  tab.id ==
                                                      connectionService
                                                          .activeConnectionPage,
                                          };
                                          final closeLocked = _pagesLocked(
                                            connectionService,
                                            probeConnectionService,
                                            connectionOwner,
                                            sshConnectionService,
                                          );
                                          final colorScheme =
                                              Theme.of(context).colorScheme;
                                          final foreground =
                                              isSelected
                                                  ? colorScheme.primary
                                                  : canSwitch
                                                  ? colorScheme.onSurfaceVariant
                                                  : colorScheme.onSurfaceVariant
                                                      .withValues(alpha: 0.3);
                                          return ReorderableDelayedDragStartListener(
                                            key: ValueKey(tab.id),
                                            index: index,
                                            child: SizedBox(
                                              width: 180,
                                              height: 35,
                                              child: Material(
                                                // Material 默认会在形状变化时做插值动画，
                                                // 会使新选中页签短暂以矩形闪现。所有
                                                // 页签固定使用同一轮廓，只即时切换颜色。
                                                animationDuration:
                                                    Duration.zero,
                                                color:
                                                    isSelected
                                                        ? Theme.of(
                                                          context,
                                                        ).scaffoldBackgroundColor
                                                        : colorScheme.onSurface
                                                            .withValues(
                                                              alpha: 0.035,
                                                            ),
                                                surfaceTintColor:
                                                    Colors.transparent,
                                                shape:
                                                    const _SelectedTabShape(),
                                                clipBehavior: Clip.antiAlias,
                                                child: InkWell(
                                                  customBorder:
                                                      const _SelectedTabShape(),
                                                  onTap:
                                                      canSwitch
                                                          ? () =>
                                                              _selectTab(tab.id)
                                                          : null,
                                                  onSecondaryTapDown: (
                                                    details,
                                                  ) {
                                                    if (closeLocked) {
                                                      AppNotifications.show(
                                                        '连接期间不能关闭页面',
                                                      );
                                                      return;
                                                    }
                                                    _showTabContextMenu(
                                                      details.globalPosition,
                                                      tab.id,
                                                    );
                                                  },
                                                  child: Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Icon(
                                                        tab.icon,
                                                        size: 16,
                                                        color: foreground,
                                                      ),
                                                      const SizedBox(width: 6),
                                                      Text(
                                                        tab.label,
                                                        style: TextStyle(
                                                          fontSize: 13,
                                                          fontWeight:
                                                              isSelected
                                                                  ? FontWeight
                                                                      .bold
                                                                  : FontWeight
                                                                      .normal,
                                                          color: foreground,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  if (showAddButton)
                                    CompositedTransformTarget(
                                      link: _addPageMenuLink,
                                      child: _TabAddButton(
                                        key: const ValueKey(
                                          'add-main-page-button',
                                        ),
                                        onTap: _toggleAddPageMenu,
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 页面内容
              Expanded(
                child: IndexedStack(
                  index: currentIndex,
                  children: tabs.map((tab) => tab.page).toList(),
                ),
              ),
              // 底部共享状态栏
              StatusBar(currentPageId: _currentTabId),
            ],
          ),
        ),
      ),
    );
  }
}

class _FastTabMenuItemData {
  const _FastTabMenuItemData({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// 标签栏专用即时菜单：无过渡动画，并使用轻量边框和极小阴影。
class _FastTabMenu extends StatelessWidget {
  const _FastTabMenu({required this.items});

  final List<_FastTabMenuItemData> items;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 2.5,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Material(
          color: Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items)
                InkWell(
                  onTap: item.onTap,
                  hoverColor: colors.primary.withValues(alpha: 0.08),
                  child: SizedBox(
                    height: 34,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          Icon(
                            item.icon,
                            size: 15,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item.label,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: colors.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabAddButton extends StatefulWidget {
  const _TabAddButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  State<_TabAddButton> createState() => _TabAddButtonState();
}

class _TabAddButtonState extends State<_TabAddButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: '添加页面',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) {
          if (_hovered) setState(() => _hovered = false);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            width: 50,
            height: 35,
            child: Row(
              children: [
                Container(
                  key: const ValueKey('add-main-page-divider'),
                  width: 1,
                  height: 20,
                  color: colors.outlineVariant,
                ),
                const SizedBox(width: 8),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        _hovered
                            ? colors.primary.withValues(alpha: 0.10)
                            : colors.onSurface.withValues(alpha: 0.06),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.add,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Chrome 风格选中标签：顶部圆角，底部两侧向外展开并衔接内容区。
class _SelectedTabShape extends ShapeBorder {
  const _SelectedTabShape();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return getOuterPath(rect, textDirection: textDirection);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    const topRadius = 7.0;
    const bodyInset = 10.0;
    const shoulderHeight = 8.0;
    return Path()
      ..moveTo(rect.left, rect.bottom)
      ..cubicTo(
        rect.left + bodyInset * 0.55,
        rect.bottom,
        rect.left + bodyInset,
        rect.bottom - shoulderHeight * 0.45,
        rect.left + bodyInset,
        rect.bottom - shoulderHeight,
      )
      ..lineTo(rect.left + bodyInset, rect.top + topRadius)
      ..quadraticBezierTo(
        rect.left + bodyInset,
        rect.top,
        rect.left + bodyInset + topRadius,
        rect.top,
      )
      ..lineTo(rect.right - bodyInset - topRadius, rect.top)
      ..quadraticBezierTo(
        rect.right - bodyInset,
        rect.top,
        rect.right - bodyInset,
        rect.top + topRadius,
      )
      ..lineTo(rect.right - bodyInset, rect.bottom - shoulderHeight)
      ..cubicTo(
        rect.right - bodyInset,
        rect.bottom - shoulderHeight * 0.45,
        rect.right - bodyInset * 0.55,
        rect.bottom,
        rect.right,
        rect.bottom,
      )
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// 窗口关闭监听器：允许窗口关闭前先收敛全部连接。
class _WindowCloseListener extends WindowListener {
  final BuildContext context;
  bool _isClosing = false;

  _WindowCloseListener(this.context);

  @override
  void onWindowClose() async {
    if (_isClosing) return;
    _isClosing = true;
    final connectionService = Provider.of<DataConnectionService>(
      context,
      listen: false,
    );
    final probeConnectionService = Provider.of<ProbeConnectionService>(
      context,
      listen: false,
    );
    final sshConnectionService = Provider.of<SshConnectionService>(
      context,
      listen: false,
    );
    final flashProgrammingService = Provider.of<FlashProgrammingService>(
      context,
      listen: false,
    );
    if (flashProgrammingService.isBusy) {
      AppNotifications.show('Flash操作正在进行，完成或强制终止前不能退出应用');
      _isClosing = false;
      return;
    }
    final modbusService = Provider.of<ModbusClientService>(
      context,
      listen: false,
    );
    final modbusWindowManager = Provider.of<ModbusWindowManager>(
      context,
      listen: false,
    );
    await AppSettings().flushPendingSave();
    await modbusWindowManager.closeAll();
    await modbusService.stop();
    await flashProgrammingService.shutdown();
    await probeConnectionService.shutdown();
    await sshConnectionService.shutdown();
    await connectionService.shutdown();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }
}
