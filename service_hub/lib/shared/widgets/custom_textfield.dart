import 'package:flutter/material.dart';

/// App-wide text field.
///
/// [helperText] is the permanent hint shown UNDER the field (e.g. the password
/// rule). When [errorText] is non-null it replaces the helper in red.
/// Password fields get a show/hide eye button automatically.
class CustomTextField extends StatefulWidget {
  final String hint;
  final bool isPassword;
  final TextEditingController? controller;
  final TextInputType? keyboardType;
  final String? helperText;
  final String? errorText;
  final IconData? prefixIcon;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  /// Email / phone / code fields are typed with Latin digits and letters, so
  /// they are edited left-to-right (but still sit on the right edge).
  final bool ltr;
  final int? maxLength;

  const CustomTextField({
    super.key,
    required this.hint,
    this.isPassword = false,
    this.controller,
    this.keyboardType,
    this.helperText,
    this.errorText,
    this.prefixIcon,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
    this.ltr = false,
    this.maxLength,
  });

  @override
  State<CustomTextField> createState() => _CustomTextFieldState();
}

class _CustomTextFieldState extends State<CustomTextField> {
  bool _obscured = true;
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (mounted) setState(() => _focused = _focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasError = widget.errorText != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: TextField(
            controller: widget.controller,
            focusNode: _focusNode,
            obscureText: widget.isPassword && _obscured,
            keyboardType: widget.keyboardType,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            textInputAction: widget.textInputAction,
            maxLength: widget.maxLength,
            textDirection: widget.ltr ? TextDirection.ltr : null,
            textAlign: widget.ltr ? TextAlign.right : TextAlign.start,
            decoration: InputDecoration(
              hintText: widget.hint,
              counterText: '',
              prefixIcon: widget.prefixIcon == null
                  ? null
                  : Icon(widget.prefixIcon),
              suffixIcon: widget.isPassword
                  ? IconButton(
                      tooltip: _obscured
                          ? 'إظهار كلمة المرور'
                          : 'إخفاء كلمة المرور',
                      icon: Icon(
                        _obscured
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                      onPressed: () => setState(() => _obscured = !_obscured),
                    )
                  : null,
              enabledBorder: hasError
                  ? OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Colors.redAccent),
                    )
                  : null,
            ),
          ),
        ),
        // The rule (helperText) only appears while the field is focused; an
        // error message is always shown.
        AnimatedSize(
          duration: const Duration(milliseconds: 150),
          alignment: Alignment.topCenter,
          child: (hasError || (widget.helperText != null && _focused))
              ? Padding(
                  padding: const EdgeInsetsDirectional.only(start: 6, top: 4),
                  child: Text(
                    widget.errorText ?? widget.helperText!,
                    style: TextStyle(
                      fontSize: 12,
                      color: hasError
                          ? Colors.redAccent
                          : Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
