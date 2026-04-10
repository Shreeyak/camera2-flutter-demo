import 'package:cambrian_camera/cambrian_camera.dart' show CameraSize;
import 'package:flutter/material.dart';

/// Shows a scrollable resolution picker dialog, with the currently selected
/// resolution centered in the visible area on open.
///
/// [context] must be valid and mounted at call time — it is passed directly
/// to [showDialog].
void showResolutionPicker(
  BuildContext context, {
  required List<CameraSize> resolutions,
  required String currentLabel,
  required ValueChanged<CameraSize> onSelected,
}) {
  showDialog<void>(
    context: context,
    builder: (_) => _ResolutionPickerDialog(
      resolutions: resolutions,
      currentLabel: currentLabel,
      onSelected: onSelected,
    ),
  );
}

class _ResolutionPickerDialog extends StatefulWidget {
  final List<CameraSize> resolutions;
  final String currentLabel;
  final ValueChanged<CameraSize> onSelected;

  const _ResolutionPickerDialog({
    required this.resolutions,
    required this.currentLabel,
    required this.onSelected,
  });

  @override
  State<_ResolutionPickerDialog> createState() =>
      _ResolutionPickerDialogState();
}

class _ResolutionPickerDialogState extends State<_ResolutionPickerDialog> {
  // Fixed height per item — standard Material ListTile compact height.
  static const double _itemHeight = 48.0;
  // Show at most 8 items before scrolling.
  static const int _maxVisibleItems = 8;
  // Wide enough for the longest resolution label (e.g. "4208x3120") in
  // monospace, plus ListTile horizontal padding. Keeps the dialog compact.
  static const double _contentWidth = 160.0;

  late final ScrollController _scrollController;
  late final int _selectedIndex;
  late final double _listHeight;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _selectedIndex = widget.resolutions.indexWhere(
      (s) => '${s.width}x${s.height}' == widget.currentLabel,
    );
    _listHeight = _itemHeight *
        widget.resolutions.length.clamp(1, _maxVisibleItems);

    if (_selectedIndex >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    if (!_scrollController.hasClients) return;
    // Center the selected item in the visible area.
    final double target =
        (_selectedIndex * _itemHeight) - (_listHeight / 2 - _itemHeight / 2);
    _scrollController.jumpTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Resolution'),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      // Constrain dialog width so it wraps the text rather than filling the screen.
      constraints: const BoxConstraints(maxWidth: _contentWidth + 48),
      content: SizedBox(
        width: _contentWidth,
        height: _listHeight,
        child: ListView.builder(
          controller: _scrollController,
          itemCount: widget.resolutions.length,
          itemExtent: _itemHeight,
          itemBuilder: (_, i) {
            final size = widget.resolutions[i];
            final label = '${size.width}x${size.height}';
            final isCurrent = label == widget.currentLabel;
            return ListTile(
              dense: true,
              title: Text(
                label,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight:
                      isCurrent ? FontWeight.bold : FontWeight.normal,
                  color: isCurrent ? cs.primary : null,
                ),
              ),
              onTap: () {
                Navigator.of(context).pop();
                widget.onSelected(size);
              },
            );
          },
        ),
      ),
    );
  }
}
