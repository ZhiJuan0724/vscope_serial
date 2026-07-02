part of '../plot_page.dart';

/// 众邦电控通道预设选择弹窗，支持列表和网格两种展示模式。
class _PresetSelectorDialog extends StatefulWidget {
  final AddressConfigProfile profile;
  final ValueChanged<AddressChannelPreset> onSelect;

  const _PresetSelectorDialog({required this.profile, required this.onSelect});

  @override
  State<_PresetSelectorDialog> createState() => _PresetSelectorDialogState();
}

enum _PresetViewMode { list, grid }

class _PresetSelectorDialogState extends State<_PresetSelectorDialog> {
  late _PresetViewMode _viewMode;
  late final TextEditingController _searchController;
  String _searchText = '';

  List<AddressChannelPreset> get _filteredPresets {
    final query = _searchText.trim().toLowerCase();
    if (query.isEmpty) return widget.profile.presets;
    return widget.profile.presets.where((preset) {
      final hexAddress = _formatZobowAddress(preset.address).toLowerCase();
      final compactAddress =
          _formatZobowAddress(preset.address, compact: true).toLowerCase();
      final decimalAddress = '${preset.address & 0xFFFFFFFF}';
      return preset.name.toLowerCase().contains(query) ||
          hexAddress.contains(query) ||
          compactAddress.contains(query) ||
          decimalAddress.contains(query);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _viewMode =
        AppSettings().zobowPresetViewMode == 'list'
            ? _PresetViewMode.list
            : _PresetViewMode.grid;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleViewMode() {
    setState(() {
      _viewMode =
          _viewMode == _PresetViewMode.list
              ? _PresetViewMode.grid
              : _PresetViewMode.list;
    });
    final settings = AppSettings();
    settings.zobowPresetViewMode =
        _viewMode == _PresetViewMode.list ? 'list' : 'grid';
    settings.save();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFFF0F0F5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: Row(
        children: [
          Expanded(
            child: Text(
              AppStrings.plot.selectAddressTitle(widget.profile.name),
              style: const TextStyle(color: Color(0xFF333344), fontSize: 15),
            ),
          ),
          // 视图切换按钮
          Tooltip(
            message:
                _viewMode == _PresetViewMode.list
                    ? AppStrings.plot.switchToGrid
                    : AppStrings.plot.switchToList,
            child: InkWell(
              onTap: _toggleViewMode,
              child: Icon(
                _viewMode == _PresetViewMode.list
                    ? Icons.grid_view
                    : Icons.list,
                size: 20,
                color: const Color(0xFF666688),
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: _viewMode == _PresetViewMode.list ? 320 : 540,
        height: 360,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              autofocus: true,
              style: const TextStyle(fontSize: 13, color: Color(0xFF333344)),
              decoration: InputDecoration(
                isDense: true,
                hintText: AppStrings.plot.searchNameOrAddress,
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon:
                    _searchText.isEmpty
                        ? null
                        : IconButton(
                          tooltip: AppStrings.plot.selectAddressSearchClear,
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchText = '');
                          },
                        ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              onChanged: (value) => setState(() => _searchText = value),
            ),
            const SizedBox(height: 8),
            Expanded(
              child:
                  _filteredPresets.isEmpty
                      ? Center(
                        child: Text(
                          AppStrings.plot.noMatchingAddress,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF8888AA),
                          ),
                        ),
                      )
                      : _viewMode == _PresetViewMode.list
                      ? _buildListView()
                      : _buildGridView(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            AppStrings.common.cancel,
            style: const TextStyle(color: Color(0xFF666688)),
          ),
        ),
      ],
    );
  }

  /// 单列列表视图（每行较细）
  Widget _buildListView() {
    final presets = _filteredPresets;
    return ListView.builder(
      itemCount: presets.length,
      itemBuilder: (context, index) {
        final preset = presets[index];
        final displayAddress = preset.formatAddress(compactHex: true);
        return InkWell(
          onTap: () {
            widget.onSelect(preset);
            Navigator.pop(context);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: const Color(0xFFD0D0E0).withValues(alpha: 0.5),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    preset.name,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF333344),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  displayAddress,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8888AA),
                    fontFamily: 'SarasaUiSC',
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 5列平铺视图
  Widget _buildGridView() {
    final presets = _filteredPresets;
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        childAspectRatio: 1.8,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: presets.length,
      itemBuilder: (context, index) {
        final preset = presets[index];
        final displayAddress = preset.formatAddress(compactHex: true);
        return InkWell(
          onTap: () {
            widget.onSelect(preset);
            Navigator.pop(context);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFFD0D0E0), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  preset.name,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF333344),
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                const SizedBox(height: 2),
                Text(
                  displayAddress,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF8888AA),
                    fontFamily: 'SarasaUiSC',
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
