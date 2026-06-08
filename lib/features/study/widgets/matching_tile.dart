import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

enum MatchingTileState { normal, selected, matched, incorrect }

class MatchingTile extends StatefulWidget {
  final String text;
  final MatchingTileState state;
  final VoidCallback? onTap;

  const MatchingTile({
    super.key,
    required this.text,
    required this.state,
    this.onTap,
  });

  @override
  State<MatchingTile> createState() => _MatchingTileState();
}

class _MatchingTileState extends State<MatchingTile> {
  static const Color _primary = Color(0xFF6F8451);
  static const Color _textDark = Color(0xFF24311F);
  bool _pressed = false;
  int _matchedAnimSeed = 0;

  @override
  void didUpdateWidget(covariant MatchingTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final justMatched =
        oldWidget.state != MatchingTileState.matched &&
        widget.state == MatchingTileState.matched;
    if (justMatched) {
      setState(() => _matchedAnimSeed++);
    }
  }

  @override
  Widget build(BuildContext context) {
    late final Color bgColor;
    late final Color borderColor;
    late final Color textColor;
    late final Widget child;
    List<BoxShadow> shadows = const [];

    switch (widget.state) {
      case MatchingTileState.selected:
        bgColor = const Color(0xFFEAF2DC);
        borderColor = _primary;
        textColor = _textDark;
        child = _buildLabel(textColor);
        shadows = [
          BoxShadow(
            color: _primary.withValues(alpha: 0.18),
            blurRadius: 0,
            spreadRadius: 2,
          ),
          BoxShadow(
            color: _primary.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ];
      case MatchingTileState.matched:
        bgColor = const Color(0xFFDDE9CB);
        borderColor = const Color(0xFF9AB37A);
        textColor = _primary;
        child = TweenAnimationBuilder<double>(
          key: ValueKey('matched_icon_$_matchedAnimSeed'),
          tween: Tween<double>(begin: 0.88, end: 1.0),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          builder: (context, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: const Icon(
            Icons.check_circle_rounded,
            color: Color(0xFF6F8451),
            size: 32,
          ),
        );
        shadows = [
          BoxShadow(
            color: _primary.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ];
      case MatchingTileState.incorrect:
        bgColor = const Color(0xFFFFE3DD);
        borderColor = const Color(0xFFE3826F);
        textColor = const Color(0xFF9A3F2E);
        child = _buildLabel(textColor);
      case MatchingTileState.normal:
        bgColor = const Color(0xFFFFFCF4);
        borderColor = _primary.withValues(alpha: 0.24);
        textColor = _textDark;
        child = _buildLabel(textColor);
        shadows = [
          BoxShadow(
            color: _primary.withValues(alpha: 0.10),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ];
    }

    final canTap =
        widget.state != MatchingTileState.matched && widget.onTap != null;

    final tileBody = GestureDetector(
      onTapDown: canTap ? (_) => setState(() => _pressed = true) : null,
      onTap: canTap
          ? () {
              setState(() => _pressed = false);
              widget.onTap!();
            }
          : null,
      onTapCancel: canTap ? () => setState(() => _pressed = false) : null,
      child: AnimatedScale(
        scale: _pressed ? 0.965 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.all(12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: borderColor,
              width: widget.state == MatchingTileState.normal ? 1.5 : 2,
            ),
            boxShadow: shadows,
          ),
          child: child,
        ),
      ),
    );

    return tileBody;
  }

  Widget _buildLabel(Color color) {
    return Text(
      widget.text,
      textAlign: TextAlign.center,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.notoSerifTc(
        textStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: color,
          height: 1.2,
        ),
      ),
    );
  }
}
