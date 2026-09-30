// A fake Supabase backend for layout tests: every table / RPC the screens
// read, answered with rows in the exact shape PostgREST returns (embedded
// relations included). Values are deliberately "worst case" -- long names,
// eight-digit sums -- so a layout that survives these survives real data.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const clubId = '63232121-53ac-495f-9f67-b8fa17a99863';
const userId = 'c4e8b893-2159-485c-bbbd-a72c62840446';

// A valid UUID per (prefix, i): screens parse and shorten ids.
String _id(String prefix, int i) {
  final hex =
      prefix.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0xffffffff);
  return '${hex.toRadixString(16).padLeft(8, '0')}-0000-4000-8000-${i.toString().padLeft(12, '0')}';
}

String _ago(Duration d) => DateTime.now().toUtc().subtract(d).toIso8601String();
String _in(Duration d) => DateTime.now().toUtc().add(d).toIso8601String();

final club = <String, dynamic>{
  'id': clubId,
  'name': 'Velora Billiard Club Premium',
  'phone': '+998 90 123 45 67',
  'address': 'Toshkent sh., Yunusobod tumani, Amir Temur ko\'chasi 107B',
  'active': true,
  'currency': 'UZS',
  'timezone': 'Asia/Tashkent',
  'logo_url': null,
  'minor_units': 0,
  'has_billiard': true,
  'has_playstation': true,
  'receipt_header': 'VELORA CLUB',
  'receipt_subtitle': '+998 90 123 45 67',
  'receipt_footer': 'Спасибо за визит!',
  'receipt_qr_url': 'https://t.me/velora',
  'receipt_qr_enabled': true,
  'receipt_qr_caption': 'Мы в соц. сетях',
  'receipt_paper_mm': 80,
  'receipt_font_meta': 15,
  'receipt_font_items': 15,
  'receipt_font_title': 30,
  'receipt_font_total': 20,
  'receipt_font_footer': 15,
  'receipt_font_qr_caption': 15,
  'receipt_print_cost': false,
  'work_hours_text': '10:00 — 04:00',
  'late_note': null,
  'late_until': null,
  'visit_bonus_points': 500,
  'loyalty_earn_percent': 3,
  'default_minimum_minutes': 15,
  'default_rounding_minutes': 5,
  'bot_welcome_photo_url': null,
  'setup_completed_at': _ago(const Duration(days: 30)),
  'created_at': _ago(const Duration(days: 30)),
  'updated_at': _ago(const Duration(days: 1)),
};

final roles = [
  {
    'id': 'role-owner',
    'key': 'owner',
    'name': 'Владелец',
    'is_owner': true,
    'is_system': true
  },
  {
    'id': 'role-admin',
    'key': 'admin',
    'name': 'Администратор',
    'is_owner': false,
    'is_system': true
  },
  {
    'id': 'role-cashier',
    'key': 'cashier',
    'name': 'Кассир',
    'is_owner': false,
    'is_system': true
  },
];

final profile = {
  'id': userId,
  'full_name': 'Константин Александров',
  'phone': '+998901234567'
};

final member = {
  'id': 'member-1',
  'club_id': clubId,
  'user_id': userId,
  'role_id': 'role-owner',
  'active': true,
  'employee_code': null,
  'clubs': club,
  'roles': roles[0],
  'created_at': _ago(const Duration(days: 30)),
};

final _types = [
  {
    'id': 'type-pool',
    'key': 'pool',
    'name': 'Русский бильярд',
    'family': 'BILLIARD',
    'is_vip': false,
    'icon': 'billiard'
  },
  {
    'id': 'type-vip',
    'key': 'vip',
    'name': 'VIP Русский бильярд',
    'family': 'BILLIARD',
    'is_vip': true,
    'icon': 'billiard'
  },
  {
    'id': 'type-ps5',
    'key': 'ps5',
    'name': 'PlayStation 5',
    'family': 'PLAYSTATION',
    'is_vip': false,
    'icon': 'gamepad'
  },
];

