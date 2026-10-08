import 'dart:ffi';

String get hostPlatform => Abi.current().toString().replaceAll('_', '-');
