import 'package:flutter/material.dart';
import 'app_colors.dart';

ThemeData appTheme = ThemeData(
  scaffoldBackgroundColor: AppColors.background,
   useMaterial3: true,

  colorScheme: ColorScheme.light(
    primary: AppColors.primary,
    secondary: AppColors.secondary,
    surface: AppColors.card,
    onPrimary: Colors.white,
    onSurface: AppColors.textDark,
  ),

  inputDecorationTheme: InputDecorationTheme(
    filled: true,

    fillColor: Colors.white,

    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(
        color: AppColors.primary, 
        width: 1.5,
      ),
    ),

    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),

    contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 16),
  ),

  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: AppColors.primary,
      minimumSize: Size(double.infinity, 55),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  ),
    navigationBarTheme: NavigationBarThemeData(
    backgroundColor: Colors.white,
    indicatorColor: Colors.grey.shade300,
  ),
);
ThemeData darkAppTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: AppColors.darkBackground,
  useMaterial3: true,

  colorScheme: ColorScheme.dark(
    primary: AppColors.darkPrimary,
    secondary: AppColors.darkPrimary,
    surface: AppColors.darkCard,
    onPrimary: Colors.white,
    onSurface: AppColors.darkText,
  ),

  appBarTheme: const AppBarTheme(
    backgroundColor: AppColors.darkBackground,
    foregroundColor: AppColors.darkText,
  ),

  cardTheme: CardThemeData(color: AppColors.darkCard),
  dialogTheme: DialogThemeData(backgroundColor: AppColors.darkCard),
  popupMenuTheme: PopupMenuThemeData(color: AppColors.darkCard),

  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: AppColors.darkField,
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: Colors.white54, width: 1.5),
    ),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
    contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 16),
  ),

  // Text buttons (dialog «إلغاء», «إضافة», …) default to the slate primary,
  // which is hard to read on darkCard; use the dark theme's text colour.
  // Buttons that set their own colour (e.g. the red «تسجيل الخروج») keep it.
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(foregroundColor: AppColors.darkText),
  ),

  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: AppColors.darkPrimary,
      foregroundColor: Colors.white,
      minimumSize: Size(double.infinity, 55),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  ),

  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: AppColors.darkCard,
    indicatorColor: AppColors.darkPrimary,
  ),
);

