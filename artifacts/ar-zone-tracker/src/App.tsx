import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ErrorBoundary } from '@/components/error-boundary';
import { Toaster } from '@/components/ui/toaster';
import { TooltipProvider } from '@/components/ui/tooltip';
import NotFound from '@/pages/not-found';
import {
  arZone,
  isNativeRuntime,
  type TrackingStatus,
  type ZoneStatus,
} from '@/native/arZone';
import {
  Activity,
  ArrowUpRight,
  Camera,
  CheckCircle2,
  CircleAlert,
  ChevronRight,
  LocateFixed,
  Move3d,
  Radio,
  RotateCcw,
  Ruler,
  ScanLine,
  ShieldCheck,
  Waves,
  Zap,
} from 'lucide-react';
import {
  Route,
  Switch,
  useLocation,
  Router as WouterRouter,
} from 'wouter';

const queryClient = new QueryClient();

type Phase = 'ready' | 'scanning' | 'active';

function Home() {
  const nativeRuntime = isNativeRuntime();
  const [phase, setPhase] = useState<Phase>('ready');
  const [trackingStatus, setTrackingStatus] = useState<TrackingStatus | null>(null);
  const [nativeStatus, setNativeStatus] = useState<ZoneStatus | null>(null);
  const [nativeError, setNativeError] = useState<string | null>(
    nativeRuntime ? null : 'AR Zone Tracker richiede l’app iPhone nativa con ARKit.',
  );

  useEffect(() => {
    if (!nativeRuntime) return;

    let disposed = false;
    let subscriptions: Array<{ remove: () => Promise<void> }> = [];

    const connectNativeSession = async () => {
      try {
        subscriptions = await Promise.all([
          arZone.addListener('trackingStatus', (status) => {
            if (!disposed) setTrackingStatus(status);
          }),
          arZone.addListener('zoneStatus', (status) => {
            if (!disposed) setNativeStatus(status);
          }),
          arZone.addListener('zoneError', ({ message }) => {
            if (!disposed) {
              setNativeError(message);
              setPhase('scanning');
            }
          }),
        ]);

        const support = await arZone.isSupported();
        if (!support.supported && !disposed) {
          setNativeError('Questo iPhone non supporta ARKit world tracking.');
        }
      } catch {
        if (!disposed) {
          setNativeError('Bridge ARKit non disponibile nella build installata.');
        }
      }
    };

    void connectNativeSession();
    return () => {
      disposed = true;
      subscriptions.forEach((subscription) => {
        void subscription.remove();
      });
    };
  }, [nativeRuntime]);

  const startSession = async () => {
    setNativeError(null);
    try {
      await arZone.startSession({ width: 20, depth: 10, height: 5 });
      setTrackingStatus(null);
      setNativeStatus(null);
      setPhase('scanning');
    } catch (error) {
      setNativeError(error instanceof Error ? error.message : 'Impossibile avviare ARKit.');
    }
  };

  const placeZone = async () => {
    setNativeError(null);
    try {
      await arZone.placeZone();
      setPhase('active');
    } catch (error) {
      setNativeError(
        error instanceof Error
          ? error.message
          : 'Punta la fotocamera verso una superficie orizzontale reale.',
      );
    }
  };

  const reset = async () => {
    setNativeError(null);
    setTrackingStatus(null);
    setNativeStatus(null);
    setPhase('ready');
    try {
      await arZone.resetSession();
    } catch (error) {
      setNativeError(error instanceof Error ? error.message : 'Impossibile arrestare la sessione ARKit.');
    }
  };

  const current = useMemo(() => {
    if (!nativeStatus) return null;
    const stateMeta = {
      outside: {
        label: 'Outside zone',
        description: 'Il telefono è fuori dal volume reale.',
        color: 'amber',
        accent: 'Nessuna sovrapposizione',
      },
      partial: {
        label: 'Partially inside',
        description: 'Il volume del telefono interseca il confine reale.',
        color: 'orange',
        accent: 'Attraversamento del confine rilevato',
      },
      inside: {
        label: 'Fully inside',
        description: 'Il volume del telefono è dentro la zona reale.',
        color: 'mint',
        accent: 'Tutti i confini sono oltre il telefono',
      },
    } as const;

    return {
      ...stateMeta[nativeStatus.state],
      percent: `${Math.round(nativeStatus.percent)}%`,
      position: {
        x: `${nativeStatus.position.x.toFixed(2)} m`,
        y: `${nativeStatus.position.y.toFixed(2)} m`,
        z: `${nativeStatus.position.z.toFixed(2)} m`,
      },
    };
  }, [nativeStatus]);

  if (!nativeRuntime) {
    return <UnsupportedView message={nativeError ?? 'Avvia l’app nativa su iPhone.'} />;
  }

  return (
    <div className="instrument-app native-ar-live min-h-[100dvh] w-full overflow-x-hidden">
      <div className="instrument-noise" aria-hidden="true" />
      <aside className="instrument-sidebar">
        <div className="brand-lockup">
          <div className="brand-mark" aria-hidden="true"><span /><span /><span /></div>
          <div>
            <p className="brand-name">AR ZONE</p>
            <p className="brand-subtitle">NATIVE ARKIT</p>
          </div>
        </div>
        <div className="sidebar-rule" />
        <div className="sidebar-stack">
          <div className="sidebar-status"><span className="status-dot" /><span>Local session</span></div>
          <div className="sidebar-readout"><span>ZONE PROFILE</span><strong>20 × 10 × 5 M</strong></div>
          <div className="sidebar-readout"><span>TRACKING SOURCE</span><strong>ARKit camera</strong></div>
        </div>
        <div className="sidebar-footer">
          <p>NO SIMULATION · NO CLOUD DATA</p>
          <div className="sidebar-version"><span>v1.1.0</span><ShieldCheck size={14} strokeWidth={1.8} /></div>
        </div>
      </aside>

      <main className="instrument-main">
        <header className="topbar">
          <div className="mobile-brand">
            <div className="brand-mark small" aria-hidden="true"><span /><span /><span /></div>
            <span>AR ZONE</span>
          </div>
          <div className="breadcrumb">
            <span>IPHONE</span><ChevronRight size={13} /><strong>LIVE ARKIT</strong>
          </div>
          <div className="topbar-actions">
            <div className="tracking-live">
              <span className="live-dot" />
              {phase === 'active' ? 'ARKit tracking' : 'ARKit ready'}
            </div>
            <Camera size={17} className="camera-indicator" />
          </div>
        </header>

        {phase !== 'active' ? (
          <SetupView
            phase={phase}
            trackingStatus={trackingStatus}
            nativeError={nativeError}
            onStart={startSession}
            onPlace={placeZone}
          />
        ) : (
          <ActiveView
            current={current}
            trackingStatus={trackingStatus}
            nativeStatus={nativeStatus}
            onReset={reset}
          />
        )}

        <footer className="app-footer">
          <div><span className="footer-pulse" /> LOCAL SESSION · NO CLOUD SYNC</div>
          <div className="footer-links"><span>ARKit NATIVE</span><span>·</span><span>REAL POSITION ONLY</span></div>
        </footer>
      </main>
    </div>
  );
}