Map<String, dynamic> _tariff(int i, String name, String family, int price) => {
      'id': _id('tar', i),
      'club_id': clubId,
      'name': name,
      'kind': 'HOURLY',
      'family': family,
      'color': null,
      'active': true,
      'sort_order': i,
      'price_per_hour': price,
      'minimum_minutes': 15,
      'rounding_minutes': 5,
      'minimum_charge': null,
      'package_minutes': null,
      'package_price': null,
      'archived_at': null,
    };

final tariffs = [
  _tariff(1, 'Бильярд дневной', 'BILLIARD', 60000),
  _tariff(2, 'VIP Бильярд вечерний', 'BILLIARD', 145000),
  _tariff(3, 'PlayStation 5 + 2 джойстика', 'PLAYSTATION', 45000),
];

final resources = [
  for (var i = 1; i <= 10; i++)
    {
      'id': _id('res', i),
      'club_id': clubId,
      'name': i == 7
          ? 'VIP Стол Русский бильярд №7'
          : (i > 8 ? 'PS5 Комната №${i - 8}' : 'Стол №$i'),
      'number': i,
      'zone': i > 8 ? 'PlayStation зона' : 'Бильярдный зал',
      'color': '#0ea5e9',
      'notes': null,
      'icon': null,
      'photo_url': null,
      'active': true,
      'archived_at': null,
      'status': i <= 5 ? 'BUSY' : 'FREE',
      'sort_order': i,
      'relay_channel': i,
      'relay_demo_mode': true,
      'relay_device_id': 'relay-1',
      'resource_type_id':
          i > 8 ? 'type-ps5' : (i == 7 ? 'type-vip' : 'type-pool'),
      'default_tariff_id': i > 8
          ? tariffs[2]['id']
          : (i == 7 ? tariffs[1]['id'] : tariffs[0]['id']),
      'resource_types': i > 8 ? _types[2] : (i == 7 ? _types[1] : _types[0]),
      'tariffs': i > 8 ? tariffs[2] : (i == 7 ? tariffs[1] : tariffs[0]),
      'created_at': _ago(const Duration(days: 30)),
    },
];

final loyaltyTiers = [
  {
    'id': 'tier-1',
    'club_id': clubId,
    'name': 'Новичок',
    'color': '#64748B',
    'active': true,
    'sort_order': 10,
    'earn_percent': 3,
    'min_total_spent': 0,
    'discount_percent': 0
  },
  {
    'id': 'tier-2',
    'club_id': clubId,
    'name': 'Профессионал',
    'color': '#E5B95C',
    'active': true,
    'sort_order': 20,
    'earn_percent': 5,
    'min_total_spent': 5000000,
    'discount_percent': 5
  },
  {
    'id': 'tier-3',
    'club_id': clubId,
    'name': 'Легенда клуба',
    'color': '#A855F7',
    'active': true,
    'sort_order': 30,
    'earn_percent': 10,
    'min_total_spent': 25000000,
    'discount_percent': 10
  },
];

const _names = [
  'Александр Константинопольский',
  'Дилшод Рахматуллаев',
  'Малика Абдурахмонова',
  'Азиз Каримов',
  'Сардор Мухаммадалиев',
  'Ольга Владимировна Петренко',
  'Жасур Тошпулатов',
  'Шахзод Нематжонов',
  'Нодира Юсупова',
  'Бобур Эргашев',
  'Тимур Исмаилов',
  'Камола Хасанова',
];

final customers = [
  for (var i = 0; i < _names.length; i++)
    {
      'id': _id('cus', i),
      'club_id': clubId,
      'full_name': _names[i],
      'phone': '+9989${(10000000 + i * 7654321) % 100000000}'.padRight(13, '7'),
      'telegram': null,
      'telegram_id': i.isEven ? 100000 + i : null,
      'telegram_username': null,
      'birth_date': null,
      'balance': i * 125000,
      'bonus_points': i * 13579,
      'discount_percent': i % 3 == 0 ? 10 : 0,
      'visits_count': 3 + i * 17,
      'total_spent': 1234567 * (i + 1),
      'debt_amount': i % 4 == 0 ? 2450000 : 0,
      'last_visit_at': _ago(Duration(days: i)),
      'note': i == 1 ? 'Постоянный клиент, любит VIP стол у окна' : null,
      'active': true,
      'archived_at': null,
      'tier_id': loyaltyTiers[i % 3]['id'],
      'loyalty_tiers': loyaltyTiers[i % 3],
      'card_token': _id('card', i),
      'created_at': _ago(Duration(days: 20 - i)),
    },
];

