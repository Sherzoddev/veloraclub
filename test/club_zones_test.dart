import 'package:flutter_test/flutter_test.dart';
import 'package:velora_club/src/screens/club_page.dart';

void main() {
  // The hall map groups tables by zone: in the zones table's order, with a
  // zone typed only on a table kept after them and blank zones left out.
  test('zones follow the club order and skip empty ones', () {
    final resources = [
      {'name': 'Вип 1', 'zone': 'VIP'},
      {'name': 'Зал 1', 'zone': 'Зал'},
      {'name': 'Кабина 1', 'zone': ' Кабина '},
      {'name': 'Тераса 1', 'zone': 'Тераса'},
      {'name': 'Стол', 'zone': null},
      {'name': 'Стол 2', 'zone': ''},
    ];
    final zoneRows = [
      {'name': 'Зал'},
      {'name': 'Кабина'},
      {'name': 'VIP'},
      {'name': 'Пустая'},
    ];
    expect(clubZones(resources, zoneRows), ['Зал', 'Кабина', 'VIP', 'Тераса']);
  });
}
