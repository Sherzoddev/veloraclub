import React from "react";
import { FeatureScene } from "../ui/Scene";
import { Parts } from "../ui/Parts";
import { Screens } from "../ui/Screens";
import { Contact, Hr, LINK, Msg, Preview, TgChat } from "../ui/Telegram";
import { contactKb, menu } from "./menu";

const TG = { at: 0, text: "Telegram bot" };
const APP = (at: number) => ({ at, text: "Mini ilova" });

// Every bot text below is the bot's own Uzbek copy (club-bot-service,
// match-notify, app_order_receipt_message) filled with BILLION's data.

export const Start: React.FC = () => (
  <FeatureScene
    step="01"
    title="Botni ishga tushiring"
    labels={[TG]}
    lines={[
      { text: "Telegramda @billionbiliard_bot ni oching va «Start» ni bosing.", from: 8, to: 150 },
      { text: "Shartlarga rozilik bering — klub menyusi darhol ochiladi.", from: 154, to: 316 },
    ]}
  >
    <TgChat keyboards={[menu(196)]}>
      <Msg at={24} from="user" time="19:40">/start</Msg>
      <Msg
        at={46}
        until={180}
        time="19:40"
        buttons={[[{ label: "✅ Roziman", tapAt: 164 }, { label: "❌ Rozi emasman" }]]}
      >
        📋 <b>Foydalanuvchi shartnomasi</b>
        {"\n\n"}Botdan foydalanishdan oldin shartlarga tanishib chiqing:{"\n\n"}• Bron qilish, mijoz kartasi va bonuslar
        uchun ismingiz, telefon raqamingiz va Telegram ID'ingiz saqlanadi.{"\n"}• Bu ma'lumotlar faqat shu klub ichida
        xizmat ko'rsatish uchun ishlatiladi va uchinchi shaxslarga berilmaydi.{"\n"}• Botdan foydalanishni davom ettirish
        shartlarga roziligingizni bildiradi.{"\n\n"}Davom etish uchun shartlarga rozimisiz?
      </Msg>
      <Msg at={192} time="19:41">
        ✨ <b>BILLION</b>
        {"\n"}
        <Hr />
        {"\n"}👋 Salom, Aziz!{"\n\n"}🎮  Bo'sh joylarni ko'rish{"\n"}📅  Joy band qilish{"\n"}🎁  Bonuslarni tekshirish{"\n"}👤
        Kartangizni ochish{"\n\n"}Quyidagi tugmalardan birini tanlang 👇
      </Msg>
    </TgChat>
  </FeatureScene>
);

export const Card: React.FC = () => (
  <FeatureScene
    step="02"
    title="Klub kartasi"
    labels={[TG]}
    lines={[
      { text: "Raqamingizni bitta tugma bilan yuboring.", from: 8, to: 150 },
      { text: "Klub kartangiz shu zahoti ochiladi — bonus har tashrifda to'planadi.", from: 154, to: 296 },
    ]}
  >
    <TgChat keyboards={[menu(0, { "🎁 Bonuslarim": 24 }), contactKb(62, 128), menu(172)]}>
      <Msg at={34} from="user">🎁 Bonuslarim</Msg>
      <Msg at={58}>Bonus to'plash uchun raqamingizni yuboring — shunda kassir sizni kassada taniydi.</Msg>
      <Contact at={140} name="Aziz" phone="+998 90 ••• •• ••" />
      <Msg at={168}>✅ Rahmat! Karta ochildi — har tashrifda bonus to'planadi.</Msg>
    </TgChat>
  </FeatureScene>
);

export const Tables: React.FC = () => (
  <FeatureScene
    step="03"
    title="Bo'sh stollar"
    labels={[TG, APP(210)]}
    lines={[
      { text: "«Bo'sh joylar» — qaysi stol bo'shligi va narxi bir qarashda.", from: 8, to: 200 },
      { text: "Ilovada ham barcha stollar holati bilan ko'rinadi.", from: 214, to: 386 },
    ]}
  >
    <Parts
      parts={[
        {
          from: 0,
          node: (
            <TgChat keyboards={[menu(0, { "🎮 Bo'sh joylar": 24 })]}>
              <Msg at={34} from="user">🎮 Bo'sh joylar</Msg>
              <Msg at={58}>
                🎮 <b>Klub joylari</b> · bo'sh 3/3{"\n"}
                <Hr />
                {"\n"}🟢 ⚪ <b>1 Stol</b> — 60 000 сум/soat{"\n"}🟢 ⚪ <b>2 Stol</b> — 60 000 сум/soat{"\n"}🟢 ⚪{" "}
                <b>3 Stol</b> — 60 000 сум/soat
              </Msg>
            </TgChat>
          ),
        },
        { from: 210, node: <Screens steps={[{ src: "02_tables", at: 0 }]} taps={[{ x: 195, y: 168, at: 150 }]} /> },
      ]}
    />
  </FeatureScene>
);

