import 'dart:convert';

import 'package:alt/github.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('blob-sha är samma som git hash-object', () {
    expect(gitBlobSha(utf8.encode('hello\n')), 'ce013625030ba8dba906f756967f9e9ca394464a');
  });

  test('filer ändrade på GitHub sedan hämtningen hittas', () {
    final remote = {'a.yaml': '1', 'b.yaml': '2', 'c.yaml': '3'};
    final local = {'a.yaml': '1', 'b.yaml': 'x'};
    // a oförändrad, b ändrad där, c ny där men inte hämtad, d ny på båda håll saknas = ok
    expect(changedSinceSync(['a.yaml', 'b.yaml', 'c.yaml', 'd.yaml'], remote, local), ['b.yaml', 'c.yaml']);
  });
}
