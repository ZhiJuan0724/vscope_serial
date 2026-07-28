import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/constants/window_configuration.dart';
import 'core/localization/app_strings.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/app_logger.dart';
import 'data/models/rtt_config.dart';
import 'services/app_notifications.dart';
import 'services/app_info.dart';
import 'services/app_settings.dart';
import 'services/connection_owner_service.dart';
import 'services/rtt_service.dart';
import 'services/serial_service.dart';
import 'services/update_checker.dart';
import 'services/update_service.dart';
import 'views/dialogs/app_info_dialog.dart';
import 'viewmodels/plot_viewmodel.dart';
import 'viewmodels/probe_plot_viewmodel.dart';
import 'viewmodels/rtt_viewmodel.dart';
import 'viewmodels/shell_viewmodel.dart';
import 'views/pages/plot_page.dart';
import 'views/pages/probe_plot_page.dart';
import 'views/pages/raw_data_page.dart';
import 'views/pages/rtt_page.dart';
import 'views/pages/shell_page.dart';
import 'views/widgets/app_icon.dart';
import 'views/widgets/status_bar.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Provider.debugCheckInvalidValueType = null;
  await AppLogger().init();
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
  SerialService().loadSettings();
  SerialService().initializePortDiscovery();
  await AppIcon.precacheAll();

  // 初始化窗口管理
  await windowManager.ensureInitialized();
  final windowOptions = WindowOptions(
    size: const Size(
      WindowConfiguration.defaultWidth,
      WindowConfiguration.defaultHeight,
    ),
    minimumSize: const Size(
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
    // SerialService 是全局单例，使用 Provider.value 避免 Provider
    // 在重建时 dispose 单例导致连接被意外断开。
    final serialService = SerialService();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: ConnectionOwnerService()),
        ChangeNotifierProvider.value(value: serialService),
        ChangeNotifierProvider(create: (_) => RttService()),
        ChangeNotifierProvider(
          create: (context) => PlotViewModel(serialService),
        ),
        ChangeNotifierProvider(
          create: (context) => ShellViewModel(serialService),
        ),
        ChangeNotifierProvider(
          create: (context) => RttViewModel(context.read<RttService>()),
        ),
        ChangeNotifierProvider(
          create: (context) => ProbePlotViewModel(context.read<RttService>()),
        ),
      ],
      child: MaterialApp(
        title: AppStrings.appName,
        scaffoldMessengerKey: AppNotifications.scaffoldMessengerKey,
        theme: AppTheme.buildLightTheme(),
        home: const MainFrame(),
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
  _WindowCloseListener? _windowCloseListener;

  @override
  void initState() {
    super.initState();
    final savedPage = AppSettings().lastMainPage;
    final settings = AppSettings();
    _currentTabId = switch (savedPage) {
      'shell' when !settings.rawDataShellEnabled => 'rawData',
      'rtt' when !settings.rttPageEnabled => 'rawData',
      'probePlot' when !settings.rttPageEnabled => 'rawData',
      _ => savedPage,
    };
    WidgetsBinding.instance.addObserver(this);
    // 注册窗口关闭处理：关闭前先断开串口。
    _setupWindowCloseHandler();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final recoveryNotice = AppSettings().takeRecoveryNotice();
      if (recoveryNotice != null) AppNotifications.show(recoveryNotice);
      unawaited(_handleStartupUpdates());
    });
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
    final listener = _windowCloseListener;
    if (listener != null) windowManager.removeListener(listener);
    _tabScrollController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
          if (AppSettings().rawDataShellEnabled)
            'shell': (
              id: 'shell',
              label: AppStrings.nav.shell,
              icon: Icons.terminal,
              page: const ShellPage(),
            ),
          'plot': (
            id: 'plot',
            label: AppStrings.nav.plot,
            icon: Icons.show_chart,
            page: const PlotPage(),
          ),
          if (AppSettings().rttPageEnabled)
            'rtt': (
              id: 'rtt',
              label: AppStrings.nav.rtt,
              icon: Icons.developer_board,
              page: const RttPage(),
            ),
          if (AppSettings().rttPageEnabled)
            'probePlot': (
              id: 'probePlot',
              label: '探针绘图',
              icon: Icons.monitor_heart_outlined,
              page: const ProbePlotPage(),
            ),
        };
    return [
      for (final id in AppSettings().mainTabOrder)
        if (available[id] case final tab?) tab,
    ];
  }

  void _reorderTabs(int oldIndex, int newIndex) {
    final visibleTabs = _tabs;
    if (oldIndex == newIndex) return;
    final reorderedVisibleIds = visibleTabs.map((tab) => tab.id).toList();
    final movedId = reorderedVisibleIds.removeAt(oldIndex);
    reorderedVisibleIds.insert(newIndex, movedId);
    var visibleIndex = 0;
    final visibleSet = reorderedVisibleIds.toSet();
    final order = [
      for (final id in AppSettings().mainTabOrder)
        if (visibleSet.contains(id))
          reorderedVisibleIds[visibleIndex++]
        else
          id,
    ];
    setState(() => AppSettings().mainTabOrder = order);
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

  @override
  Widget build(BuildContext context) {
    final serialService = Provider.of<SerialService>(context);
    final connectionOwner = Provider.of<ConnectionOwnerService>(context);
    // 探针连接和活动变化会直接影响两个探针页面的切换权限。
    final rttService = Provider.of<RttService>(context);
    final tabs = _tabs;
    if (!tabs.any((tab) => tab.id == _currentTabId)) {
      _currentTabId = 'rawData';
    }
    final currentIndex = tabs.indexWhere((tab) => tab.id == _currentTabId);
    _ensureSelectedTabVisible(currentIndex);

    return Scaffold(
      body: Column(
        children: [
          // 顶部 Tab 切换栏
          ClipRect(
            child: Container(
              height: 40,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.only(top: 5),
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
                      final isSelected = index == currentIndex;
                      final ownerTab = switch (serialService.activityOwner) {
                        SerialActivityOwner.rawData => 'rawData',
                        SerialActivityOwner.shell => 'shell',
                        SerialActivityOwner.plot => 'plot',
                        SerialActivityOwner.none => null,
                      };
                      final canSwitch = switch (connectionOwner.owner) {
                        ConnectionOwner.rtt => switch (rttService
                            .activityOwner) {
                          ProbeActivityOwner.rttViewer => tab.id == 'rtt',
                          ProbeActivityOwner.probePlot => tab.id == 'probePlot',
                          ProbeActivityOwner.none =>
                            tab.id == 'rtt' || tab.id == 'probePlot',
                        },
                        _ => ownerTab == null || tab.id == ownerTab,
                      };
                      final colorScheme = Theme.of(context).colorScheme;
                      final foreground =
                          isSelected
                              ? colorScheme.primary
                              : canSwitch
                              ? colorScheme.onSurfaceVariant
                              : colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.3,
                              );
                      return ReorderableDelayedDragStartListener(
                        key: ValueKey(tab.id),
                        index: index,
                        child: SizedBox(
                          width: 180,
                          height: 35,
                          child: Material(
                            color:
                                isSelected
                                    ? Theme.of(context).scaffoldBackgroundColor
                                    : Colors.transparent,
                            surfaceTintColor: Colors.transparent,
                            shape:
                                isSelected
                                    ? const _SelectedTabShape()
                                    : const RoundedRectangleBorder(),
                            clipBehavior:
                                isSelected ? Clip.antiAlias : Clip.none,
                            child: InkWell(
                              customBorder:
                                  isSelected
                                      ? const _SelectedTabShape()
                                      : const RoundedRectangleBorder(),
                              onTap:
                                  canSwitch ? () => _selectTab(tab.id) : null,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(tab.icon, size: 16, color: foreground),
                                  const SizedBox(width: 6),
                                  Text(
                                    tab.label,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight:
                                          isSelected
                                              ? FontWeight.bold
                                              : FontWeight.normal,
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

/// 窗口关闭监听器：允许窗口关闭前先断开串口。
class _WindowCloseListener extends WindowListener {
  final BuildContext context;
  bool _isClosing = false;

  _WindowCloseListener(this.context);

  @override
  void onWindowClose() async {
    if (_isClosing) return;
    _isClosing = true;
    final serialService = Provider.of<SerialService>(context, listen: false);
    final rttService = Provider.of<RttService>(context, listen: false);
    await AppSettings().flushPendingSave();
    await rttService.disconnect();
    await serialService.shutdown();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }
}
