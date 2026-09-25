import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The whole app was written with hardcoded Uzbek strings as the literal
/// source text -- no translation keys anywhere. Rather than restructure
/// every widget's text into a separate key system, `tr()` maps each of
/// those literal Uzbek phrases straight to Russian: call `tr('Bekor
/// qilish')` wherever a bare string used to sit. When the locale is
/// Uzbek, or a phrase has no entry yet, it just returns the original text
/// unchanged -- so an untranslated string never breaks, it just stays
/// Uzbek until someone adds it to the map below.
class LocaleController extends ChangeNotifier {
  LocaleController._();
  static final instance = LocaleController._();

  static const _prefsKey = 'app_locale';
  String _locale = 'uz';
  String get locale => _locale;
  bool get isRu => _locale == 'ru';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _locale = prefs.getString(_prefsKey) == 'ru' ? 'ru' : 'uz';
    notifyListeners();
  }

  Future<void> toggle() async {
    _locale = _locale == 'uz' ? 'ru' : 'uz';
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, _locale);
  }
}

String tr(String uz) {
  if (!LocaleController.instance.isRu) return uz;
  return _ru[uz] ?? uz;
}

const Map<String, String> _ru = {
  // Sidebar navigation
  'Menyu': 'Меню',
  // Product categories
  'Toifalar': 'Категории',
  'Toifasiz': 'Без категории',
  'Toifa qo\'shish': 'Добавить категорию',
  'Hali toifa yo\'q': 'Категорий пока нет',
  'Yuqoriga': 'Выше',
  'Pastga': 'Ниже',
  'Yangi toifa': 'Новая категория',
  'Toifani tahrirlash': 'Изменить категорию',
  'Rang': 'Цвет',
  'Toifani o\'chirish': 'Удалить категорию',
  'Toifadagi tovarlar o\'chmaydi — ular «Toifasiz» bo\'limiga o\'tadi.':
      'Товары не удалятся — они перейдут в раздел «Без категории».',
  'Klub': 'Клуб',
  'Sotuvlar': 'Продажи',
  'Bronlar': 'Брони',
  'Navbat': 'Очередь',
  'Mijozlar': 'Клиенты',
  'Cheklar': 'Чеки',
  'Smena': 'Смена',
  'Tovarlar': 'Товары',
  'Xarajatlar': 'Расходы',
  'Hisobotlar': 'Отчёты',
  'Rele': 'Реле',
  'Xodimlar': 'Сотрудники',
  'Sozlamalar': 'Настройки',

  // Top bar
  'Onlayn': 'Онлайн',
  'Oflayn': 'Офлайн',
  'Mavzu': 'Тема',
  'Printer sozlamalari': 'Настройки принтера',
  'Chiqish': 'Выйти',

  // Common dialog buttons/labels
  'Bekor qilish': 'Отмена',
  'Saqlash': 'Сохранить',
  'Yopish': 'Закрыть',
  "O'chirish": 'Удалить',
  'Ochish': 'Открыть',
  'Ha': 'Да',
  "Yo'q": 'Нет',
  'Tasdiqlash': 'Подтвердить',
  'Qayta urinish': 'Повторить',
  'Qo\'shish': 'Добавить',
  'Tahrirlash': 'Изменить',
  'Yangilash': 'Обновить',
  'Ism': 'Имя',
  'Mijoz ismi': 'Имя клиента',
  'Telefon': 'Телефон',
  'Summa': 'Сумма',
  'Sana': 'Дата',
  'Vaqt': 'Время',
  'Izoh': 'Комментарий',
  'Qidiruv': 'Поиск',
  'Holat': 'Статус',
  'Manzil': 'Адрес',

  // Klub / resources
  'Zal xaritasi': 'Карта зала',
  'ta band': 'занято из',
  'Barchasi': 'Все',
  'Bilyard': 'Бильярд',
  "Bo'sh": 'Свободен',
  "O'yin bormoqda": 'Идёт игра',
  'soat': 'час',
  "so'm/soat": 'сум/час',
  "so'm": 'сум',
  'Joylar topilmadi': 'Места не найдены',
  "Sozlamalarda yangi joy qo'shing": 'Добавьте новое место в настройках',
  'PAUZA': 'ПАУЗА',
  "O'YIN BORMOQDA": 'ИДЁТ ИГРА',
  'Davom': 'Продолжить',
  'Davom ettirish': 'Продолжить',
  'Pauza': 'Пауза',
  'Raund': 'Раунд',
  'YANGILANMOQDA': 'ОБНОВЛЯЕТСЯ',
  'Stol band': 'Стол занят',
  'Faol seans yuklanmoqda': 'Загрузка активного сеанса',
  "BO'SH": 'СВОБОДЕН',
  'Bron': 'Бронь',
  "Stol band. Ma'lumot yangilanmoqda": 'Стол занят. Данные обновляются',
  'Vaqt tugadi': 'Время вышло',
  'Yakunlash': 'Завершить',
  "Qo'shimcha vaqt": 'Дополнительное время',
  "Qo'shimcha summa": 'Доп. сумма',
  'Yangi raund': 'Новый раунд',
  'Izoh (ixtiyoriy)': 'Комментарий (необязательно)',
  "Masalan, kim to'laydi — chekda ko'rinadi":
      'Например, кто платит — будет видно в чеке',
  'Mijoz': 'Клиент',
  'Mijozsiz': 'Без клиента',
  'Tarif': 'Тариф',
  "To'lov summasi bo'yicha vaqt (ixtiyoriy)":
      'Время по сумме оплаты (необязательно)',
  "Summa — bo'sh qoldirsangiz cheklanmagan":
      'Сумма — оставьте пустым для неограниченного времени',
  'daqiqa': 'минут',
  'Boshlash': 'Начать',
  'Seans boshlandi': 'Сеанс начат',
  'Vaqt uchun': 'За время',
  'Bar uchun': 'За бар',
  "Tovar qo'shish": 'Добавить товар',
  "Boshqa joyga ko'chirish": 'Перенести в другое место',
  "Yakunlash va to'lash": 'Завершить и оплатить',
  'Seansni bekor qilish': 'Отмена сеанса',
  "Seans bekor qilinadi, hisob yopiladi. Bu amalni qaytarib bo'lmaydi.":
      'Сеанс будет отменён, счёт закрыт. Это действие необратимо.',
  "Bo'sh joy topilmadi": 'Свободное место не найдено',
  "Qaysi joyga ko'chiramiz?": 'В какое место перенести?',
  "Ko'chirildi": 'Перенесено',

  // Sotuv (sales)
  'Smena yopiq': 'Смена закрыта',
  'Savdoni boshlash uchun avval smenani oching':
      'Откройте смену, чтобы начать продажу',
  "Smenaga o'tish": 'Перейти к смене',
  'Sotuv': 'Продажа',
  'Shtrix-kodni skanerlang': 'Отсканируйте штрих-код',
  'Tovar qidirish...': 'Поиск товара...',
  'Savat': 'Корзина',
  'Tozalash': 'Очистить',
  "Chek bo'sh": 'Чек пуст',
  'Chekka qo\'shish uchun tovar tanlang':
      'Выберите товар, чтобы добавить в чек',
  'Chegirma': 'Скидка',
  'Oraliq summa': 'Промежуточная сумма',
  'Jami': 'Итого',
  "To'lash": 'Оплатить',
  "Tovar qoldig'i yetarli emas": 'Недостаточно товара на складе',
  'Tovar topilmadi': 'Товар не найден',

  // Bronlar (reservations)
  'Yangi bron': 'Новая бронь',
  "Bronlar yo'q": 'Броней нет',
  'Yangi bron yaratishingiz mumkin': 'Вы можете создать новую бронь',
  'Joy': 'Место',
  "o'yinchi": 'игрок(ов)',

  // Mijozlar (customers)
  'Klub mijozlari va sodiqlik dasturi': 'Клиенты клуба и программа лояльности',
  'Sodiqlik': 'Лояльность',
  'Yangi mijoz': 'Новый клиент',
  'Ism, telefon — yoki mijoz kartasini skaner qiling':
      'Имя, телефон — или отсканируйте карту клиента',
  'chegirma': 'скидка',
  'ta tashrif': 'посещений',
  'ball': 'баллов',
  'Ismi': 'Имя',
  'Balans': 'Баланс',
  'Bonuslar': 'Бонусы',
  'Qarz': 'Долг',
  'Jami sarflangan': 'Всего потрачено',
  'Tashriflar': 'Посещения',
  'Buyurtmalar tarixi': 'История заказов',
  'buyurtmalar': 'заказы',
  "Buyurtmalar yo'q": 'Заказов нет',
  'Chek': 'Чек',
  "Bonuslarni o'zgartirish": 'Изменить бонусы',
  'Miqdor (+ yoki -)': 'Количество (+ или -)',
  'Foiz': 'Процент',
  'Sodiqlik dasturi': 'Программа лояльности',
  'Darajasiz mijozlar uchun bonus %': 'Бонус % для клиентов без уровня',
  "Darajasi bo'lmagan mijozlar uchun": 'Для клиентов без уровня',
  'Tashrif uchun bonus': 'Бонус за посещение',
  "Kuniga 1 marta, 0 — o'chirilgan": '1 раз в день, 0 — отключено',
  'Darajalar': 'Уровни',
  'Daraja': 'Уровень',
  "Mijoz sotib olishlar summasiga qarab o'zi mos keladigan eng yuqori darajaga tushadi.":
      'Клиент автоматически попадает на наивысший подходящий уровень по сумме покупок.',
  'Darajalar qayta hisoblandi': 'Уровни пересчитаны',
  'Mijozlar darajasini qayta hisoblash': 'Пересчитать уровни клиентов',
  'Yangi daraja': 'Новый уровень',
  'Darajani tahrirlash': 'Изменить уровень',
  'Nomi': 'Название',
  "Boshlang'ich summa (so'm)": 'Начальная сумма (сум)',
  'Bonus %': 'Бонус %',
  'Chegirma %': 'Скидка %',
  'bonus': 'бонус',
  'Eng yuqori daraja': 'Наивысший уровень',

  // Smena (shift)
  'Savdoni boshlash uchun smenani oching':
      'Откройте смену, чтобы начать продажу',
  'Smenani ochish': 'Открыть смену',
  'Kassir': 'Кассир',
  'Ochilgan': 'Открыта',
  'Smena boshidagi summa': 'Сумма на начало смены',
  'Buyurtmalar': 'Заказы',
  'Tushum': 'Выручка',
  'Tannarx': 'Себестоимость',
  'Foyda': 'Прибыль',
  'Sof foyda': 'Чистая прибыль',
  "Kassada bo'lishi kerak": 'Должно быть в кассе',
  'Ish kuni': 'Рабочий день',
  'Yopilgan': 'Закрыта',
  'Smena davom etmoqda': 'Смена ещё не закрыта',
  'Smena ochilmagan': 'Смена не открывалась',
  'Topshirildi': 'Сдано',
  'Kamomad': 'Недостача',
  'Ortiqcha': 'Излишек',
  'Kiritish': 'Внести',
  'Chiqarish': 'Изъять',
  'X-hisobotni chop etish': 'Распечатать X-отчёт',
  'Smenani yopish': 'Закрыть смену',
  'Printer sozlanmagan — Sozlamalar → Chek':
      'Принтер не настроен — Настройки → Чек',
  'Hisobot chop etildi': 'Отчёт распечатан',
  "Boshlang'ich naqd pul": 'Начальные наличные',
  'Kassaga kiritish': 'Внести в кассу',
  'Kassadan chiqarish': 'Изъять из кассы',
  'Haqiqiy naqd pul': 'Фактические наличные',

  // Navbat (waitlist)
  'Navbatga': 'В очередь',
  "Navbat bo'sh": 'Очередь пуста',
  "Hozir kutayotgan mijoz yo'q": 'Сейчас нет ожидающих клиентов',
  'kutmoqda': 'ждёт',
  "Chegirma to'plandi": 'Накоплена скидка',
  "O'tqazish": 'Посадить',
  "Navbatga qo'shish": 'Добавить в очередь',
  'Joy tanlang': 'Выберите место',

  // Cheklar (orders)
  'Yopilgan va ochiq cheklar': 'Закрытые и открытые чеки',
  'Chek raqami, stol yoki mijoz': 'Номер чека, стол или клиент',
  'Bar': 'Бар',
  'Ochiq': 'Открыт',
  'Bekor qilingan': 'Отменён',
  'Chek (ochiq)': 'Чек (открыт)',
  'Seans': 'Сеанс',
  'raund': 'раунд',
  'Chop etish': 'Распечатать',
  'Buyurtmani bekor qilish': 'Отмена заказа',
  "Buyurtma bekor qilinadi, tovarlar ombor qoldig'iga qaytariladi. Bu amalni qaytarib bo'lmaydi.":
      'Заказ будет отменён, товары вернутся на склад. Это действие необратимо.',
  'Buyurtma bekor qilindi': 'Заказ отменён',
  'Chek chop etildi': 'Чек распечатан',

  // Hisobotlar (reports dashboard)
  'SMENA TUSHUMI': 'ВЫРУЧКА СМЕНЫ',
  "O'RTACHA CHEK": 'СРЕДНИЙ ЧЕК',
  "KASSADA BO'LISHI KERAK": 'ДОЛЖНО БЫТЬ В КАССЕ',
  'Bugun': 'Сегодня',
  'Hafta': 'Неделя',
  'Oy': 'Месяц',
  'Yil': 'Год',
  'TUSHUM': 'ВЫРУЧКА',
  'FOYDA': 'ПРИБЫЛЬ',
  'BUYURTMALAR': 'ЗАКАЗЫ',
  'SOTILGAN TOVARLAR': 'ПРОДАНО ТОВАРОВ',
  "O'rtacha chek": 'Средний чек',
  "Kunlar bo'yicha tushum": 'Выручка по дням',
  "Soatlar bo'yicha tushum": 'Выручка по часам',
  "Oylar bo'yicha tushum": 'Выручка по месяцам',
  'Sotuvlar tarkibi': 'Структура продаж',
  'Skladdagi qoldiq': 'Остатки на складе',
  "Skladga o'tish": 'Перейти на склад',
  'Buyurtmalar soni': 'Количество заказов',
  "Tushum bo'yicha eng yaxshi tovarlar": 'Лучшие товары по выручке',
  'dona': 'шт',
  "Ma'lumot yo'q": 'Нет данных',
  'Vaqt tushumi': 'Выручка за время',
  'Bar foydasi': 'Прибыль бара',
  'Hozirgi bandlik': 'Текущая загрузка',
  'Kategoriyasiz': 'Без категории',
  'Boshqa': 'Другое',
  'band': 'занято',

  // Sozlamalar → Token (switching clubs)
  'Boshqa muassasaga ulash': 'Подключить другой клуб',
  "Muassasa kodini ta'minotchi o'z botida beradi. Kiritilgan kod qaysi klubga tegishli bo'lsa, dastur o'sha klubni ochadi.":
      'Код заведения выдаёт поставщик в своём боте. Программа откроет тот клуб, к которому привязан введённый код.',
  'Muassasa kodi (64 belgi)': 'Код заведения (64 символа)',
  "Kodni to'liq joylashtiring": 'Вставьте код полностью',
  'Ulash': 'Подключить',
  "Ulangandan so'ng dastur hisobdan chiqadi va yangi muassasa xodimining PIN-kodini so'raydi.":
      'После подключения программа выйдет из аккаунта и попросит PIN-код сотрудника нового клуба.',
  'Klubdan chiqish': 'Выйти из клуба',
  "Dastur bu qurilmadagi muassasa kodini unutadi va hisobdan chiqadi. Keyingi kirishda kod so'raladi — qaysi klubning kodini kiritsangiz, o'sha klub ochiladi.":
      'Программа забудет код заведения на этом устройстве и выйдет из аккаунта. При следующем входе она попросит код — откроется тот клуб, чей код вы введёте.',
  'Davom etish': 'Продолжить',
  'Qurilma yangi muassasaga ulanadi va dastur hisobdan chiqadi. Keyin yangi muassasa xodimining PIN-kodi bilan kirasiz.':
      'Устройство подключится к новому клубу, и программа выйдет из аккаунта. Затем войдите PIN-кодом сотрудника нового клуба.',

  // Auth / errors
  "Klubni ochib bo'lmadi": 'Не удалось открыть клуб',

  // Login
  'Kirish': 'Вход',
  'Parol': 'Пароль',
};