Map<String, dynamic> _order(int i,
        {String status = 'COMPLETED', String? sessionId, int? resource}) =>
    {
      'id': _id('ord', i),
      'club_id': clubId,
      'order_number': 1000 + i,
      'status': status,
      'session_id': sessionId,
      'customer_id': customers[i % customers.length]['id'],
      'time_amount': 1245000 + i * 1000,
      'items_amount': 12345000 + i * 10000,
      'total_amount': 13590000 + i * 11000,
      'paid_amount': status == 'COMPLETED' ? 13590000 + i * 11000 : 0,
      'discount_amount': i % 3 == 0 ? 1359000 : 0,
      'discount_reason': i % 3 == 0 ? 'Постоянный клиент' : null,
      'discount_applies_to': 'ALL',
      'discount_id': null,
      'deposit_amount': 0,
      'note': null,
      'cash_shift_id': 'shift-1',
      'opened_by': userId,
      'closed_by': status == 'COMPLETED' ? userId : null,
      'created_at': _ago(Duration(hours: i * 3)),
      'updated_at': _ago(Duration(hours: i * 3)),
      'closed_at':
          status == 'COMPLETED' ? _ago(Duration(hours: i * 3 - 1)) : null,
      'customers': {
        'full_name': customers[i % customers.length]['full_name'],
        'phone': customers[i % customers.length]['phone']
      },
      'game_sessions': resource == null
          ? null
          : {
              'resources': {'name': resources[resource]['name']}
            },
      'opener': {'full_name': profile['full_name']},
    };

final orders = [
  for (var i = 1; i <= 25; i++) _order(i, resource: i % 4 == 0 ? null : i % 10)
];

final activeSessions = [
  for (var i = 0; i < 5; i++)
    {
      'id': _id('ses', i),
      'club_id': clubId,
      'resource_id': resources[i]['id'],
      'status': i == 3 ? 'PAUSED' : 'ACTIVE',
      'billing_mode': i == 2 ? 'PREPAID' : 'POSTPAID',
      'customer_id': customers[i]['id'],
      'customers': {
        'id': customers[i]['id'],
        'full_name': customers[i]['full_name'],
        'phone': customers[i]['phone']
      },
      'tariff_id': resources[i]['default_tariff_id'],
      'tariff_snapshot': {
        ...resources[i]['tariffs'] as Map,
        'base_price_per_hour':
            (resources[i]['tariffs'] as Map)['price_per_hour'],
        'currency': 'UZS'
      },
      'started_at': _ago(Duration(hours: 3 + i, minutes: 47)),
      'created_at': _ago(Duration(hours: 3 + i, minutes: 47)),
      'planned_end_at': i == 2 ? _in(const Duration(minutes: 38)) : null,
      'pause_started_at': i == 3 ? _ago(const Duration(minutes: 12)) : null,
      'paused_seconds': 0,
      'banked_seconds': 0,
      'banked_time_amount': 0,
      'billable_seconds': 13620,
      'time_amount': 2345000,
      'prepaid_amount': i == 2 ? 290000 : 0,
      'discount_amount': 0,
      'discount_reason': null,
      'round_number': 1 + i,
      'players_count': 2 + i,
      'comment': null,
      'relay_ok': true,
      'expected_relay_state': 'ON',
      'order_id': _id('ord', 100 + i),
      'cash_shift_id': 'shift-1',
      'orders': [
        _order(100 + i, status: 'OPEN', sessionId: _id('ses', i), resource: i)
      ],
    },
];

final productCategories = [
  for (final (i, n) in [
    'Напитки',
    'Энергетики и газировка',
    'Снеки',
    'Кальян',
    'Горячие блюда'
  ].indexed)
    {
      'id': _id('cat', i),
      'club_id': clubId,
      'name': n,
      'color': null,
      'icon': null,
      'active': true,
      'sort_order': i * 10,
      'archived_at': null
    },
];

