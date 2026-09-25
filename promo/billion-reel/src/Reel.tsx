import React from "react";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { Intro } from "./scenes/Intro";
import { Start, Card, Tables, Booking, Bonus, Match, Chat, Referral, Receipt, Club } from "./scenes/Features";
import { Outro } from "./scenes/Outro";

export const SCENES: { id: string; component: React.FC; durationInFrames: number }[] = [
  { id: "Intro", component: Intro, durationInFrames: 160 },
  { id: "Start", component: Start, durationInFrames: 330 },
  { id: "Card", component: Card, durationInFrames: 310 },
  { id: "Tables", component: Tables, durationInFrames: 400 },
  { id: "Booking", component: Booking, durationInFrames: 600 },
  { id: "Bonus", component: Bonus, durationInFrames: 450 },
  { id: "Match", component: Match, durationInFrames: 660 },
  { id: "Chat", component: Chat, durationInFrames: 480 },
  { id: "Referral", component: Referral, durationInFrames: 390 },
  { id: "Receipt", component: Receipt, durationInFrames: 330 },
  { id: "Club", component: Club, durationInFrames: 185 },
  { id: "Outro", component: Outro, durationInFrames: 200 },
];

export const TRANSITION = 20;
export const REEL_DURATION =
  SCENES.reduce((s, x) => s + x.durationInFrames, 0) - TRANSITION * (SCENES.length - 1);

export const Reel: React.FC = () => (
  <TransitionSeries>
    {SCENES.flatMap((s, i) => {
      const seq = (
        <TransitionSeries.Sequence key={s.id} name={s.id} durationInFrames={s.durationInFrames}>
          <s.component />
        </TransitionSeries.Sequence>
      );
      if (i === 0) return [seq];
      return [
        <TransitionSeries.Transition
          key={`${s.id}-t`}
          presentation={fade()}
          timing={linearTiming({ durationInFrames: TRANSITION })}
        />,
        seq,
      ];
    })}
  </TransitionSeries>
);