export const Booking: React.FC = () => (
  <FeatureScene
    step="04"
    title="Stolni band qilish"
    labels={[TG, APP(290)]}
    lines={[
      { text: "«Band qilish» — avval stolni tanlang…", from: 8, to: 140 },
      { text: "…so'ng o'zingizga qulay vaqtni belgilang.", from: 144, to: 286 },
      { text: "Ilovada kun va davomiylikni ham tanlash mumkin.", from: 294, to: 440 },
      { text: "Bron tasdiqlandi — stol sizni kutib turadi!", from: 444, to: 586 },
    ]}
  >
    <Parts
      parts={[
        {
          from: 0,
          node: (
            <TgChat keyboards={[menu(0, { "📅 Band qilish": 24 })]}>
              <Msg at={34} from="user">📅 Band qilish</Msg>
              <Msg
                at={58}
                buttons={[
                  [{ label: "🟢 1 Stol · 60 000 сум/soat", tapAt: 138 }],
                  [{ label: "🟢 2 Stol · 60 000 сум/soat" }],
                  [{ label: "🟢 3 Stol · 60 000 сум/soat" }],
                ]}
              >
                🎮 <b>Qaysi joyni band qilamiz?</b>
                {"\n"}Band joyni kutib turmang — darhol navbatga turing, bo'sh joylarni esa boshqa vaqtga band qilsa
                bo'ladi.
              </Msg>
              <Msg
                at={158}
                buttons={[
                  [{ label: "16:00" }, { label: "17:00" }, { label: "18:00" }],
                  [{ label: "19:00" }, { label: "20:00", tapAt: 246 }, { label: "21:00" }],
                  [{ label: "Boshqa vaqt" }],
                ]}
              >
                <b>Qaysi vaqtga?</b>
              </Msg>
            </TgChat>
          ),
        },
        {
          from: 290,
          node: (
            <Screens
              steps={[
                { src: "03_booking", at: 0, slide: true },
                { src: "04_booking_selected", at: 80 },
                { src: "05_booking_success", at: 176 },
              ]}
              taps={[
                { x: 195, y: 564, at: 56 },
                { x: 195, y: 603, at: 118 },
                { x: 195, y: 815, at: 162 },
              ]}
            />
          ),
        },
      ]}
    />
  </FeatureScene>
);

export const Bonus: React.FC = () => (
  <FeatureScene
    step="05"
    title="Bonuslar va darajalar"
    labels={[TG, APP(270)]}
    lines={[
      { text: "«Bonuslarim» — darajangiz, bonuslar va tashriflar soni.", from: 8, to: 136 },
      { text: "Har darajada keshbek oshadi: 3% dan 10% gacha.", from: 140, to: 266 },
      { text: "Ilovada — kartangiz va keyingi darajagacha qolgan summa.", from: 274, to: 436 },
    ]}
  >
    <Parts
      parts={[
        {
          from: 0,
          node: (
            <TgChat keyboards={[menu(0, { "🎁 Bonuslarim": 24 })]}>
              <Msg at={34} from="user">🎁 Bonuslarim</Msg>
              <Msg at={58}>
                🎁 <b>Aziz</b>
                {"\n"}
                <Hr />
                {"\n\n"}🏅 Holat: <b>Золото</b>
                {"\n"}   keshbek 7%{"\n\n"}🪙 Bonuslar: <b>48 500</b>
                {"\n"}📅 Tashriflar: 23{"\n\n"}✨ Darajagacha «Платина»: <b>2 260 000 сум</b>
                {"\n\n"}
                <Hr />
                {"\n\n"}📊 <b>Klub darajalari</b>
                {"\n\n"}🥉 <b>Новичок</b>
                {"\n"}   dan 0 сум · keshbek 3%{"\n\n"}🥈 <b>Серебро</b>
                {"\n"}   dan 500 000 сум · keshbek 5%{"\n\n"}🥇 <b>Золото</b>  ⬅️ sizning darajangiz{"\n"}   dan 2 000 000
                сум · keshbek 7%{"\n\n"}💎 <b>Платина</b>
                {"\n"}   dan 5 000 000 сум · keshbek 10%
              </Msg>
            </TgChat>
          ),
        },
        {
          from: 270,
          node: (
            <Screens
              steps={[
                { src: "01_home", at: 0 },
                { src: "06_card", at: 60, slide: true },
                { src: "07_card_levels", at: 120 },
              ]}
            />
          ),
        },
      ]}
    />
  </FeatureScene>
);

