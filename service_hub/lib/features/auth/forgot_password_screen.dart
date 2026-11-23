import 'package:flutter/material.dart';
import '../../core/api/api_exception.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/custom_textfield.dart';
import 'data/auth_service.dart';
import 'reset_password_screen.dart';

/// Step 1 of password recovery: the user types their email and we send them a
/// 6-digit code. On success we move on to [ResetPasswordScreen].
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({
    super.key,
    this.authService,
    this.initialEmail = '',
  });

  /// Optional override so widget tests can inject a fake backend.
  final AuthService? authService;

  /// Pre-filled from whatever the user already typed on the login screen.
  final String initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final AuthService _authService = widget.authService ?? AuthService();
  late final TextEditingController _emailController =
      TextEditingController(text: widget.initialEmail);

  bool _loading = false;
  bool _submitted = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  String? get _shownError => (_submitted || _emailController.text.isNotEmpty)
      ? emailError(_emailController.text)
      : null;

  Future<void> _sendCode() async {
    setState(() => _submitted = true);
    final email = _emailController.text.trim();
    final error = emailError(email);
    if (error != null) {
      _showMessage(error);
      return;
    }

    setState(() => _loading = true);
    try {
      await _authService.forgotPassword(email: email);
      if (!mounted) return;
      _showMessage('تم إرسال رمز التحقق إلى بريدك الإلكتروني.');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) =>
              ResetPasswordScreen(email: email, authService: _authService),
        ),
      );
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
                const Icon(Icons.mark_email_read_outlined, size: 72),
                const SizedBox(height: 16),
                const Text(
                  'نسيت كلمة المرور؟',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Text(
                  'أدخل بريدك الإلكتروني وسنرسل لك رمز تحقق مكوّن من 6 أرقام '
                  'لتعيين كلمة مرور جديدة.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 28),
                CustomTextField(
                  hint: 'البريد الإلكتروني',
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  prefixIcon: Icons.email_outlined,
                  textInputAction: TextInputAction.done,
                  ltr: true,
                  errorText: _shownError,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (!_loading) _sendCode();
                  },
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _loading ? null : _sendCode,
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
                          'إرسال رمز التحقق',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _loading ? null : () => Navigator.pop(context),
                  child: const Text('العودة لتسجيل الدخول'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
