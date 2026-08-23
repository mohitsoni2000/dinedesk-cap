import 'dart:math';

final _random = Random();

String newRequestId() {
  final rand =
      List.generate(8, (_) => _random.nextInt(16).toRadixString(16)).join();
  return 'req_${DateTime.now().microsecondsSinceEpoch}_$rand';
}