final products = [
  for (var i = 0; i < 18; i++)
    {
      'id': _id('prd', i),
      'club_id': clubId,
      'name': [
            'Вода 0.5л',
            'Red Bull 0.25л',
            'Coca-Cola Zero 1.5л',
            'Чипсы Lay\'s сметана и зелень 150г',
            'Кальян премиум на двоих с фруктовой чашей',
            'Шаурма куриная XXL'
          ][i % 6] +
          (i >= 6 ? ' ${i ~/ 6 + 1}' : ''),
      'unit': 'шт',
      'sku': null,
      'barcode': null,
      'image_url': null,
      'active': true,
      'archived_at': null,
      'category_id': productCategories[i % 5]['id'],
      'product_categories': productCategories[i % 5],
      'sale_price': [5000, 22000, 18000, 35000, 1250000, 65000][i % 6],
      'purchase_price': [2500, 14000, 11000, 21000, 400000, 30000][i % 6],
      'track_stock': i % 6 != 4,
      'stock_quantity': [7, 124, 3, 0, 0, 1245][i % 6],
      'minimum_stock': 12,
      'sort_order': i,
      'created_at': _ago(const Duration(days: 20)),
      'updated_at': _ago(const Duration(days: 1)),
    },
];

final reservations = [
  for (var i = 0; i < 8; i++)
    {
      'id': _id('rsv', i),
      'club_id': clubId,
      'resource_id': resources[i]['id'],
      'resources': {'name': resources[i]['name']},
      'customer_id': i.isEven ? customers[i]['id'] : null,
      'customers': i.isEven
          ? {
              'full_name': customers[i]['full_name'],
              'phone': customers[i]['phone']
            }
          : null,
      'customer_name': customers[i]['full_name'],
      'phone': customers[i]['phone'],
      'starts_at': _in(Duration(hours: i * 2 + 1)),
      'ends_at': _in(Duration(hours: i * 2 + 3)),
      'duration_minutes': 120,
      'players_count': 4,
      'prepaid_amount': i == 1 ? 1250000 : 0,
      'status': ['pending', 'confirmed', 'arrived', 'cancelled'][i % 4],
      'source': i.isEven ? 'BOT' : 'STAFF',
      'comment': i == 3 ? 'День рождения, нужен торт и украшение стола' : null,
      'session_id': null,
      'warned_at': null,
      'created_at': _ago(Duration(hours: i)),
      'created_by': null,
    },
];

final waitlist = [
  for (var i = 0; i < 3; i++)
    {
      'id': _id('wai', i),
      'club_id': clubId,
      'customer_id': customers[i]['id'],
      'customer_name': customers[i]['full_name'],
      'phone': customers[i]['phone'],
      'resource_family': i == 2 ? 'PLAYSTATION' : 'BILLIARD',
      'status': 'WAITING',
      'joined_at': _ago(Duration(minutes: 17 + i * 23)),
      'note': null,
      'waited_seconds': (17 + i * 23) * 60,
      'accrued_discount': 3000 + i * 2000,
    },
];

final shifts = [
  for (var i = 0; i < 6; i++)
    {
      'id': i == 0 ? 'shift-1' : _id('shf', i),
      'club_id': clubId,
      'status': i == 0 ? 'OPEN' : 'CLOSED',
      'opened_at': _ago(Duration(hours: 9 + i * 24)),
      'closed_at': i == 0 ? null : _ago(Duration(hours: i * 24 - 5)),
      'opened_by': userId,
      'closed_by': i == 0 ? null : userId,
      'opening_cash': 1500000,
      'expected_cash': 45678900,
      'actual_cash': i == 0 ? null : 45600000,
      'difference': i == 0 ? null : -78900,
      'totals': {},
      'note': null,
      'profiles': {'full_name': profile['full_name']},
      'created_at': _ago(Duration(hours: 9 + i * 24)),
    },
];