function UnsupportedView({ message }: { message: string }) {
  return (
    <div className="unsupported-view">
      <div className="unsupported-card">
        <CircleAlert size={28} />
        <p className="eyebrow">NATIVE IPHONE APP REQUIRED</p>
        <h1>ARKit non disponibile.</h1>
        <p>{message}</p>
        <span>Questa app non contiene una modalità simulata.</span>
      </div>
    </div>
  );
}

type SetupViewProps = {
  phase: Phase;
  trackingStatus: TrackingStatus | null;
  nativeError: string | null;
  onStart: () => void;
  onPlace: () => void;
};

function SetupView({ phase, trackingStatus, nativeError, onStart, onPlace }: SetupViewProps) {
  const scanning = phase === 'scanning';
  const canPlace = trackingStatus?.trackingQuality === 'normal';
  const trackingLabel = !trackingStatus
    ? 'In attesa di un frame ARKit'
    : trackingStatus.trackingQuality === 'normal'
      ? trackingStatus.surfaceDetected
        ? 'Superficie orizzontale rilevata'
        : 'Muovi lentamente il telefono'
      : 'Tracking limitato: muovi il telefono lentamente';

  return (
    <section className="setup-view page-enter" aria-label="ARKit setup">
      <div className="setup-intro">
        <div className="eyebrow"><span className="eyebrow-line" /> INITIALIZE REAL SPACE</div>
        <h1>Scan your<br /><em>field.</em></h1>
        <p className="setup-copy">
          ARKit rileva lo spazio reale attraverso la fotocamera dell’iPhone.
          Nessuna posizione viene inventata o sostituita con dati di prova.
        </p>
        <div className="setup-actions">
          {!scanning ? (
            <button type="button" className="primary-action" onClick={onStart} data-testid="button-start-scan">
              <ScanLine size={18} /> Start real AR scan <ArrowUpRight size={17} />
            </button>
          ) : (
            <button
              type="button"
              className="primary-action"
              onClick={onPlace}
              disabled={!canPlace}
              data-testid="button-place-zone"
            >
              <LocateFixed size={18} /> Place zone on detected floor <ArrowUpRight size={17} />
            </button>
          )}
        </div>
        <div className="setup-notes">
          <div className="setup-note"><Move3d size={16} /><span>{trackingLabel}</span></div>
          <div className="setup-note">
            {trackingStatus?.lidarAvailable ? <CheckCircle2 size={16} /> : <Radio size={16} />}
            <span>{trackingStatus?.lidarAvailable ? 'LiDAR / scene depth active' : 'ARKit world tracking active'}</span>
          </div>
        </div>
        {nativeError && <p className="native-error" role="alert">{nativeError}</p>}
      </div>

      <div className="live-surface" aria-label="Live AR camera surface">
        <div className="visual-corner corner-tl" /><div className="visual-corner corner-tr" />
        <div className="visual-corner corner-bl" /><div className="visual-corner corner-br" />
        <div className="live-surface-label">
          <span>LIVE CAMERA FEED</span><strong>{scanning ? 'TRACKING' : 'STANDBY'}</strong>
        </div>
        <div className="live-surface-center">
          <Camera size={24} />
          <strong>{scanning ? 'Point the camera at the floor' : 'Camera session not started'}</strong>
          <span>The native ARKit view is behind this panel.</span>
        </div>
        <div className="live-surface-readout">
          <span>ZONE DIMENSIONS</span>
          <strong>20.00 × 10.00 × 5.00 <small>M</small></strong>
        </div>
      </div>
    </section>
  );
}

