import 'dart:async';

import 'package:flutter/material.dart';
import 'package:service_hub/features/auth/register_screen.dart';
import '../../core/api/api_exception.dart';
import '../../core/push/push_notification_service.dart';
import '../../shared/widgets/custom_textfield.dart';
import '../home/home_screen.dart';
import 'data/auth_service.dart';
import 'forgot_password_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    this.authService,
    this.homeBuilder,
    this.pushSetup,
  });

  /// Optional overrides, mainly so widget tests can inject a fake backend.
  /// In the real app all are null and the defaults below are used.
  final AuthService? authService;
  final WidgetBuilder? homeBuilder;

  /// Registers this device for push notifications after a successful login.
  /// Defaults to the real Firebase-backed [PushNotificationService]; widget
  /// tests pass a fake because Firebase is never initialized there.
  final Future<void> Function()? pushSetup;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final AuthService _authService = widget.authService ?? AuthService();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      _showMessage('يرجى إدخال البريد الإلكتروني وكلمة المرور.');
      return;
    }

    setState(() => _loading = true);
    try {
      await _authService.login(email: email, password: password);
      if (!mounted) return;
      // Fire-and-forget: registering the push token shouldn't block or
      // fail the login itself (e.g. if Firebase didn't initialize).
      unawaited(
        (widget.pushSetup ?? PushNotificationService().initialize)(),
      );
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: widget.homeBuilder ?? ((_) => HomeScreen())),
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

  void _openForgotPassword() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ForgotPasswordScreen(
          authService: _authService,
          initialEmail: _emailController.text.trim(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _BrandHeader(),

                const SizedBox(height: 30),

                CustomTextField(
                  hint: 'البريد الإلكتروني',
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  prefixIcon: Icons.email_outlined,
                  textInputAction: TextInputAction.next,
                  ltr: true,
                ),

                const SizedBox(height: 16),

                CustomTextField(
                  hint: 'كلمة المرور',
                  isPassword: true,
                  controller: _passwordController,
                  prefixIcon: Icons.lock_outline,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (!_loading) _login();
                  },
                ),

                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: _loading ? null : _openForgotPassword,
                    child: const Text('نسيت كلمة المرور؟'),
                  ),
                ),

                const SizedBox(height: 8),

                ElevatedButton(
                  onPressed: _loading ? null : _login,
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
                          'تسجيل الدخول',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                ),

                const SizedBox(height: 16),

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('ليس لديك حساب؟'),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => RegisterScreen(),
                                ),
                              );
                            },
                      child: const Text('إنشاء حساب',style: TextStyle(color: Colors.green),),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final gradient = isDark
        ? const [Color.fromARGB(255, 96, 101, 99), Color.fromARGB(255, 165, 173, 173)]
        : const [Color.fromARGB(255, 5, 6, 6), Color.fromARGB(255, 77, 80, 80)];

    return Column(
      children: [
        Container(
          child: Icon(
            Icons.handshake,
            size: 75,
            color: isDark ? const Color.fromARGB(255, 122, 128, 128) : Colors.black,
          ),
        ),
        const SizedBox(height: 10),
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            colors: gradient,
          ).createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height)),
          child: const Text(
            'مَهارة',
            style: TextStyle(
              fontSize: 46,
              fontWeight: FontWeight.w900,
              height: 1.2,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'تطبيقك لتبادل الخدمات والمهارات',
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }
}
