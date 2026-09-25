import "./index.css";
import React from "react";
import { Composition, Folder } from "remotion";
import { Reel, REEL_DURATION, SCENES } from "./Reel";

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
    <Composition id="VeloraReel" component={Reel} width={1080} height={1920} fps={30} durationInFrames={REEL_DURATION} />
  </>
);
