import "./index.css";
import React from "react";
import { Composition, Folder } from "remotion";
import { Reel, REEL_DURATION, SCENES } from "./Reel";
import { PromoFilm } from "./cinema/Film";
import { M, PromoMotion } from "./motion/Motion";
import { B, PromoBright } from "./bright/Bright";
import { CB, PromoCalm } from "./calm/Calm";

export const RemotionRoot: React.FC = () => (
  <>
    <Folder name="Scenes">
      {SCENES.map((s) => (
        <Composition
          key={s.id}
          id={s.id}
          component={s.component}
          width={1080}
          height={1920}
          fps={30}
          durationInFrames={s.durationInFrames}
        />
      ))}
    </Folder>
    <Composition id="PromoFilm" component={PromoFilm} width={1080} height={1920} fps={30} durationInFrames={1110} />
    <Composition id="PromoFilmClean" component={PromoFilm} defaultProps={{ subtitles: false }} width={1080} height={1920} fps={30} durationInFrames={1110} />
    <Composition id="PromoMotion" component={PromoMotion} width={1080} height={1920} fps={30} durationInFrames={M.LENGTH} />
    <Composition id="PromoBright" component={PromoBright} width={1080} height={1920} fps={30} durationInFrames={B.LENGTH} />
    <Composition id="PromoCalm" component={PromoCalm} width={1080} height={1920} fps={30} durationInFrames={CB.LENGTH} />
    <Composition
      id="VeloraReel"
      component={Reel}
      width={1080}
      height={1920}
      fps={30}
      durationInFrames={REEL_DURATION}
    />
    <Composition
      id="VeloraReelClean"
      component={Reel}
      defaultProps={{ subtitles: false }}
      width={1080}
      height={1920}
      fps={30}
      durationInFrames={REEL_DURATION}
    />
  </>
);
