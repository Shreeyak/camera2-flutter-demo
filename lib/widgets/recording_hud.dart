import 'dart:async' show StreamSubscription, Timer;

import 'package:cambrian_camera/cambrian_camera.dart' show RecordingState;
import 'package:flutter/material.dart'
    show
        AnimatedSwitcher,
        AnimationController,
        BorderRadius,
        BoxDecoration,
        BoxShape,
        BuildContext,
        CircularProgressIndicator,
        Color,
        Colors,
        Column,
        Container,
        CrossAxisAlignment,
        Curves,
        DecoratedBox,
        EdgeInsets,
        FadeTransition,
        FontWeight,
        Key,
        MainAxisSize,
        Padding,
        Row,
        SingleTickerProviderStateMixin,
        SizedBox,
        State,
        StatefulWidget,
        StatelessWidget,
        Text,
        TextOverflow,
        TextStyle,
        ValueKey,
        Widget;

String _formatElapsed(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Non-intrusive recording status overlay.
///
/// Place inside a [Stack] over the camera preview — typically via a
/// [Positioned] widget at the top-right. Manages its own subscription to
/// [stateStream] and drives three visual states:
///
///   - [RecordingState.recording] → dark-red capsule with blinking dot + timer
///   - [RecordingState.idle] after recording → saving spinner + filename + dir
///   - initial idle / error → invisible
///
/// The saving badge auto-dismisses ~2 s after [RecordingState.idle] is received.
class RecordingHud extends StatefulWidget {
  const RecordingHud({
    super.key,
    required this.stateStream,
    required this.displayName,
    required this.outputDir,
  });

  /// Broadcast stream of recording state changes from the camera plugin.
  final Stream<RecordingState> stateStream;

  /// Display name of the current/last file (e.g. "cambrian_1712345678.mp4").
  /// Updated by the caller when [startRecording] resolves.
  final String displayName;

  /// MediaStore relative path shown in the saving badge (e.g. "Movies/CambrianCamera").
  final String outputDir;

  @override
  State<RecordingHud> createState() => _RecordingHudState();
}

// Tri-state for the HUD:
//   null  = invisible (initial or fully dismissed)
//   true  = recording capsule
//   false = saving capsule
enum _HudPhase { hidden, recording, saving }

class _RecordingHudState extends State<RecordingHud> {
  _HudPhase _phase = _HudPhase.hidden;
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _ticker;
  StreamSubscription<RecordingState>? _sub;

  @override
  void initState() {
    super.initState();
    _subscribe(widget.stateStream);
  }

  @override
  void didUpdateWidget(RecordingHud old) {
    super.didUpdateWidget(old);
    if (old.stateStream != widget.stateStream) {
      _sub?.cancel();
      _subscribe(widget.stateStream);
    }
  }

  void _subscribe(Stream<RecordingState> stream) {
    _sub = stream.listen(_onState);
  }

  void _onState(RecordingState state) {
    if (!mounted) return;
    switch (state) {
      case RecordingState.recording:
        setState(() {
          _phase = _HudPhase.recording;
          _stopwatch
            ..reset()
            ..start();
        });
        _ticker?.cancel();
        _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
          if (mounted && _phase == _HudPhase.recording) setState(() {});
        });
      case RecordingState.idle:
        if (_phase == _HudPhase.recording) {
          // We were recording — show "saving" badge, then dismiss.
          _stopwatch.stop();
          _ticker?.cancel();
          _ticker = null;
          setState(() => _phase = _HudPhase.saving);
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && _phase == _HudPhase.saving) {
              setState(() => _phase = _HudPhase.hidden);
            }
          });
        }
      case RecordingState.error:
        _stopwatch.stop();
        _ticker?.cancel();
        _ticker = null;
        if (mounted) setState(() => _phase = _HudPhase.hidden);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    _stopwatch.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: switch (_phase) {
        _HudPhase.recording => _RecordingCapsule(
            key: const ValueKey('rec'),
            elapsed: _stopwatch.elapsed,
          ),
        _HudPhase.saving => _SavingCapsule(
            key: const ValueKey('saving'),
            displayName: widget.displayName,
            outputDir: widget.outputDir,
          ),
        _HudPhase.hidden => const SizedBox.shrink(key: ValueKey('hidden')),
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Recording capsule — dark red pill with blinking dot + elapsed timer
// ---------------------------------------------------------------------------

class _RecordingCapsule extends StatelessWidget {
  const _RecordingCapsule({super.key, required this.elapsed});

  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF7B0000),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _BlinkingDot(),
            const SizedBox(width: 8),
            Text(
              _formatElapsed(elapsed),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Saving capsule — spinner + filename + dir
// ---------------------------------------------------------------------------

class _SavingCapsule extends StatelessWidget {
  const _SavingCapsule({
    super.key,
    required this.displayName,
    required this.outputDir,
  });

  final String displayName;
  final String outputDir;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white70,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'saving file\u2026',
                  style: TextStyle(color: Colors.white70, fontSize: 10),
                ),
                Text(
                  displayName,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'to $outputDir',
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Blinking dot — white circle that pulses at ~0.8 s
// ---------------------------------------------------------------------------

class _BlinkingDot extends StatefulWidget {
  const _BlinkingDot();

  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl,
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