final shiftTotals = {
  'cash': 23456000,
  'uzcard': 12345000,
  'humo': 9876000,
  'click': 4567000,
  'payme': 3456000,
  'transfer': 1234000,
  'debt': 2450000,
  'shift_id': 'shift-1',
  'opening_cash': 1500000,
  'opened_at': shifts[0]['opened_at'],
  'opened_by_name': profile['full_name'],
  'by_payment_method': {
    'Наличные': 23456000,
    'Uzcard': 12345000,
    'Humo': 9876000,
    'Click': 4567000,
    'Payme': 3456000
  },
  'cash_in': 23456000,
  'revenue': 57384000,
  'cost': 8765000,
  'gross_profit': 48619000,
  'profit': 48619000,
  'expenses': 3450000,
  'cash_expenses': 2100000,
  'refunds': 0,
  'cash_deposits': 500000,
  'cash_withdrawals': 1000000,
  'net_profit': 45169000,
  'expected_cash': 22356000,
  'sessions_count': 47,
  'orders_count': 63,
  'calculated_at': DateTime.now().toUtc().toIso8601String(),
};

final periodReport = {
  'revenue': 157384000,
  'orders_count': 463,
  'time_playstation': 34567000,
  'time_billiard': 98765000,
  'time_playstation_gross': 35567000,
  'time_billiard_gross': 99765000,
  'time_discount': 2000000,
  'products': 24052000,
  'products_qty': 1873,
  'products_cost': 11234000,
  'bar_profit': 12818000,
  'expenses': 8450000,
  'discount_total': 4560000,
  'discount_by_reason': {
    'Постоянный клиент': 3450000,
    'Кассир играет с клиентом (50%)': 1110000
  },
  'by_payment_method': {
    'Наличные': 83456000,
    'Uzcard': 32345000,
    'Humo': 19876000,
    'Click': 14567000,
    'Payme': 7140000
  },
  'net_profit': 137700000,
};

final reportDashboard = {
  'series': [
    for (var i = 6; i >= 0; i--)
      {
        'at': DateTime.now()
            .toUtc()
            .subtract(Duration(days: i))
            .toIso8601String(),
        'revenue': 12345000 + i * 3456000,
        'orders': 40 + i * 7
      },
  ],
  'composition': [
    {'label': 'Бильярд', 'amount': 98765000},
    {'label': 'PlayStation', 'amount': 34567000},
    {'label': 'Напитки', 'amount': 12345000},
    {'label': 'Кальян', 'amount': 8765000},
    {'label': 'Снеки', 'amount': 2942000},
  ],
  'top_products': [
    for (final p in products.take(8))
      {
        'name': p['name'],
        'qty': 1234,
        'revenue': 12345000,
        'product_id': p['id']
      },
  ],
};

final expenseCategories = [
  for (final (i, n) in [
    'Закупка товара',
    'Аренда помещения',
    'Коммунальные услуги',
    'Зарплата'
  ].indexed)
    {
      'id': _id('exc', i),
      'club_id': clubId,
      'name': n,
      'icon': null,
      'active': true,
      'sort_order': i * 10,
      'archived_at': null
    },
];

final paymentMethods = [
  for (final (i, m) in [
    ('cash', 'CASH', 'Наличные'),
    ('uzcard', 'CARD', 'Uzcard'),
    ('humo', 'CARD', 'Humo'),
    ('click', 'ONLINE', 'Click'),
    ('payme', 'ONLINE', 'Payme'),
    ('transfer', 'TRANSFER', 'Перевод'),
    ('debt', 'DEBT', 'Долг'),
  ].indexed)
    {
      'id': _id('pm', i),
      'club_id': clubId,
      'key': m.$1,
      'kind': m.$2,
      'name': m.$3,
      'icon': null,
      'active': true,
      'sort_order': i * 10,
      'affects_cash_drawer': m.$1 == 'cash',
      'archived_at': null
    },
];

