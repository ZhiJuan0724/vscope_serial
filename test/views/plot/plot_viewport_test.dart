import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/views/plot/plot_viewport.dart';

void main() {
  group('PlotViewport', () {
    test('默认值', () {
      final vp = PlotViewport();
      expect(vp.xMin, 0.0);
      expect(vp.xMax, 1000.0);
      expect(vp.yMin, 0.0);
      expect(vp.yMax, 32768.0);
      expect(vp.xRange, 1000.0);
      expect(vp.yRange, 32768.0);
    });

    test('不可变语义 - panX返回新实例', () {
      final vp = PlotViewport(xMin: 0, xMax: 1000, yMin: 0, yMax: 1000);
      final newVp = vp.panX(100, 800); // 画布宽800，绘图区宽720

      // 原实例不变
      expect(vp.xMin, 0.0);
      expect(vp.xMax, 1000.0);

      // 新实例变化
      expect(newVp.xMin, lessThan(0.0));
      expect(newVp.xMax, lessThan(1000.0));
    });

    test('不可变语义 - panY返回新实例', () {
      final vp = PlotViewport(xMin: 0, xMax: 1000, yMin: 0, yMax: 1000);
      final newVp = vp.panY(100, 600); // 画布高600，绘图区高540

      // 原实例不变
      expect(vp.yMin, 0.0);
      expect(vp.yMax, 1000.0);

      // 新实例变化
      expect(newVp.yMin, greaterThan(0.0));
      expect(newVp.yMax, greaterThan(1000.0));
    });

    test('不可变语义 - zoomX返回新实例', () {
      final vp = PlotViewport(xMin: 0, xMax: 1000, yMin: 0, yMax: 1000);
      final newVp = vp.zoomX(0.5, 500); // 以500为中心缩放0.5倍

      // 原实例不变
      expect(vp.xMin, 0.0);
      expect(vp.xMax, 1000.0);

      // 新实例范围缩小
      expect(newVp.xRange, closeTo(500.0, 1.0));
    });

    test('不可变语义 - reset返回新实例', () {
      final vp = PlotViewport(xMin: 100, xMax: 500, yMin: 200, yMax: 800);
      final newVp = vp.reset();

      // 原实例不变
      expect(vp.xMin, 100.0);

      // 新实例恢复默认
      expect(newVp.xMin, 0.0);
      expect(newVp.xMax, 1000.0);
      expect(newVp.yMin, 0.0);
      expect(newVp.yMax, 32768.0);
    });

    test('坐标转换 - dataToScreenX', () {
      final vp = PlotViewport(xMin: 0, xMax: 1000, yMin: 0, yMax: 1000);
      const canvasWidth = 800.0;

      // x=0 应在 marginLeft 处
      expect(vp.dataToScreenX(0, canvasWidth), vp.marginLeft);

      // x=1000 应在 canvasWidth - marginRight 处
      expect(vp.dataToScreenX(1000, canvasWidth), canvasWidth - vp.marginRight);
    });

    test('坐标转换 - screenToDataX', () {
      final vp = PlotViewport(xMin: 0, xMax: 1000, yMin: 0, yMax: 1000);
      const canvasWidth = 800.0;

      // marginLeft 处应为 x=0
      expect(vp.screenToDataX(vp.marginLeft, canvasWidth), 0.0);

      // canvasWidth - marginRight 处应为 x=1000
      expect(
        vp.screenToDataX(canvasWidth - vp.marginRight, canvasWidth),
        1000.0,
      );
    });

    test('copyWith只修改指定字段', () {
      final vp = PlotViewport(xMin: 0, xMax: 1000, yMin: 0, yMax: 1000);
      final newVp = vp.copyWith(xMin: 100);

      expect(newVp.xMin, 100.0);
      expect(newVp.xMax, 1000.0); // 未修改
      expect(newVp.yMin, 0.0); // 未修改
      expect(newVp.yMax, 1000.0); // 未修改
    });

    test('copy创建完整副本', () {
      final vp = PlotViewport(xMin: 100, xMax: 500, yMin: 200, yMax: 800);
      final copy = vp.copy();

      expect(copy.xMin, vp.xMin);
      expect(copy.xMax, vp.xMax);
      expect(copy.yMin, vp.yMin);
      expect(copy.yMax, vp.yMax);

      // 修改副本不影响原实例
      final modified = copy.copyWith(xMin: 999);
      expect(vp.xMin, 100.0);
      expect(modified.xMin, 999.0);
    });

    test('offset axis column widths adjust margin and survive copy', () {
      final vp = PlotViewport();

      vp.setOffsetAxisColumnWidths([42, 68, 92]);

      expect(vp.offsetChannelCount, 3);
      expect(vp.offsetAxisColumnWidths, [42, 68, 92]);
      expect(vp.marginRight, 20 + 42 + 68 + 92);

      final copy = vp.copy();
      expect(copy.offsetAxisColumnWidths, [42, 68, 92]);
      expect(copy.marginRight, vp.marginRight);
    });
  });
}
