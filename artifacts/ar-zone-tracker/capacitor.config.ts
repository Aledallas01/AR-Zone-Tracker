import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.arzonetracker.app',
  appName: 'AR Zone Tracker',
  webDir: 'dist/public',
  bundledWebRuntime: false,
  ios: {
    contentInset: 'automatic',
    backgroundColor: '#edf3f0',
  },
  server: {
    iosScheme: 'capacitor',
  },
};

export default config;