export const Match: React.FC = () => (
  <FeatureScene
    step="06"
    title="Raqib topish"
    labels={[TG, APP(470)]}
    lines={[
      { text: "Sherik yo'qmi? «Raqib topish» ni bosing.", from: 8, to: 130 },
      { text: "Vaqt va darajani tanlang — so'rov klubning barcha o'yinchilariga boradi.", from: 134, to: 300 },
      { text: "Kim birinchi «O'ynayman!» ni bossa — o'sha siz bilan o'ynaydi.", from: 304, to: 466 },
      { text: "Ilovada — so'rovlar ro'yxati va raqib bilan yozishma.", from: 474, to: 646 },
    ]}
  >
    <Parts
      parts={[
        {
          from: 0,
          node: (
            <TgChat keyboards={[menu(0, { "⚪ Raqib topish": 24 })]}>
              <Msg at={34} from="user">⚪ Raqib topish</Msg>
              <Msg
                at={58}
                buttons={[[{ label: "➕ So'rov yaratish", tapAt: 128 }], [{ label: "📱 Ilovada ochish" }]]}
              >
                ⚪ <b>Raqib topish</b>
                {"\n"}
                <Hr />
                {"\n\n"}Hozir hech kim o'yin qidirmayapti. So'rov yarating — uni klubning barcha o'yinchilari ko'radi.
              </Msg>
              <Msg
                at={146}
                buttons={[
                  [{ label: "⚡ Hozir" }],
                  [{ label: "16:00" }, { label: "17:00" }, { label: "18:00" }],
                  [{ label: "19:00" }, { label: "20:00", tapAt: 206 }, { label: "21:00" }],
                ]}
              >
                🕗 <b>Qachon o'ynaymiz?</b>
              </Msg>
              <Msg
                at={222}
                buttons={[[{ label: "🟢 Boshlovchi" }, { label: "🟡 O'rta", tapAt: 270 }, { label: "🔴 Professional" }]]}
              >
                🎯 <b>O'yin darajangiz?</b>
              </Msg>
              <Msg at={284}>⏳ So'rovni e'lon qilyapmiz…</Msg>
              <Msg
                at={312}
                buttons={[[{ label: "❌ So'rovni bekor qilish" }], [{ label: "📱 Ilovada ochish" }]]}
              >
                📣 <b>So'rov e'lon qilindi!</b>
                {"\n\n"}🕗 bugun 20:00 · 🟡 O'rta{"\n"}Uni klubning 16 o'yinchisi ko'rdi. Kimdir «O'ynayman!» ni bosishi
                bilan xabar beraman.
              </Msg>
              <Msg
                at={384}
                buttons={[[{ label: "💬 Raqibga yozish" }], [{ label: "❌ O'yinni bekor qilish" }]]}
              >
                🎉 <b>Raqib topildi!</b>
                {"\n\n"}👤 <b>Sardor</b> · 14 ta tashrif{"\n"}🕗 bugun 20:00{"\n\n"}Tafsilotlarni kelishib oling —
                yozishmalar bot orqali, Telegramingiz hech kimga ko'rinmaydi.
              </Msg>
            </TgChat>
          ),
        },
        {
          from: 470,
          node: (
            <Screens
              steps={[
                { src: "09_match_board", at: 0, slide: true },
                { src: "10_match_found", at: 96 },
              ]}
              taps={[{ x: 305, y: 610, at: 82 }]}
            />
          ),
        },
      ]}
    />
  </FeatureScene>
);