final expenses = [
  for (var i = 0; i < 12; i++)
    {
      'id': _id('exp', i),
      'club_id': clubId,
      'amount': [2450000, 12500000, 345000, 18000000][i % 4],
      'status': 'ACTIVE',
      'comment': i == 1 ? 'Аренда за сентябрь, основной зал и склад' : null,
      'spent_at': _ago(Duration(hours: i * 11)),
      'created_at': _ago(Duration(hours: i * 11)),
      'created_by': userId,
      'category_id': expenseCategories[i % 4]['id'],
      'expense_categories': {'name': expenseCategories[i % 4]['name']},
      'profiles': {'full_name': profile['full_name']},
      'payment_method_id': paymentMethods[0]['id'],
      'receipt_url': null,
      'cash_shift_id': 'shift-1',
      'reverses_expense_id': null,
    },
];

final payments = [
  for (var i = 0; i < 20; i++)
    {
      'id': _id('pay', i),
      'club_id': clubId,
      'order_id': orders[i]['id'],
      'amount': 1359000 + i * 1000,
      'status': 'COMPLETED',
      'created_at': _ago(Duration(hours: i * 2)),
      'created_by': userId,
      'payment_method_id': paymentMethods[i % 7]['id'],
      'cash_shift_id': 'shift-1',
      'customer_id': null,
      'payment_methods': {
        'name': paymentMethods[i % 7]['name'],
        'key': paymentMethods[i % 7]['key'],
        'kind': paymentMethods[i % 7]['kind']
      },
      'note': null,
      'reason': null,
      'external_reference': null,
      'reverses_payment_id': null,
    },
];

final zones = [
  for (final (i, n)
      in ['Бильярдный зал', 'VIP зона', 'PlayStation зона'].indexed)
    {
      'id': _id('zon', i),
      'club_id': clubId,
      'name': n,
      'active': true,
      'sort_order': i
    },
];

final discounts = [
  {
    'id': 'disc-1',
    'club_id': clubId,
    'name': 'Скидка 10%',
    'kind': 'PERCENT',
    'value': 10,
    'active': true,
    'applies_to': 'ALL',
    'max_amount': null,
    'requires_approval_above': null,
    'archived_at': null,
    'created_at': _ago(const Duration(days: 20))
  },
  {
    'id': 'disc-2',
    'club_id': clubId,
    'name': 'Кассир играет с клиентом (50% на время)',
    'kind': 'PERCENT',
    'value': 50,
    'active': true,
    'applies_to': 'TIME',
    'max_amount': null,
    'requires_approval_above': null,
    'archived_at': null,
    'created_at': _ago(const Duration(days: 19))
  },
  {
    'id': 'disc-3',
    'club_id': clubId,
    'name': 'Фиксированная 25 000',
    'kind': 'FIXED',
    'value': 25000,
    'active': false,
    'applies_to': 'ALL',
    'max_amount': null,
    'requires_approval_above': null,
    'archived_at': null,
    'created_at': _ago(const Duration(days: 18))
  },
];

final staff = [
  for (var i = 0; i < 4; i++)
    {
      'id': 'member-${i + 1}',
      'club_id': clubId,
      'user_id': _id('usr', i),
      'role_id': roles[i % 3]['id'],
      'active': i != 3,
      'employee_code': '10${i + 1}',
      'archived_at': null,
      'profiles': {
        'id': _id('usr', i),
        'full_name': _names[i + 4],
        'phone': '+998901112233'
      },
      'roles': roles[i % 3],
      'created_at': _ago(Duration(days: 30 - i)),
    },
];

final relayDevices = [
  {
    'id': 'relay-1',
    'club_id': clubId,
    'name': 'Реле зала (16 каналов)',
    'provider': 'USB_SERIAL',
    'direct_control': true,
    'configuration': {'port': 'COM3', 'channels': 16},
    'active': true,
    'created_at': _ago(const Duration(days: 20))
  },
];

final stockMovements = [
  for (var i = 0; i < 15; i++)
    {
      'id': _id('stm', i),
      'club_id': clubId,
      'product_id': products[i]['id'],
      'kind': ['SALE', 'PURCHASE', 'ADJUSTMENT'][i % 3],
      'quantity_delta': [-2, 48, -1][i % 3],
      'quantity_after': 124,
      'unit_cost': 14000,
      'note': i % 3 == 1 ? 'Поставка от ООО «Напитки Азии»' : null,
      'order_id': null,
      'created_by': userId,
      'created_at': _ago(Duration(hours: i * 5)),
      'products': {'name': products[i]['name'], 'unit': 'шт'},
      'profiles': {'full_name': profile['full_name']},
    },
];

