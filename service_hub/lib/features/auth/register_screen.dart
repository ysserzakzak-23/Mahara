import 'package:flutter/material.dart';
import '../../core/api/api_exception.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/city_picker_field.dart';
import '../../shared/widgets/custom_textfield.dart';
import '../home/home_screen.dart';
import 'data/auth_service.dart';
import 'data/city_service.dart';
import '../../core/utils/error_text.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({
    super.key,
    this.authService,
    this.cityService,
    this.homeBuilder,
  });

  /// Optional overrides, mainly so widget tests can inject a fake backend.
  /// In the real app all are null and the defaults below are used.
  final AuthService? authService;
  final CityService? cityService;
  final WidgetBuilder? homeBuilder;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  late final AuthService _authService = widget.authService ?? AuthService();
  late final CityService _cityService = widget.cityService ?? CityService();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _phoneController = TextEditingController();

  bool _loading = false;
  bool _submitted = false;
  late Future<List<String>> _citiesFuture;
  String? _selectedCity;

  @override
  void initState() {
    super.initState();
    _citiesFuture = _cityService.cities();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  // --- validation -----------------------------------------------------------
  // A field shows its error once the user typed something in it, or after the
  // first press on the register button. Otherwise the permanent rule hint is
  // shown under it.

  String? _nameError() {
    if (_nameController.text.trim().length < 2) {
      return 'الاسم الكامل مطلوب (حرفان على الأقل)';
    }
    return null;
  }

  String? _shown(TextEditingController c, String? error) =>
      (_submitted || c.text.isNotEmpty) ? error : null;

  String? get _nameShownError => _shown(_nameController, _nameError());
  String? get _emailShownError =>
      _shown(_emailController, emailError(_emailController.text));
  String? get _phoneShownError =>
      _shown(_phoneController, phoneError(_phoneController.text));
  String? get _passwordShownError =>
      _shown(_passwordController, passwordError(_passwordController.text));
  String? get _confirmShownError => _shown(
        _confirmPasswordController,
        confirmPasswordError(
          _passwordController.text,
          _confirmPasswordController.text,
        ),
      );

  Future<void> _register() async {
    setState(() => _submitted = true);

    final fullName = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final phone = normalizeDigits(_phoneController.text).trim();

    final firstError = _nameError() ??
        emailError(email) ??
        phoneError(phone) ??
        passwordError(password) ??
        confirmPasswordError(password, _confirmPasswordController.text);
    if (firstError != null) {
      _showMessage(firstError);
      return;
    }
    if (_selectedCity == null) {
      _showMessage('يرجى اختيار مدينتك.');
      return;
    }

    setState(() => _loading = true);
    try {
      await _authService.register(
        email: email,
        password: password,
        fullName: fullName,
        phoneNumber: phone,
        city: _selectedCity!,
      );
      await _authService.login(email: email, password: password);
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: widget.homeBuilder ?? ((_) => HomeScreen())),
        (route) => false,
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
          onPressed: () {
            Navigator.pop(context);
          },
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
                  'إنشاء حساب',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),

                const SizedBox(height: 25),

                CustomTextField(
                  hint: 'الاسم الكامل',
                  controller: _nameController,
                  prefixIcon: Icons.person_outline,
                  textInputAction: TextInputAction.next,
                  errorText: _nameShownError,
                  onChanged: (_) => setState(() {}),
                ),

                const SizedBox(height: 15),

                CustomTextField(
                  hint: 'البريد الإلكتروني',
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  prefixIcon: Icons.email_outlined,
                  textInputAction: TextInputAction.next,
                  ltr: true,
                  errorText: _emailShownError,
                  onChanged: (_) => setState(() {}),
                ),

                const SizedBox(height: 15),

                CustomTextField(
                  hint: 'رقم الجوال',
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  prefixIcon: Icons.phone_outlined,
                  textInputAction: TextInputAction.next,
                  ltr: true,
                  helperText: kPhoneRuleText,
                  errorText: _phoneShownError,
                  onChanged: (_) => setState(() {}),
                ),

                const SizedBox(height: 15),

                CustomTextField(
                  hint: 'كلمة المرور',
                  isPassword: true,
                  controller: _passwordController,
                  prefixIcon: Icons.lock_outline,
                  textInputAction: TextInputAction.next,
                  helperText: kPasswordRuleText,
                  errorText: _passwordShownError,
                  onChanged: (_) => setState(() {}),
                ),

                const SizedBox(height: 15),

                CustomTextField(
                  hint: 'تأكيد كلمة المرور',
                  isPassword: true,
                  controller: _confirmPasswordController,
                  prefixIcon: Icons.lock_reset_outlined,
                  textInputAction: TextInputAction.done,
                  helperText: kConfirmPasswordRuleText,
                  errorText: _confirmShownError,
                  onChanged: (_) => setState(() {}),
                ),

                const SizedBox(height: 15),

                FutureBuilder<List<String>>(
                  future: _citiesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const LinearProgressIndicator();
                    }
                    if (snapshot.hasError) {
                      return Text(
                        'تعذّر تحميل المدن: ${errorText(snapshot.error)}',
                        textAlign: TextAlign.center,
                      );
                    }
                    final cities = snapshot.data ?? [];
                    return Container(
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
                      child: CityPickerField(
                        cities: cities,
                        selected: _selectedCity,
                        onChanged: (value) =>
                            setState(() => _selectedCity = value),
                        hint: 'المدينة',
                        prefixIcon: Icons.location_city_outlined,
                      ),
                    );
                  },
                ),

                const SizedBox(height: 20),

                ElevatedButton(
                  onPressed: _loading ? null : _register,
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
                          'إنشاء الحساب',
                          style: TextStyle(color: Colors.white, fontSize: 16),
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
