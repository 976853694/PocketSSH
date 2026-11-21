import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:xterm2/xterm.dart';

class TerminalSelection extends StatefulWidget {
  const TerminalSelection({
    super.key,
    required this.terminal,
    required this.controller,
    required this.viewKey,
    required this.focusNode,
    required this.connected,
    required this.onCopy,
    required this.onPaste,
    required this.child,
  });

  final Terminal terminal;
  final TerminalController controller;
  final GlobalKey<TerminalViewState> viewKey;
  final FocusNode focusNode;
  final bool connected;
  final VoidCallback onCopy;
  final VoidCallback onPaste;
  final Widget child;

  @override
  State<TerminalSelection> createState() => _TerminalSelectionState();
}

typedef _SelectionLayout = ({
  Size size,
  Offset anchor,
  Offset? start,
  Offset? end,
  bool dragging,
});

class _TerminalSelectionState extends State<TerminalSelection> {
  final _viewport = GlobalKey();
  final _layout = ValueNotifier<_SelectionLayout?>(null);
  Timer? _pressTimer;
  int? _pressPointer;
  Offset? _pressStart;
  bool _moved = false;
  bool _held = false;
  bool _deferredFocus = false;
  bool _hadSelection = false;
  Offset? _menuPosition;
  bool _layoutPending = false;
  int? _handlePointer;
  bool _dragStart = false;
  CellAnchor? _fixedAnchor;
  Offset _handleOffset = Offset.zero;
  Offset? _handlePosition;
  EdgeDraggingAutoScroller? _autoScroller;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scheduleLayout);
    widget.terminal.addListener(_scheduleLayout);
  }

  void _scheduleLayout() {
    if (_menuPosition == null || _layoutPending) return;
    _layoutPending = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _layoutPending = false;
      if (mounted) _measure();
    });
    binding.ensureVisualUpdate();
  }

  void _measure() {
    final position = _menuPosition;
    final view = widget.viewKey.currentState;
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (position == null || view == null || box == null || !box.hasSize) return;
    final render = view.renderTerminal;
    final range = widget.controller
        .selectionFor(widget.terminal.buffer)
        ?.normalized;
    Offset endpoint(CellOffset cell) => box.globalToLocal(
      render.localToGlobal(
        render.getOffset(cell) + Offset(0, render.lineHeight),
      ),
    );
    final selected = range != null && !range.isCollapsed;
    final start = selected ? endpoint(range.begin) : null;
    final end = selected ? endpoint(range.end) : null;
    bool visible(Offset? point) =>
        point != null && point.dy >= 0 && point.dy <= box.size.height;
    _layout.value = (
      size: box.size,
      anchor: visible(start)
          ? start!
          : visible(end)
          ? end!
          : box.globalToLocal(position),
      start: start,
      end: end,
      dragging: _handlePointer != null,
    );
  }

  void _onDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    if (_pressPointer != null) {
      _moved = true;
      _pressTimer?.cancel();
      return;
    }
    _dismiss();
    _pressPointer = event.pointer;
    _pressStart = event.position;
    _hadSelection =
        widget.controller.selectionFor(widget.terminal.buffer) != null;
    _deferredFocus =
        !widget.focusNode.hasFocus && widget.focusNode.canRequestFocus;
    // xterm requests focus on tap-down, before a touch resolves into a tap.
    if (_deferredFocus) widget.focusNode.canRequestFocus = false;
    _pressTimer = Timer(kLongPressTimeout, () => _held = true);
  }

  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _pressPointer || _held || _moved) return;
    final slop = MediaQuery.gestureSettingsOf(context).touchSlop ?? kTouchSlop;
    if ((event.position - _pressStart!).distance > slop) {
      _moved = true;
      _pressTimer?.cancel();
    }
  }

  void _onUp(PointerUpEvent event) {
    if (event.pointer != _pressPointer) return;
    final show = _held && !_moved;
    final requestKeyboard =
        _deferredFocus && !show && !_moved && !_hadSelection;
    _finishPress();
    if (show) {
      _menuPosition = event.position;
      _scheduleLayout();
    } else if (requestKeyboard && widget.connected) {
      widget.viewKey.currentState?.requestKeyboard();
    }
  }

  void _finishPress() {
    _pressTimer?.cancel();
    _pressTimer = null;
    _pressPointer = null;
    _pressStart = null;
    _held = false;
    _moved = false;
    if (_deferredFocus) widget.focusNode.canRequestFocus = true;
    _deferredFocus = false;
  }

  void _startHandle(bool start, PointerDownEvent event) {
    if (_handlePointer != null || event.buttons != kPrimaryButton) return;
    final buffer = widget.terminal.buffer;
    final range = widget.controller.selectionFor(buffer)?.normalized;
    final view = widget.viewKey.currentState;
    if (range == null || view == null) return;
    _handlePointer = event.pointer;
    _dragStart = start;
    _fixedAnchor = buffer.createAnchorFromOffset(
      start ? range.end : range.begin,
    );
    final render = view.renderTerminal;
    final point = render.localToGlobal(
      render.getOffset(start ? range.begin : range.end) +
          Offset(0, render.lineHeight / 2),
    );
    _handleOffset = point - event.position;
    _handlePosition = point;
    final scrollable = view.scrollableState;
    if (scrollable != null) {
      _autoScroller = EdgeDraggingAutoScroller(
        scrollable,
        velocityScalar: 30,
        onScrollViewScrolled: _adjustSelection,
      );
    }
    _scheduleLayout();
  }

  void _moveHandle(PointerMoveEvent event) {
    if (event.pointer != _handlePointer) return;
    final point = _handlePosition = event.position + _handleOffset;
    _adjustSelection();
    final scroller = _autoScroller;
    if (scroller == null) return;
    final viewport = widget.viewKey.currentState!.renderTerminal;
    scroller.startAutoScrollIfNecessary(
      Rect.fromCenter(
        center: point,
        width: 0,
        height: math.min(36, viewport.size.height),
      ),
    );
  }

  void _adjustSelection() {
    final position = _handlePosition;
    final fixed = _fixedAnchor;
    final view = widget.viewKey.currentState;
    final buffer = widget.terminal.buffer;
    if (position == null ||
        fixed == null ||
        view == null ||
        !buffer.ownsAnchor(fixed)) {
      return;
    }
    final render = view.renderTerminal;
    final local = render.globalToLocal(position);
    final cell = render.getCellOffset(local);
    final rowStart = render.getOffset(CellOffset(0, cell.y));
    final width = widget.terminal.viewWidth;
    var x = ((local.dx - rowStart.dx) / render.cellSize.width).round().clamp(
      0,
      width,
    );
    final line = buffer.lines[cell.y];
    if (x > 0 &&
        x < width &&
        line.getWidth(x) == 0 &&
        line.getWidth(x - 1) == 2) {
      x += _dragStart ? -1 : 1;
    }
    final moving = CellOffset(x, cell.y);
    final other = fixed.offset;
    if (_dragStart ? !moving.isBefore(other) : !moving.isAfter(other)) return;
    final range = widget.controller.selectionFor(buffer)?.normalized;
    if (range == null || moving == (_dragStart ? range.begin : range.end)) {
      return;
    }
    widget.controller.setSelection(
      buffer.createAnchorFromOffset(_dragStart ? moving : other),
      buffer.createAnchorFromOffset(_dragStart ? other : moving),
      mode: SelectionMode.line,
    );
  }

  void _finishHandle() {
    _autoScroller?.stopAutoScroll();
    _autoScroller = null;
    _fixedAnchor?.dispose();
    _fixedAnchor = null;
    _handlePointer = null;
    _handlePosition = null;
  }

  void _dismiss() {
    _menuPosition = null;
    _finishHandle();
    _layout.value = null;
  }

  @override
  void dispose() {
    _finishPress();
    _finishHandle();
    widget.controller.removeListener(_scheduleLayout);
    widget.terminal.removeListener(_scheduleLayout);
    _layout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
    child: Stack(
      key: _viewport,
      fit: StackFit.expand,
      children: [
        NotificationListener<LayoutChangedNotification>(
          onNotification: (_) {
            _scheduleLayout();
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _scheduleLayout();
              return false;
            },
            child: SizeChangedLayoutNotifier(
              child: Listener(
                onPointerDown: _onDown,
                onPointerMove: _onMove,
                onPointerUp: _onUp,
                onPointerCancel: (event) {
                  if (event.pointer == _pressPointer) _finishPress();
                },
                child: widget.child,
              ),
            ),
          ),
        ),
        ValueListenableBuilder<_SelectionLayout?>(
          valueListenable: _layout,
          builder: (context, layout, _) {
            if (layout == null) return const SizedBox.shrink();
            final positions = _handlePositions(layout);
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                if (!layout.dragging) _toolbar(layout),
                if (positions.start case final rect?) _handle(rect, true),
                if (positions.end case final rect?) _handle(rect, false),
              ],
            );
          },
        ),
      ],
    ),
  );

  Widget _toolbar(_SelectionLayout layout) {
    final colors = Theme.of(context).colorScheme;
    final width = math.min(224.0, layout.size.width);
    const height = 48.0;
    final anchor = layout.anchor;
    final top = anchor.dy > 70 ? anchor.dy - 70 : anchor.dy + 38;
    return Positioned(
      left: (anchor.dx - width / 2).clamp(0, layout.size.width - width),
      top: top.clamp(0, math.max(0, layout.size.height - height)),
      width: width,
      height: height,
      child: ExcludeFocus(
        child: Material(
          elevation: 3,
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(9),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  key: const ValueKey('terminal-copy'),
                  onPressed: layout.start == null
                      ? null
                      : () {
                          _dismiss();
                          widget.onCopy();
                        },
                  child: const Text('复制'),
                ),
              ),
              Expanded(
                child: TextButton(
                  key: const ValueKey('terminal-paste'),
                  onPressed: !widget.connected
                      ? null
                      : () {
                          _dismiss();
                          widget.onPaste();
                        },
                  child: const Text('粘贴'),
                ),
              ),
              IconButton(
                tooltip: '关闭选择',
                onPressed: () {
                  _dismiss();
                  widget.controller.clearSelection();
                },
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }

  ({Rect? start, Rect? end}) _handlePositions(_SelectionLayout layout) {
    final start = layout.start;
    final end = layout.end;
    if (start == null || end == null) return (start: null, end: null);
    final width = math.min(44.0, layout.size.width / 2);
    final height = math.min(38.0, layout.size.height);
    final maxLeft = layout.size.width - width;
    var startLeft = (start.dx - width + 10).clamp(0.0, maxLeft);
    var endLeft = (end.dx - 10).clamp(0.0, maxLeft);
    final maxTop = layout.size.height - height;
    final startTop = (start.dy - 4).clamp(0.0, maxTop);
    final endTop = (end.dy - 4).clamp(0.0, maxTop);
    if ((startTop - endTop).abs() < height &&
        (start.dx - end.dx).abs() < width * 2 &&
        endLeft < startLeft + width &&
        startLeft < endLeft + width) {
      final middle = ((start.dx + end.dx) / 2).clamp(width, maxLeft);
      startLeft = middle - width;
      endLeft = middle;
    }
    Rect? visible(Offset point, double left, double top) =>
        point.dy < 0 || point.dy > layout.size.height
        ? null
        : Rect.fromLTWH(left, top, width, height);
    return (
      start: visible(start, startLeft, startTop),
      end: visible(end, endLeft, endTop),
    );
  }

  Widget _handle(Rect rect, bool start) => Positioned.fromRect(
    key: ValueKey(
      start ? 'terminal-selection-start' : 'terminal-selection-end',
    ),
    rect: rect,
    child: Semantics(
      label: start ? '调整选区起点' : '调整选区终点',
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) => _startHandle(start, event),
        onPointerMove: _moveHandle,
        onPointerUp: _onHandleEnd,
        onPointerCancel: _onHandleEnd,
        child: Align(
          alignment: start ? Alignment.topRight : Alignment.topLeft,
          child: Container(
            width: 16,
            height: 21,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(start ? 9 : 2),
                topRight: Radius.circular(start ? 2 : 9),
                bottomLeft: const Radius.circular(9),
                bottomRight: const Radius.circular(9),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  void _onHandleEnd(PointerEvent event) {
    if (event.pointer != _handlePointer) return;
    _finishHandle();
    _scheduleLayout();
  }
}