type ActiveViewProps = {
  current: {
    label: string;
    description: string;
    color: string;
    percent: string;
    accent: string;
    position: { x: string; y: string; z: string };
  } | null;
  trackingStatus: TrackingStatus | null;
  nativeStatus: ZoneStatus | null;
  onReset: () => void;
};

function ActiveView({ current, trackingStatus, nativeStatus, onReset }: ActiveViewProps) {
  const trackingLabel = trackingStatus?.trackingQuality === 'limited' ? 'LIMITED' : 'NORMAL';
  return (
    <section className="active-view page-enter" aria-label="Active ARKit monitor">
      <div className="active-header">
        <div>
          <div className="eyebrow"><span className="eyebrow-line" /> MONITORING REAL VOLUME</div>
          <h1>Zone <em>live.</em></h1>
        </div>
        <div className="active-header-meta">
          <div className="tracking-live"><span className="live-dot" /> ARKit tracking</div>
          <span className="header-time">{trackingLabel}</span>
        </div>
      </div>

      <div className="monitor-grid">
        <div className="live-monitor">
          <div className="map-topline"><span>LIVE AR CAMERA</span><span><Radio size={11} /> NATIVE FEED</span></div>
          <div className="live-monitor-content">
            <Camera size={26} />
            <strong>Volume anchor active</strong>
            <span>Move through the real zone. The status is calculated from the ARKit camera pose.</span>
            <div className="live-monitor-dimensions">20.00 × 10.00 × 5.00 M</div>
          </div>
        </div>

        <aside className="monitor-rail">
          <div className={`state-card state-${current?.color ?? 'amber'}`} data-testid="status-zone-state">
            <div className="state-card-top"><span className="state-kicker">CURRENT STATE</span><Activity size={17} /></div>
            <h2>{current?.label ?? 'Waiting for AR frame'}</h2>
            <p>{current?.description ?? 'ARKit sta acquisendo la posizione reale del telefono.'}</p>
            <div className="state-bar"><span style={{ width: current?.percent ?? '0%' }} /></div>
            <div className="state-card-bottom"><strong>{current?.percent ?? '—'}</strong><span>{current?.accent ?? 'Acquisizione in corso'}</span></div>
          </div>

          <div className="readout-panel">
            <div className="panel-heading"><span>REAL POSITION READOUT</span><Move3d size={15} /></div>
            <div className="coordinates">
              <div><span>X AXIS</span><strong>{current?.position.x ?? '—'}</strong></div>
              <div><span>Y AXIS</span><strong>{current?.position.y ?? '—'}</strong></div>
              <div><span>Z AXIS</span><strong>{current?.position.z ?? '—'}</strong></div>
            </div>
          </div>

          <div className="rail-actions">
            <button type="button" className="reset-button" onClick={onReset} data-testid="button-reset-placement">
              <RotateCcw size={15} /> Reset real placement
            </button>
            <div className="quality">
              <div><span>TRACKING QUALITY</span><strong>{trackingLabel}</strong></div>
              <div className="quality-bars"><i /><i /><i /><i /><i /></div>
            </div>
          </div>
        </aside>
      </div>

      <div className="measurement-strip">
        <div className="measure-item"><div className="measure-icon"><Ruler size={16} /></div><div><span>ZONE DIMENSIONS</span><strong>20.00 × 10.00 × 5.00 <small>M</small></strong></div></div>
        <div className="measure-item"><div className="measure-icon"><Waves size={16} /></div><div><span>DEPTH SENSOR</span><strong>{trackingStatus?.lidarAvailable ? 'LiDAR' : 'ARKit'} <small>ACTIVE</small></strong></div></div>
        <div className="measure-item"><div className="measure-icon"><Zap size={16} /></div><div><span>POSITION SOURCE</span><strong>ARFrame <small>LIVE</small></strong></div></div>
        <div className="measure-note"><CircleAlert size={16} /><span>Only native ARKit data<br /><b>{nativeStatus ? 'Position received' : 'Waiting for position'}</b></span></div>
      </div>
    </section>
  );
}

function Router() {
  return (
    <RoutedErrorBoundary>
      <Switch>
        <Route path="/" component={Home} />
        <Route component={NotFound} />
      </Switch>
    </RoutedErrorBoundary>
  );
}

function RoutedErrorBoundary({ children }: { children: ReactNode }) {
  const [location] = useLocation();
  return <ErrorBoundary resetKey={location}>{children}</ErrorBoundary>;
}

function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <TooltipProvider>
        <WouterRouter base={import.meta.env.BASE_URL.replace(/\/$/, '')}>
          <Router />
        </WouterRouter>
        <Toaster />
      </TooltipProvider>
    </QueryClientProvider>
  );
}

export default App;