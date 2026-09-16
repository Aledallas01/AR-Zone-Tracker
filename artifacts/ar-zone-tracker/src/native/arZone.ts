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

export type TrackingStatus = {
  trackingQuality: 'notAvailable' | 'limited' | 'normal';
  lidarAvailable: boolean;
  surfaceDetected: boolean;
};

export type ZoneError = {
  message: string;
};

export type ARZoneNativePlugin = {
  isSupported(): Promise<{ supported: boolean; lidarAvailable: boolean }>;
  startSession(options: {
    width: number;
    depth: number;
    height: number;
  }): Promise<{ started: boolean; lidarAvailable: boolean }>;
  placeZone(): Promise<{ placed: boolean }>;
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