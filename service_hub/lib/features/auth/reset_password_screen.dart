import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/api/api_exception.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/custom_textfield.dart';
import 'data/auth_service.dart';

/// Step 2 of password recovery: the 6-digit code from the email + the new
/// password (typed twice). On success the user goes back to the login screen.
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({
    super.key,
    required this.email,
    this.authService,
  });

  final String email;

  /// Optional override so widget tests can inject a fake backend.
  final AuthService? authService;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  static const int _resendSeconds = 60;

  late final AuthService _authService = widget.authService ?? AuthService();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _loading = false;
  bool _submitted = false;
  int _secondsLeft = _resendSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startCooldown(notify: false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _startCooldown({bool notify = true}) {
    _timer?.cancel();
    if (notify) {
      setState(() => _secondsLeft = _resendSeconds);
    } else {
      _secondsLeft = _resendSeconds;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_secondsLeft <= 1) {
        timer.cancel();
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  String? _codeError() {
    final code = normalizeDigits(_codeController.text).trim();
    if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) {
      return 'أدخل رمز التحقق المكوّن من 6 أرقام';
    }
    return null;
  }

  String? _shown(TextEditingController c, String? error) =>
      (_submitted || c.text.isNotEmpty) ? error : null;

  Future<void> _resend() async {
    if (_secondsLeft > 0 || _loading) return;
    try {
      await _authService.forgotPassword(email: widget.email);
      if (!mounted) return;
      _startCooldown();
      _showMessage('تم إرسال رمز جديد إلى بريدك الإلكتروني.');
    } on ApiException catch (e) {
      _showMessage(e.message);
    }
  }

  Future<void> _submit() async {
    setState(() => _submitted = true);
    final password = _passwordController.text;
    final error = _codeError() ??
        passwordError(password) ??
        confirmPasswordError(password, _confirmController.text);
    if (error != null) {
      _showMessage(error);
      return;
    }

    setState(() => _loading = true);
    try {
      await _authService.resetPassword(
        email: widget.email,
        code: normalizeDigits(_codeController.text).trim(),
        newPassword: password,
      );
      if (!mounted) return;
      _showMessage('تم تغيير كلمة المرور بنجاح، يمكنك الآن تسجيل الدخول.');
      Navigator.popUntil(context, (route) => route.isFirst);
    } on ApiException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final mutedColor =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color.fromARGB(0, 79, 78, 78),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'تعيين كلمة مرور جديدة',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Text(
                  'أرسلنا رمز تحقق من 6 أرقام إلى',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: mutedColor),
                ),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    widget.email,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 24),
                CustomTextField(
                  hint: 'رمز التحقق',
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  prefixIcon: Icons.pin_outlined,
                  textInputAction: TextInputAction.next,
                  ltr: true,
                  maxLength: 6,
                  errorText: _shown(_codeController, _codeError()),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 15),
                CustomTextField(
                  hint: 'كلمة المرور الجديدة',
                  isPassword: true,
                  controller: _passwordController,
                  prefixIcon: Icons.lock_outline,
                  textInputAction: TextInputAction.next,
                  helperText: kPasswordRuleText,
                  errorText: _shown(
                    _passwordController,
                    passwordError(_passwordController.text),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 15),
                CustomTextField(
                  hint: 'تأكيد كلمة المرور الجديدة',
                  isPassword: true,
                  controller: _confirmController,
                  prefixIcon: Icons.lock_reset_outlined,
                  textInputAction: TextInputAction.done,
                  helperText: kConfirmPasswordRuleText,
                  errorText: _shown(
                    _confirmController,
                    confirmPasswordError(
                      _passwordController.text,
                      _confirmController.text,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'تغيير كلمة المرور',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: (_secondsLeft > 0 || _loading) ? null : _resend,
                  child: Text(
                    _secondsLeft > 0
                        ? 'إعادة إرسال الرمز بعد $_secondsLeft ثانية'
                        : 'إعادة إرسال الرمز',
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
