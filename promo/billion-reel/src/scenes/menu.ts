import type { Btn, Keyboard } from "../ui/Telegram";

/** The client bot's reply keyboard (clientKeyboardFor, Uzbek). */
export const menu = (at: number, tap: Partial<Record<string, number>> = {}): Keyboard => {
  const b = (label: string): Btn => ({ label, tapAt: tap[label] });
  return {
    at,
    rows: [
      [b("🎮 Bo'sh joylar"), b("📅 Band qilish")],
      [b("⚪ Raqib topish")],
      [b("🎁 Bonuslarim"), b("👤 Ma'lumotlarim")],
      [b("🤝 Do'stni taklif qilish"), b("🌐 Til")],
    ],
  };
};

export const contactKb = (at: number, tapAt?: number): Keyboard => ({
  at,
  rows: [[{ label: "📱 Raqamni yuborish", tapAt }]],
});
