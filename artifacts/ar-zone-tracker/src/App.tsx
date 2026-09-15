import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ErrorBoundary } from '@/components/error-boundary';
import { Toaster } from '@/components/ui/toaster';
import { TooltipProvider } from '@/components/ui/tooltip';
import NotFound from '@/pages/not-found';
import { arZone, isNativeRuntime, type ZoneStatus } from '@/native/arZone';
import {
  Activity,
  ArrowUpRight,
  Box,
  ChevronRight,
  CircleDot,
  Compass,
  Layers3,
  LocateFixed,
  MapPin,
  Move3d,
  Radio,
  RefreshCcw,
  RotateCcw,
  Ruler,
  ScanLine,
  Settings2,
  ShieldCheck,
  SquareDashedMousePointer,
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

function Home() {
  const [mode, setMode] = useState<'simulator' | 'live'>('simulator');
  const [phase, setPhase] = useState<'ready' | 'scanning' | 'placement' | 'active'>('ready');
  const [simulatorState, setSimulatorState] = useState<'outside' | 'partial' | 'inside'>('partial');
  const [scanProgress, setScanProgress] = useState(0);
  const [nativeStatus, setNativeStatus] = useState<ZoneStatus | null>(null);
  const [nativeError, setNativeError] = useState<string | null>(null);

  const stateMeta = useMemo(() => ({
    outside: {
      label: 'Outside zone',
      description: 'Move toward the zone boundary',
      color: 'amber',
      position: { x: '-11.40 m', y: '1.20 m', z: '4.80 m' },
      percent: '0%',
      accent: 'The zone is ahead of you',
    },
    partial: {
      label: 'Partially inside',
      description: 'Two edges of the volume are around you',
      color: 'orange',
      position: { x: '−1.84 m', y: '1.20 m', z: '2.16 m' },
      percent: '42%',
      accent: 'Boundary crossing detected',
    },
    inside: {
      label: 'Fully inside',
      description: 'You are within the monitored volume',
      color: 'mint',
      position: { x: '0.80 m', y: '1.20 m', z: '−1.40 m' },
      percent: '100%',
      accent: 'All boundaries clear',
    },
  }), []);

  const currentState = nativeStatus?.state ?? simulatorState;
  const current = {
    ...stateMeta[currentState],
    percent: nativeStatus ? `${Math.round(nativeStatus.percent)}%` : stateMeta[currentState].percent,
    position: nativeStatus
      ? {
          x: `${nativeStatus.position.x.toFixed(2)} m`,
          y: `${nativeStatus.position.y.toFixed(2)} m`,
          z: `${nativeStatus.position.z.toFixed(2)} m`,
        }
      : stateMeta[currentState].position,
  };
  const isActive = phase === 'active';

  useEffect(() => {
    let subscription: { remove: () => Promise<void> } | undefined;
    if (mode !== 'live' || !isNativeRuntime()) return;

    void arZone
      .addListener('zoneStatus', (status) => {
        setNativeStatus(status);
        setSimulatorState(status.state);
      })
      .then((listener) => {
        subscription = listener;
      })
      .catch(() => setNativeError('Native AR bridge unavailable'));

    return () => {
      void subscription?.remove();
    };
  }, [mode]);

  useEffect(() => {
    if (phase !== 'scanning') return;
    setScanProgress(0);
    const interval = window.setInterval(() => {
      setScanProgress((value) => {
        if (value >= 100) {
          window.clearInterval(interval);
          setPhase('placement');
          return 100;
        }
        return value + 10;
      });
    }, 120);
    return () => window.clearInterval(interval);
  }, [phase]);

  const startScan = () => {
    setScanProgress(0);
    setNativeError(null);
    if (mode === 'live' && isNativeRuntime()) {
      void arZone
        .startSession({ width: 20, depth: 10, height: 5 })
        .then(() => setPhase('scanning'))
        .catch(() => setNativeError('Camera or ARKit permission is required'));
      return;
    }
    setPhase('scanning');
  };

  const placeZone = () => {
    if (mode === 'live' && isNativeRuntime()) {
      void arZone
        .placeZone()
        .then(() => setPhase('active'))
        .catch(() => setNativeError('Move the phone slowly, then try again'));
      return;
    }
    setPhase('active');
  };

  const reset = () => {
    setScanProgress(0);
    setPhase('ready');
    setSimulatorState('partial');
    setNativeStatus(null);
    if (mode === 'live' && isNativeRuntime()) {
      void arZone.resetSession();
    }
  };

  const setTrackingMode = (nextMode: 'simulator' | 'live') => {
    setNativeError(null);
    setMode(nextMode);
  };

  return (
    <div className={`instrument-app min-h-[100dvh] w-full overflow-x-hidden ${mode === 'live' && isNativeRuntime() ? 'native-ar-live' : ''}`}>
      <div className="instrument-noise" aria-hidden="true" />
      <aside className="instrument-sidebar">
        <div className="brand-lockup">
          <div className="brand-mark" aria-hidden="true">
            <span />
            <span />
            <span />
          </div>
          <div>
            <p className="brand-name">AR ZONE</p>
            <p className="brand-subtitle">FIELD INSTRUMENT</p>
          </div>
        </div>

        <div className="sidebar-rule" />
        <div className="sidebar-stack">
          <div className="sidebar-status">
            <span className="status-dot" />
            <span>System ready</span>
          </div>
          <div className="sidebar-readout">
            <span>SESSION</span>
            <strong>AZ-2408</strong>
          </div>
          <div className="sidebar-readout">
            <span>ZONE PROFILE</span>
            <strong>20 × 10 × 5 M</strong>
          </div>
        </div>

        <div className="sidebar-footer">
          <p>BUILT FOR SPATIAL CONFIDENCE</p>
          <div className="sidebar-version">
            <span>v1.0.4</span>
            <ShieldCheck size={14} strokeWidth={1.8} />
          </div>
        </div>
      </aside>

      <main className="instrument-main">
        <header className="topbar">
          <div className="mobile-brand">
            <div className="brand-mark small" aria-hidden="true"><span /><span /><span /></div>
            <span>AR ZONE</span>
          </div>
          <div className="breadcrumb">
            <span>WORKSPACE</span>
            <ChevronRight size={13} />
            <strong>ZONE MONITOR</strong>
          </div>
          <div className="topbar-actions">
            <div className="mode-switch" role="group" aria-label="Tracking mode">
              <button
                type="button"
                className={mode === 'simulator' ? 'mode-button active' : 'mode-button'}
                onClick={() => setTrackingMode('simulator')}
                data-testid="button-mode-simulator"
              >
                <SquareDashedMousePointer size={14} />
                Simulator
              </button>
              <button
                type="button"
                className={mode === 'live' ? 'mode-button active' : 'mode-button'}
                onClick={() => setTrackingMode('live')}
                data-testid="button-mode-live"
              >
                <Radio size={14} />
                Live AR
              </button>
            </div>
            <button className="icon-button" type="button" aria-label="Settings" data-testid="button-settings">
              <Settings2 size={17} />
            </button>
          </div>
        </header>

        {!isActive ? (
          <SetupView
            phase={phase}
            scanProgress={scanProgress}
            mode={mode}
            onStart={startScan}
          onPlace={placeZone}
          nativeError={nativeError}
          />
        ) : (
          <ActiveView
            current={current}
          simulatorState={currentState}
            mode={mode}
            onStateChange={setSimulatorState}
            onReset={reset}
          nativeStatus={nativeStatus}
          />
        )}

        <footer className="app-footer">
          <div><span className="footer-pulse" /> LOCAL SESSION · NO CLOUD SYNC</div>
          <div className="footer-links"><span>ARKit READY</span><span>·</span><span>SAFE AREA ENABLED</span></div>
        </footer>
      </main>
    </div>
  );
}

type SetupViewProps = {
  phase: 'ready' | 'scanning' | 'placement';
  scanProgress: number;
  mode: 'simulator' | 'live';
  onStart: () => void;
  onPlace: () => void;
  nativeError: string | null;
};

function SetupView({ phase, scanProgress, mode, onStart, onPlace, nativeError }: SetupViewProps) {
  const scanning = phase === 'scanning';
  const placement = phase === 'placement';
  return (
    <section className="setup-view page-enter" aria-label="Zone setup">
      <div className="setup-intro">
        <div className="eyebrow"><span className="eyebrow-line" /> INITIALIZE VOLUME</div>
        <h1>Place your<br /><em>field.</em></h1>
        <p className="setup-copy">
          Anchor a precise 20 × 10 × 5 meter volume to the world around you.
          AR Zone keeps the boundary legible, even when your attention is elsewhere.
        </p>
        <div className="setup-actions">
          {!placement && (
            <button
              type="button"
              className="primary-action"
              onClick={onStart}
              disabled={scanning}
              data-testid="button-start-scan"
            >
              {scanning ? <RefreshCcw className="spin" size={18} /> : <ScanLine size={18} />}
              {scanning ? 'Scanning environment' : 'Start AR scan'}
              {!scanning && <ArrowUpRight size={17} />}
            </button>
          )}
          {placement && (
            <button type="button" className="primary-action" onClick={onPlace} data-testid="button-place-zone">
              <MapPin size={18} />
              Place zone here
              <ArrowUpRight size={17} />
            </button>
          )}
          {scanning && (
            <div className="scan-progress" aria-label={`Scan ${scanProgress}% complete`} data-testid="status-scan-progress">
              <div className="progress-track"><span style={{ width: `${scanProgress}%` }} /></div>
              <div className="progress-meta"><span>CALIBRATING SURFACES</span><strong>{scanProgress}%</strong></div>
            </div>
          )}
        </div>
        <div className="setup-notes">
          <div className="setup-note"><LocateFixed size={16} /><span>Find a clear, level surface</span></div>
          <div className="setup-note"><Move3d size={16} /><span>Move slowly for stable tracking</span></div>
        </div>
        {nativeError && <p className="native-error" role="alert">{nativeError}</p>}
      </div>

      <div className="setup-visual">
        <div className="visual-corner corner-tl" /><div className="visual-corner corner-tr" />
        <div className="visual-corner corner-bl" /><div className="visual-corner corner-br" />
        <div className="visual-label label-top"><span>VOLUME PREVIEW</span><span>01</span></div>
        <div className="setup-orbit orbit-one" />
        <div className="setup-orbit orbit-two" />
        <div className="ghost-zone">
          <div className="ghost-face ghost-top" />
          <div className="ghost-face ghost-front" />
          <div className="ghost-face ghost-side" />
          <span className="ghost-point point-a" /><span className="ghost-point point-b" /><span className="ghost-point point-c" />
        </div>
        <div className="axis axis-x"><span>X</span></div>
        <div className="axis axis-y"><span>Y</span></div>
        <div className="axis axis-z"><span>Z</span></div>
        <div className="visual-caption">
          <div className="caption-icon"><Box size={18} /></div>
          <div><strong>ZONE VOLUME</strong><span>Spatial anchor · {mode === 'simulator' ? 'simulator preview' : 'ARKit camera'}</span></div>
        </div>
        <div className="visual-readout"><span>DIMENSIONS</span><strong>20.00 × 10.00 × 5.00 <small>M</small></strong></div>
      </div>
    </section>
  );
}

type CurrentState = {
  label: string;
  description: string;
  color: string;
  position: { x: string; y: string; z: string };
  percent: string;
  accent: string;
};

type ActiveViewProps = {
  current: CurrentState;
  simulatorState: 'outside' | 'partial' | 'inside';
  mode: 'simulator' | 'live';
  onStateChange: (value: 'outside' | 'partial' | 'inside') => void;
  onReset: () => void;
  nativeStatus: ZoneStatus | null;
};

function ActiveView({ current, simulatorState, mode, onStateChange, onReset, nativeStatus }: ActiveViewProps) {
  return (
    <section className="active-view page-enter" aria-label="Active zone monitor">
      <div className="active-header">
        <div>
          <div className="eyebrow"><span className="eyebrow-line" /> MONITORING VOLUME</div>
          <h1>Zone <em>live.</em></h1>
        </div>
        <div className="active-header-meta">
          <div className="tracking-live"><span className="live-dot" /> {mode === 'live' ? 'ARKit tracking' : 'Simulator active'}</div>
          <span className="header-time">00:04:28</span>
        </div>
      </div>

      <div className="monitor-grid">
        <div className={`spatial-map state-${current.color}`}>
          <div className="map-topline"><span>SPATIAL MAP / TOP VIEW</span><span><CircleDot size={11} /> ORIGIN LOCKED</span></div>
          <div className="map-plane">
            <div className="map-grid-lines" />
            <div className="map-compass"><Compass size={16} /><span>N</span></div>
            <div className="zone-shadow" />
            <div className="zone-volume">
              <div className="zone-top" /><div className="zone-front" /><div className="zone-right" />
              <div className="zone-label"><span className="zone-label-dot" />20 × 10 M FOOTPRINT</div>
            </div>
            <div className="person-marker">
              <div className="person-pulse" /><div className="person-core"><LocateFixed size={16} /></div>
              <span>YOU</span>
            </div>
            <div className="map-axis axis-north"><span>N</span></div>
            <div className="map-axis axis-east"><span>E</span></div>
          </div>
          <div className="map-footer">
            <div className="map-legend"><span className="legend-line" />ZONE BOUNDARY <span className="legend-you" />YOUR POSITION</div>
            <div className="map-scale"><span>−10</span><i /><span>0</span><i /><span>10 M</span></div>
          </div>
        </div>

        <aside className="monitor-rail">
          <div className={`state-card state-${current.color}`} data-testid="status-zone-state">
            <div className="state-card-top"><span className="state-kicker">CURRENT STATE</span><Activity size={17} /></div>
            <h2>{current.label}</h2>
            <p>{current.description}</p>
            <div className="state-bar"><span style={{ width: current.percent }} /></div>
            <div className="state-card-bottom"><strong>{current.percent}</strong><span>{current.accent}</span></div>
          </div>

          <div className="simulator-panel">
            <div className="panel-heading"><span>SIMULATOR POSITION</span><span className="panel-mode">TEST CONTROLS</span></div>
            <div className="simulator-options" role="group" aria-label="Simulator position">
              <button type="button" className={simulatorState === 'outside' ? 'sim-option selected outside' : 'sim-option outside'} onClick={() => onStateChange('outside')} data-testid="button-state-outside">
                <span className="option-swatch" /><span>Outside</span><small>0%</small>
              </button>
              <button type="button" className={simulatorState === 'partial' ? 'sim-option selected partial' : 'sim-option partial'} onClick={() => onStateChange('partial')} data-testid="button-state-partial">
                <span className="option-swatch" /><span>Partial</span><small>42%</small>
              </button>
              <button type="button" className={simulatorState === 'inside' ? 'sim-option selected inside' : 'sim-option inside'} onClick={() => onStateChange('inside')} data-testid="button-state-inside">
                <span className="option-swatch" /><span>Full</span><small>100%</small>
              </button>
            </div>
          </div>

          <div className="readout-panel">
            <div className="panel-heading"><span>POSITION READOUT</span><Move3d size={15} /></div>
            <div className="coordinates">
              <div><span>X AXIS</span><strong>{current.position.x}</strong></div>
              <div><span>Y AXIS</span><strong>{current.position.y}</strong></div>
              <div><span>Z AXIS</span><strong>{current.position.z}</strong></div>
            </div>
          </div>

          <div className="rail-actions">
            <button type="button" className="reset-button" onClick={onReset} data-testid="button-reset-placement"><RotateCcw size={15} /> Reset placement</button>
            <div className="quality"><div><span>TRACKING QUALITY</span><strong>{nativeStatus?.trackingQuality === 'limited' ? 'LIMITED' : 'EXCELLENT'}</strong></div><div className="quality-bars"><i /><i /><i /><i /><i /></div></div>
          </div>
        </aside>
      </div>

      <div className="measurement-strip">
        <div className="measure-item"><div className="measure-icon"><Ruler size={16} /></div><div><span>ZONE DIMENSIONS</span><strong>20.00 × 10.00 × 5.00 <small>M</small></strong></div></div>
        <div className="measure-item"><div className="measure-icon"><Layers3 size={16} /></div><div><span>EST. VOLUME</span><strong>1,000.00 <small>M³</small></strong></div></div>
        <div className="measure-item"><div className="measure-icon"><Waves size={16} /></div><div><span>SURFACE LOCK</span><strong>0.02 <small>M ERROR</small></strong></div></div>
        <div className="measure-note"><Zap size={16} /><span>Position updates at 60 Hz<br /><b>{mode === 'live' ? 'ARKit native bridge' : 'Native bridge standing by'}</b></span></div>
      </div>
    </section>
  );
}

function Router() {
  return (
    // Keep a shared shell (sidebar, navbar) outside the boundary so it
    // survives a page crash.
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
