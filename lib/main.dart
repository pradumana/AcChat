// main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.black,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]).then((_) {
    runApp(const ACchatApp());
  });
}

class ACchatApp extends StatelessWidget {
  const ACchatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ACchat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'RetroFont',
      ),
      home: const ACchatHome(),
    );
  }
}
