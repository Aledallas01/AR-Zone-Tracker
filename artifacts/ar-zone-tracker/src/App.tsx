import { useEffect, useState } from 'react';
import {
  arZone,
  isNativeRuntime,
  type TrackingStatus,
  type ZoneState,
  type ZoneStatus,
} from '@/native/arZone';

/** Misure della zona in centimetri: unica fonte di verita per UI e plugin.
 *  ARKit ragiona in metri, quindi la conversione avviene solo al confine nativo. */
const ZONE_CM = { width: 20, depth: 10, height: 5 } as const;
const CM_PER_M = 100;

type Phase = 'starting' | 'placing' | 'tracking';

const STATES: ReadonlyArray<{ key: ZoneState; label: string }> = [
  { key: 'outside', label: 'Fuori' },
  { key: 'partial', label: 'Parzialmente dentro' },
  { key: 'inside', label: 'Completamente dentro' },
];

/** La zona resta ferma solo se ARKit ha gia mappato abbastanza ambiente:
 *  piazzarla prima e la causa principale della deriva. */
function scanReady(tracking: TrackingStatus | null): boolean {
  if (!tracking) return false;
  if (tracking.trackingQuality !== 'normal') return false;
  if (!tracking.previewReady) return false;
  return tracking.mappingStatus === 'extending' || tracking.mappingStatus === 'mapped';
}

function scanHint(tracking: TrackingStatus | null): string {
  if (!tracking) return 'Avvio fotocamera...';
  if (tracking.trackingQuality !== 'normal') {
    return 'Muovi lentamente il telefono';
  }
  if (tracking.lidarAvailable && tracking.meshAnchors > 0) {
    return `Scansione LiDAR: ${tracking.meshAnchors} blocchi`;
  }
  if (!tracking.previewReady) {
    return 'Inquadra il pavimento al centro';
  }
  return 'Scansione ambiente...';
}

function ZoneOverlay() {
  const nativeRuntime = isNativeRuntime();
  const [phase, setPhase] = useState<Phase>('starting');
  const [status, setStatus] = useState<ZoneStatus | null>(null);
  const [tracking, setTracking] = useState<TrackingStatus | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!nativeRuntime) return;

    let disposed = false;
    let subscriptions: Array<{ remove: () => Promise<void> }> = [];

    const connect = async () => {
      try {
        subscriptions = await Promise.all([
          arZone.addListener('zoneStatus', (next) => {
            if (!disposed) setStatus(next);
          }),
          arZone.addListener('trackingStatus', (next) => {
            if (!disposed) setTracking(next);
          }),
          arZone.addListener('zoneError', ({ message }) => {
            if (!disposed) setError(message);
          }),
        ]);

        await arZone.startSession({
          width: ZONE_CM.width / CM_PER_M,
          depth: ZONE_CM.depth / CM_PER_M,
          height: ZONE_CM.height / CM_PER_M,
        });
        if (!disposed) setPhase('placing');
      } catch (cause) {
        if (!disposed) {
          setError(cause instanceof Error ? cause.message : 'Impossibile avviare ARKit.');
        }
      }
    };

    void connect();
    return () => {
      disposed = true;
      subscriptions.forEach((subscription) => {
        void subscription.remove();
      });
    };
  }, [nativeRuntime]);

  const place = async () => {
    setError(null);
    try {
      await arZone.placeZone();
      setPhase('tracking');
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : 'Punta la fotocamera verso una superficie orizzontale.',
      );
    }
  };

  const replace = async () => {
    setStatus(null);
    setPhase('placing');
    try {
      await arZone.previewZone();
    } catch {
      setError('Impossibile tornare in anteprima.');
    }
  };

  if (!nativeRuntime) {
    return (
      <div className="zone-notice">
        <p>AR Zone Tracker richiede l&rsquo;app iPhone nativa con ARKit.</p>
      </div>
    );
  }

  const state: ZoneState = status?.state ?? 'outside';
  const percent = Math.min(100, Math.max(0, status?.percent ?? 0));
  const ready = scanReady(tracking);

  return (
    <div className="zone-overlay">
      {error ? <p className="zone-error">{error}</p> : null}

      {phase === 'tracking' ? (
        <div className="zone-readout">
          <div className="zone-track" role="presentation">
            <div className="zone-fill" style={{ width: `${percent}%` }} />
            <div className="zone-knob" style={{ left: `${percent}%` }} />
          </div>
          <div className="zone-labels">
            {STATES.map((item) => (
              <span key={item.key} className={item.key === state ? 'is-active' : undefined}>
                {item.label}
              </span>
            ))}
          </div>
          <button type="button" className="zone-secondary" onClick={replace}>
            Riposiziona
          </button>
          <p className="zone-tip">Doppio tap sul box per le misure dei lati</p>
        </div>
      ) : (
        <>
          <p className="zone-scan">
            {ready ? 'Anteprima agganciata - conferma quando ti piace' : scanHint(tracking)}
          </p>
          <button
            type="button"
            className="zone-primary"
            onClick={place}
            disabled={!ready}
            data-testid="button-place-zone"
          >
            Posiziona zona
          </button>
        </>
      )}
    </div>
  );
}

function App() {
  return <ZoneOverlay />;
}

export default App;
