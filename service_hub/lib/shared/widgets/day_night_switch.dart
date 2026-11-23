import 'package:flutter/material.dart';

/// The day/night switch, drawn after the design the team sent:
///  * off: grey-blue track; white thumb on the LEFT with a yellow sun, a
///    white moon waiting on the right;
///  * on: blue track with a soft glow; white thumb on the RIGHT with a navy
///    moon, a pale-blue sun left behind on the left.
///
/// The sides are fixed as in the design (not mirrored for RTL).
class DayNightSwitch extends StatelessWidget {
  const DayNightSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String? semanticLabel;

  static const double width = 64;
  static const double height = 30;
  static const double _thumb = 27; // almost the full height, as designed
  static const double thumbIconSize = 17;
  static const double _idleIconSize = 15;
  static const Duration _duration = Duration(milliseconds: 260);

  // Colours sampled from the design.
  static const Color _offTrack = Color(0xFF8A93A5);
  static const Color _onTrack = Color(0xFF375BA0);
  static const Color _thumbColor = Color(0xFFFCFCFC);
  static const Color sunColor = Color(0xFFFDC546);
  static const Color moonColor = Color(0xFF1B3E80);
  static const Color _idleMoon = Color(0xFFFFFFFF);
  static const Color _idleSun = Color(0xFFDAE5F8);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: semanticLabel,
      onTap: () => onChanged(!value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(!value),
          child: AnimatedContainer(
            duration: _duration,
            curve: Curves.easeInOut,
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: value ? _onTrack : _offTrack,
              borderRadius: BorderRadius.circular(height / 2),
              boxShadow: [
                BoxShadow(
                  color: _onTrack.withValues(alpha: value ? 0.4 : 0),
                  blurRadius: 10,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all((height - _thumb) / 2),
              child: Stack(
                children: [
                  // The other state's icon, resting on the free side.
                  AnimatedAlign(
                    duration: _duration,
                    curve: Curves.easeInOut,
                    alignment: value
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                    child: SizedBox(
                      width: _thumb,
                      height: _thumb,
                      child: Icon(
                        value ? Icons.wb_sunny_rounded : Icons.nightlight_round,
                        size: _idleIconSize,
                        color: value ? _idleSun : _idleMoon,
                      ),
                    ),
                  ),
                  AnimatedAlign(
                    duration: _duration,
                    curve: Curves.easeInOut,
                    alignment: value
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      width: _thumb,
                      height: _thumb,
                      decoration: const BoxDecoration(
                        color: _thumbColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 3,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                      child: AnimatedSwitcher(
                        duration: _duration,
                        transitionBuilder: (child, animation) =>
                            RotationTransition(
                              turns: Tween(
                                begin: 0.6,
                                end: 1.0,
                              ).animate(animation),
                              child: FadeTransition(
                                opacity: animation,
                                child: child,
                              ),
                            ),
                        child: Icon(
                          value
                              ? Icons.nightlight_round
                              : Icons.wb_sunny_rounded,
                          key: ValueKey(value),
                          size: thumbIconSize,
                          color: value ? moonColor : sunColor,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
