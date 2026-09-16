import { Capacitor, registerPlugin } from '@capacitor/core';

export type ZoneState = 'outside' | 'partial' | 'inside';

export type ZoneStatus = {
  state: ZoneState;
  percent: number;
  position: {
    x: number;
    y: number;
    z: number;
  };
  trackingQuality: 'notAvailable' | 'limited' | 'normal';
  lidarAvailable: boolean;
};

export type MappingStatus = 'notAvailable' | 'limited' | 'extending' | 'mapped';

export type TrackingStatus = {
  trackingQuality: 'notAvailable' | 'limited' | 'normal';
  lidarAvailable: boolean;
  surfaceDetected: boolean;
  /** Quanto ARKit ha mappato l'ambiente: sotto 'extending' l'ancoraggio deriva. */
  mappingStatus: MappingStatus;
  /** Numero di blocchi di mesh LiDAR ricostruiti finora. */
  meshAnchors: number;
  /** true quando l'anteprima sta agganciando una superficie: solo allora il
   *  posizionamento ha senso, perche conferma esattamente cio che si vede. */
  previewReady: boolean;
};

export type ZoneError = {
  message: string;
};

export type ARZoneNativePlugin = {
  isSupported(): Promise<{ supported: boolean; lidarAvailable: boolean }>;
  /** Dimensioni in METRI: è l'unità di ARKit. La UI lavora in centimetri
   *  e converte qui al confine (vedi ZONE_CM in App.tsx). */
  startSession(options: {
    width: number;
    depth: number;
    height: number;
  }): Promise<{ started: boolean; lidarAvailable: boolean }>;
  /** Conferma la posizione mostrata dall'anteprima. */
  placeZone(): Promise<{ placed: boolean }>;
  /** Rimuove la zona e torna all'anteprima, senza fermare la sessione. */
  previewZone(): Promise<{ preview: boolean }>;
  resetSession(): Promise<void>;
  addListener(
    eventName: 'zoneStatus',
    listenerFunc: (status: ZoneStatus) => void,
  ): Promise<{ remove: () => Promise<void> }>;
  addListener(
    eventName: 'trackingStatus',
    listenerFunc: (status: TrackingStatus) => void,
  ): Promise<{ remove: () => Promise<void> }>;
  addListener(
    eventName: 'zoneError',
    listenerFunc: (error: ZoneError) => void,
  ): Promise<{ remove: () => Promise<void> }>;
};

export const arZone = registerPlugin<ARZoneNativePlugin>('ARZoneNative');

export const isNativeRuntime = () => Capacitor.isNativePlatform();