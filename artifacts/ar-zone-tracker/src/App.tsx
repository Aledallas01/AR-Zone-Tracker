import { useEffect, useRef, useState } from 'react';
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
  if (tracking.relocalizing) {
    return 'Cerco la zona salvata: inquadra la stessa area';
  }
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

/** Pannello per scegliere il comando rapido. iOS non espone l'elenco degli
 *  shortcut dell'utente, quindi la scelta avviene per nome esatto. */
function ShortcutPanel({
  title,
  initialName,
  onSave,
  onClose,
  onTest,
}: {
  title: string;
  initialName: string;
  onSave: (name: string) => void;
  onClose: () => void;
  onTest?: (name: string) => void;
}) {
  const [name, setName] = useState(initialName);

  return (
    <div className="zone-sheet-backdrop" role="dialog" aria-modal="true">
      <div className="zone-sheet">
        <h2>{title}</h2>
        <p className="zone-sheet-copy">
          Scrivi il nome esatto del comando rapido, come compare nell&rsquo;app Comandi Rapidi.
        </p>
        <input
          className="zone-input"
          type="text"
          value={name}
          placeholder="Nome del comando rapido"
          autoCapitalize="none"
          autoCorrect="off"
          onChange={(event) => setName(event.target.value)}
          data-testid="input-shortcut-name"
        />
        <div className="zone-sheet-actions">
          <button type="button" className="zone-secondary" onClick={onClose}>
            Annulla
          </button>
          {onTest ? (
            <button
              type="button"
              className="zone-secondary"
              onClick={() => onTest(name.trim())}
              disabled={!name.trim()}
            >
              Prova
            </button>
          ) : null}
          <button
            type="button"
            className="zone-primary compact"
            onClick={() => onSave(name.trim())}
            disabled={!name.trim()}
            data-testid="button-save-shortcut"
          >
            Salva
          </button>
        </div>
      </div>
    </div>
  );
}

function ZoneOverlay() {
  const nativeRuntime = isNativeRuntime();
  const [phase, setPhase] = useState<Phase>('starting');
  const [status, setStatus] = useState<ZoneStatus | null>(null);
  const [tracking, setTracking] = useState<TrackingStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [shortcut, setShortcut] = useState('');
  const [shortcutsAvailable, setShortcutsAvailable] = useState(true);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [askShortcut, setAskShortcut] = useState(false);

  // Il listener nativo viene registrato una volta sola: con lo state leggerebbe
  // per sempre il valore iniziale, quindi serve un ref.
  const shortcutRef = useRef('');
  const previousState = useRef<ZoneState | null>(null);

  useEffect(() => {
    shortcutRef.current = shortcut;
  }, [shortcut]);

  useEffect(() => {
    if (!nativeRuntime) return;

    let disposed = false;
    let subscriptions: Array<{ remove: () => Promise<void> }> = [];

    const enteredZone = () => {
      const name = shortcutRef.current;
      if (!name) {
        setAskShortcut(true);
        return;
      }
      void arZone.runShortcut({ name }).catch(() => {
        setError('Comando rapido non trovato. Controlla il nome nelle impostazioni.');
      });
    };

    const connect = async () => {
      try {
        subscriptions = await Promise.all([
          arZone.addListener('zoneStatus', (next) => {
            if (disposed) return;
            setStatus(next);
            if (next.state === 'inside' && previousState.current !== 'inside') {
              enteredZone();
            }
            previousState.current = next.state;
          }),
          arZone.addListener('trackingStatus', (next) => {
            if (disposed) return;
            setTracking(next);
            // Una zona ripristinata dalla mappa salvata e gia attiva: si entra
            // direttamente in tracking senza passare dall'anteprima.
            if (next.zonePlaced) {
              setPhase((current) => (current === 'tracking' ? current : 'tracking'));
            }
          }),
          arZone.addListener('zoneError', ({ message }) => {
            if (!disposed) setError(message);
          }),
        ]);

        const saved = await arZone.getShortcut();
        if (!disposed) {
          setShortcut(saved.name);
          shortcutRef.current = saved.name;
          setShortcutsAvailable(saved.available);
        }

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
      previousState.current = null;
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
    previousState.current = null;
    setPhase('placing');
    try {
      await arZone.previewZone();
    } catch {
      setError('Impossibile tornare in anteprima.');
    }
  };

  const saveShortcut = async (name: string) => {
    try {
      await arZone.setShortcut({ name });
      setShortcut(name);
      shortcutRef.current = name;
      setAskShortcut(false);
      setSettingsOpen(false);
    } catch {
      setError('Impossibile salvare il comando rapido.');
    }
  };

  const forgetSavedZone = async () => {
    try {
      await arZone.clearSavedZone();
      await arZone.previewZone();
      setStatus(null);
      previousState.current = null;
      setPhase('placing');
      setSettingsOpen(false);
    } catch {
      setError('Impossibile cancellare la zona salvata.');
    }
  };

  const testShortcut = (name: string) => {
    void arZone.runShortcut({ name }).catch(() => {
      setError('Comando rapido non trovato.');
    });
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
    <>
      <button
        type="button"
        className="zone-settings-button"
        onClick={() => setSettingsOpen(true)}
        aria-label="Impostazioni"
        data-testid="button-settings"
      >
        &#9881;
      </button>

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

      {askShortcut ? (
        <ShortcutPanel
          title="Quale comando rapido?"
          initialName={shortcut}
          onSave={saveShortcut}
          onClose={() => setAskShortcut(false)}
        />
      ) : null}

      {settingsOpen ? (
        <div className="zone-sheet-backdrop" role="dialog" aria-modal="true">
          <div className="zone-sheet">
            <h2>Impostazioni</h2>
            <dl className="zone-settings-list">
              <div>
                <dt>Dimensioni zona</dt>
                <dd>
                  {ZONE_CM.width} &times; {ZONE_CM.depth} &times; {ZONE_CM.height} cm
                </dd>
              </div>
              <div>
                <dt>Comando rapido all&rsquo;ingresso</dt>
                <dd>{shortcut || 'Nessuno'}</dd>
              </div>
              <div>
                <dt>App Comandi Rapidi</dt>
                <dd>{shortcutsAvailable ? 'Disponibile' : 'Non raggiungibile'}</dd>
              </div>
              <div>
                <dt>Zona salvata</dt>
                <dd>{tracking?.hasSavedZone ? 'Ripristinata' : 'Nessuna'}</dd>
              </div>
            </dl>
            {tracking?.hasSavedZone ? (
              <button type="button" className="zone-danger" onClick={forgetSavedZone}>
                Dimentica zona salvata
              </button>
            ) : null}
            <div className="zone-sheet-actions">
              <button
                type="button"
                className="zone-secondary"
                onClick={() => setSettingsOpen(false)}
              >
                Chiudi
              </button>
              {shortcut ? (
                <button
                  type="button"
                  className="zone-secondary"
                  onClick={() => testShortcut(shortcut)}
                >
                  Prova
                </button>
              ) : null}
              <button
                type="button"
                className="zone-primary compact"
                onClick={() => {
                  setSettingsOpen(false);
                  setAskShortcut(true);
                }}
                data-testid="button-change-shortcut"
              >
                {shortcut ? 'Cambia' : 'Scegli'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}

function App() {
  return <ZoneOverlay />;
}

export default App;
