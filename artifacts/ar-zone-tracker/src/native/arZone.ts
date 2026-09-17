import { Capacitor, registerPlugin } from '@capacitor/core';

export type ZoneState = 'outside' | 'partial' | 'inside';

export type MappingStatus = 'notAvailable' | 'limited' | 'extending' | 'mapped';

/** Stato di una singola zona. Arriva solo quando qualcosa cambia: un evento per
 *  frame per zona saturerebbe il ponte con il nativo. */
export type ZoneStatus = {
  id: string;
  state: ZoneState;
  percent: number;
};

export type ZoneEvent = {
  id: string;
};

export type TrackingStatus = {
  trackingQuality: 'notAvailable' | 'limited' | 'normal';
  lidarAvailable: boolean;
  surfaceDetected: boolean;
  /** Quanto ARKit ha mappato l'ambiente: sotto 'extending' l'ancoraggio deriva. */
  mappingStatus: MappingStatus;
  /** Numero di blocchi di mesh LiDAR ricostruiti finora. */
  meshAnchors: number;
  /** true quando l'anteprima sta agganciando una superficie. */
  previewReady: boolean;
  /** ARKit sta cercando di riconoscere l'ambiente della mappa salvata. */
  relocalizing: boolean;
  zoneCount: number;
  hasSavedZones: boolean;
};

export type ZoneError = {
  message: string;
};

export type ARZoneNativePlugin = {
  isSupported(): Promise<{ supported: boolean; lidarAvailable: boolean }>;
  startSession(): Promise<{
    started: boolean;
    lidarAvailable: boolean;
    restoringSavedZones: boolean;
  }>;
  /** Entra in modalita aggiunta: il box segue il centro dello schermo.
   *  Le misure sono in METRI, l'unita di ARKit. */
  previewZone(options: {
    color: string;
    width: number;
    height: number;
    depth: number;
  }): Promise<{ preview: boolean }>;
  cancelPreview(): Promise<{ preview: boolean }>;
  /** Conferma la posizione mostrata dall'anteprima per la zona indicata. */
  placeZone(options: { id: string; color: string }): Promise<{ placed: boolean; id: string }>;
  removeZone(options: { id: string }): Promise<{ removed: boolean; id: string }>;
  resetSession(): Promise<void>;
  /** Configurazione dell'interfaccia (JSON), salvata in UserDefaults. */
  getConfig(): Promise<{ config: string; shortcutsAvailable: boolean }>;
  setConfig(options: { config: string }): Promise<{ saved: boolean }>;
  runShortcut(options: { name: string }): Promise<{ launched: boolean; name: string }>;
  /** Dimentica mappa e zone salvate: necessario quando si cambia stanza. */
  clearSavedZones(): Promise<{ cleared: boolean }>;
  addListener(
    eventName: 'zoneStatus',
    listenerFunc: (status: ZoneStatus) => void,
  ): Promise<{ remove: () => Promise<void> }>;
  addListener(
    eventName: 'trackingStatus',
    listenerFunc: (status: TrackingStatus) => void,
  ): Promise<{ remove: () => Promise<void> }>;
  addListener(
    eventName: 'zoneEnter' | 'zoneExit',
    listenerFunc: (event: ZoneEvent) => void,
  ): Promise<{ remove: () => Promise<void> }>;
  addListener(
    eventName: 'zoneError',
    listenerFunc: (error: ZoneError) => void,
  ): Promise<{ remove: () => Promise<void> }>;
};

export const arZone = registerPlugin<ARZoneNativePlugin>('ARZoneNative');

export const isNativeRuntime = () => Capacitor.isNativePlatform();