final orderItems = [
  for (var i = 0; i < 6; i++)
    {
      'id': _id('oit', i),
      'club_id': clubId,
      'order_id': orders[0]['id'],
      'kind': i == 0 ? 'TIME' : 'PRODUCT',
      'product_id': i == 0 ? null : products[i]['id'],
      'description':
          i == 0 ? 'Время: VIP Стол Русский бильярд №7' : products[i]['name'],
      'quantity': i == 0 ? 1 : i + 1,
      'unit_price': 1245000,
      'unit_cost': 400000,
      'total_price': 12450000,
      'metadata': {},
      'created_at': _ago(const Duration(hours: 1)),
      'created_by': userId,
    },
];

final sessionRounds = [
  for (var i = 1; i <= 3; i++)
    {
      'id': _id('rnd', i),
      'club_id': clubId,
      'session_id': activeSessions[0]['id'],
      'round_number': i,
      'amount': 1245000,
      'billable_seconds': 3725,
      'note': i == 2 ? 'Смена игроков' : null,
      'started_at': _ago(Duration(hours: 4 - i)),
      'ended_at': _ago(Duration(hours: 3 - i)),
      'created_at': _ago(Duration(hours: 3 - i))
    },
];

final Map<String, Object?> _tables = {
  'club_members': [member],
  'profiles': [profile],
  'clubs': [club],
  'resources': resources,
  'resource_types': _types,
  'tariffs': tariffs,
  'game_sessions': activeSessions,
  'products': products,
  'product_categories': productCategories,
  'customers': customers,
  'loyalty_tiers': loyaltyTiers,
  'reservations': reservations,
  'orders': orders,
  'order_items': orderItems,
  'cash_shifts': shifts,
  'expenses': expenses,
  'expense_categories': expenseCategories,
  'zones': zones,
  'discounts': discounts,
  'payments': payments,
  'payment_methods': paymentMethods,
  'stock_movements': stockMovements,
  'session_rounds': sessionRounds,
};

final Map<String, Object?> _rpcs = {
  'waitlist_list': waitlist,
  'app_period_report': periodReport,
  'app_report_dashboard': reportDashboard,
  'shift_totals': shiftTotals,
  'product_sales_stats': [
    for (final p in products) {'product_id': p['id'], 'qty': 42}
  ],
  'app_admin_list_relay_devices': relayDevices,
  'app_relay_device_for_resource': {
    'channel': 1,
    'provider': 'USB_SERIAL',
    'direct_control': true,
    'configuration': {}
  },
  'club_bot_info': {
    'configured': true,
    'active': true,
    'username': 'velora_club_bot',
    'pair_code': 'AB12CD34',
    'owner_paired': true,
    'webhook_secret': 'x'
  },
  'session_current_charge': {
    'time_amount': 2345000,
    'items_amount': 12345000,
    'total_amount': 14690000,
    'billable_seconds': 13620
  },
  'app_order_json': {'order': orders[0], 'items': orderItems},
};

/// Every request the screens make, answered from the tables above. Filters
/// are ignored (the screens only ever see this one club); a request for a
/// single object (maybeSingle/single) gets the first row.
MockClient fakeSupabaseHttp({List<String>? log}) => MockClient((request) async {
      final path = request.url.path;
      log?.add('${request.method} $path');
      Object? body;
      if (path.startsWith('/rest/v1/rpc/')) {
        body = _rpcs[path.substring('/rest/v1/rpc/'.length)];
      } else if (path.startsWith('/rest/v1/')) {
        body = _tables[path.substring('/rest/v1/'.length)] ?? const [];
        final wantsObject =
            (request.headers['Accept'] ?? request.headers['accept'] ?? '')
                .contains('vnd.pgrst.object');
        if (wantsObject) body = (body as List).isEmpty ? null : body.first;
      } else {
        body = const {};
      }
      return http.Response(jsonEncode(body), 200, request: request, headers: {
        'content-type': 'application/json; charset=utf-8',
        'content-range': '0-0/*',
      });
    });
