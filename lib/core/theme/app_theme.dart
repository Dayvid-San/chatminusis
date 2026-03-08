import 'package:flutter/material.dart';

class AppTheme with ChangeNotifier {
  // Mudamos de "lightTheme" para "getTheme" para bater com o seu MyApp
  ThemeData getTheme() {
    return ThemeData(
      primarySwatch: Colors.blue,
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
      ),
    );
  }
}