export const Chat: React.FC = () => (
  <FeatureScene
    step="07"
    title="Klub bilan chat"
    labels={[TG, APP(330)]}
    lines={[
      { text: "Administrator javobi Telegramga keladi…", from: 8, to: 140 },
      { text: "…«Javob berish» ni bosing va shu yerning o'zida yozing.", from: 144, to: 326 },
      { text: "Butun yozishma ilovada saqlanib qoladi.", from: 334, to: 466 },
    ]}
  >
    <Parts
      parts={[
        {
          from: 0,
          node: (
            <TgChat keyboards={[menu(0)]}>
              <Msg at={20} time="18:03" buttons={[[{ label: "↩️ Javob berish", tapAt: 118 }, { label: "💬 Chatni ochish" }]]}>
                💬 <b>BILLION</b>
                {"\n\n"}Assalomu alaykum! Ha, bo'sh 👍 Band qilib qo'yaymi?
              </Msg>
              <Msg at={132} time="18:03">✍️ Klubga xabar yozing.</Msg>
              <Msg at={186} from="user" time="18:04">Ha, iltimos 🙏</Msg>
              <Msg at={206} time="18:04">✅ Klubga yuborildi — javob shu yerga keladi.</Msg>
              <Msg at={262} time="18:05" buttons={[[{ label: "↩️ Javob berish" }, { label: "💬 Chatni ochish", tapAt: 316 }]]}>
                💬 <b>BILLION</b>
                {"\n\n"}Tayyor! Sizni 21:00 da kutamiz ⚪
              </Msg>
            </TgChat>
          ),
        },
        { from: 330, node: <Screens steps={[{ src: "11_chat", at: 0, slide: true }]} /> },
      ]}
    />
  </FeatureScene>
);

export const Referral: React.FC = () => (
  <FeatureScene
    step="08"
    title="Do'stni taklif qiling"
    labels={[TG, APP(210)]}
    lines={[
      { text: "Do'stingizga shaxsiy havolangizni yuboring…", from: 8, to: 206 },
      { text: "…yoki QR-kodni ko'rsating. Uning birinchi chekidan 10% sizga!", from: 214, to: 376 },
    ]}
  >
    <Parts
      parts={[
        {
          from: 0,
          node: (
            <TgChat keyboards={[menu(0, { "🤝 Do'stni taklif qilish": 24 })]}>
              <Msg at={34} from="user">🤝 Do'stni taklif qilish</Msg>
              <Msg at={58} buttons={[[{ label: "📨 Do'stga yuborish", tapAt: 180 }]]}>
                🤝 <b>Do'stingizni taklif qiling — 10% oling</b>
                {"\n"}
                <Hr />
                {"\n"}Do'stingiz havola orqali botga kiradi, klubga keladi va kassada kartasini ko'rsatadi. Birinchi chek
                to'langach sizga bir marta 10% yoziladi.{"\n\n"}Takliflar: <b>3</b> · bonus: <b>36 000</b>
                {"\n\n"}
                <span style={{ color: LINK, textDecoration: "underline" }}>
                  https://t.me/billionbiliard_bot?start=ref_7f3a9c21-5b8e-4d10-a2c4-6e9b1d0f8a73
                </span>
                <Preview />
              </Msg>
            </TgChat>
          ),
        },
        { from: 210, node: <Screens steps={[{ src: "08_referral", at: 0, slide: true }]} /> },
      ]}
    />
  </FeatureScene>
);

export const Receipt: React.FC = () => (
  <FeatureScene
    step="09"
    title="Chek va baho"
    labels={[TG]}
    lines={[
      { text: "O'yindan so'ng chek darhol Telegramga keladi.", from: 8, to: 150 },
      { text: "Bonus avtomatik yoziladi — klubni baholashni unutmang!", from: 154, to: 316 },
    ]}
  >
    <TgChat keyboards={[menu(0)]}>
      <Msg
        at={24}
        time="22:04"
        buttons={[[{ label: "1⭐" }, { label: "2⭐" }, { label: "3⭐" }, { label: "4⭐" }, { label: "5⭐", tapAt: 190 }]]}
        markups={[{ at: 204, rows: [[{ label: "⭐⭐⭐⭐⭐" }]] }]}
      >
        🧾 <b>Chek №1284</b> · BILLION{"\n"}25.09.2026 22:04{"\n"}
        <Hr />
        {"\n"}⚪ 1 Stol · 2 soat 0 daq — 120 000 so'm{"\n"}
        <Hr />
        {"\n"}💰 <b>Jami: 120 000 so'm</b>
        {"\n"}💳 To'lov: Наличные{"\n"}🪙 Bonus: +8 400 · balans: 56 900{"\n\n"}Tashrif sizga yoqdimi? Baholang 👇
      </Msg>
      <Msg at={216} time="22:05">Baho uchun rahmat! Sizni yana kutamiz ⚪</Msg>
    </TgChat>
  </FeatureScene>
);

export const Club: React.FC = () => (
  <FeatureScene
    step="10"
    title="Klub haqida"
    labels={[APP(0)]}
    lines={[{ text: "Manzil, ish vaqti va telefon — hammasi ilovada.", from: 8, to: 170 }]}
  >
    <Screens steps={[{ src: "12_club", at: 0 }]} />
  </FeatureScene>
);
