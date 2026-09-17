import { useEffect, useMemo, useRef, useState } from 'react';
import {
  arZone,
  isNativeRuntime,
  type TrackingStatus,
  type ZoneState,
  type ZoneStatus,
} from '@/native/arZone';

/** Misure predefinite in centimetri. ARKit ragiona in metri, quindi la
 *  conversione avviene solo al confine nativo. */
const DEFAULT_SIZE_CM = { width: 20, depth: 10, height: 5 } as const;
const CM_PER_M = 100;

const PALETTE = [
  { hex: '#175394', label: 'Blu' },
  { hex: '#1E7A5F', label: 'Verde' },
  { hex: '#9A3B1F', label: 'Rosso' },
  { hex: '#7A3E9C', label: 'Viola' },
  { hex: '#B07A12', label: 'Ambra' },
  { hex: '#256E7E', label: 'Ciano' },
] as const;

const STATE_LABEL: Record<ZoneState, string> = {
  outside: 'Fuori',
  partial: 'Parzialmente dentro',
  inside: 'Completamente dentro',
};

const STATE_ORDER: ReadonlyArray<ZoneState> = ['outside', 'partial', 'inside'];

type ZoneConfig = {
  id: string;
  name: string;
  color: string;
  /** Misure in centimetri: e l'unita con cui si ragiona nell'interfaccia. */
  width: number;
  depth: number;
  height: number;
  shortcutEnter: string;
  shortcutExit: string;
};

type StoredConfig = { zones: ZoneConfig[] };

function newZone(index: number): ZoneConfig {
  return {
    id: `z${Date.now().toString(36)}`,
    name: `Zona ${index + 1}`,
    color: PALETTE[index % PALETTE.length].hex,
    width: DEFAULT_SIZE_CM.width,
    depth: DEFAULT_SIZE_CM.depth,
    height: DEFAULT_SIZE_CM.height,
    shortcutEnter: '',
    shortcutExit: '',
  };
}

function scanReady(tracking: TrackingStatus | null): boolean {
  if (!tracking) return false;
  if (tracking.trackingQuality !== 'normal') return false;
  if (!tracking.previewReady) return false;
  return tracking.mappingStatus === 'extending' || tracking.mappingStatus === 'mapped';
}

function scanHint(tracking: TrackingStatus | null): string {
  if (!tracking) return 'Avvio fotocamera...';
  if (tracking.relocalizing) return 'Cerco le zone salvate: inquadra la stessa area';
  if (tracking.trackingQuality !== 'normal') return 'Muovi lentamente il telefono';
  if (tracking.lidarAvailable && tracking.meshAnchors > 0) {
    return `Scansione LiDAR: ${tracking.meshAnchors} blocchi`;
  }
  if (!tracking.previewReady) return 'Inquadra il pavimento al centro';
  return 'Scansione ambiente...';
}

/** Editor di una zona: nome, colore e i due comandi rapidi. iOS non espone
 *  l'elenco degli shortcut, quindi la scelta avviene per nome esatto. */
function ZoneEditor({
  zone,
  onSave,
  onDelete,
  onClose,
  onTest,
}: {
  zone: ZoneConfig;
  onSave: (zone: ZoneConfig) => void;
  onDelete: (id: string) => void;
  onClose: () => void;
  onTest: (name: string) => void;
}) {
  const [draft, setDraft] = useState(zone);

  return (
    <div className="zone-sheet-backdrop" role="dialog" aria-modal="true">
      <div className="zone-sheet">
        <h2>{zone.name}</h2>

        <label className="zone-field">
          <span>Nome</span>
          <input
            className="zone-input"
            type="text"
            value={draft.name}
            onChange={(event) => setDraft({ ...draft, name: event.target.value })}
            data-testid="input-zone-name"
          />
        </label>

        <div className="zone-field">
          <span>Colore</span>
          <div className="zone-swatches">
            {PALETTE.map((entry) => (
              <button
                key={entry.hex}
                type="button"
                className={draft.color === entry.hex ? 'zone-swatch is-active' : 'zone-swatch'}
                style={{ background: entry.hex }}
                aria-label={entry.label}
                onClick={() => setDraft({ ...draft, color: entry.hex })}
              />
            ))}
          </div>
        </div>

        <label className="zone-field">
          <span>Comando rapido all&rsquo;ingresso</span>
          <input
            className="zone-input"
            type="text"
            value={draft.shortcutEnter}
            placeholder="Nome esatto del comando"
            autoCapitalize="none"
            autoCorrect="off"
            onChange={(event) => setDraft({ ...draft, shortcutEnter: event.target.value })}
            data-testid="input-shortcut-enter"
          />
        </label>

        <label className="zone-field">
          <span>Comando rapido all&rsquo;uscita</span>
          <input
            className="zone-input"
            type="text"
            value={draft.shortcutExit}
            placeholder="Opzionale"
            autoCapitalize="none"
            autoCorrect="off"
            onChange={(event) => setDraft({ ...draft, shortcutExit: event.target.value })}
            data-testid="input-shortcut-exit"
          />
        </label>

        <div className="zone-sheet-actions">
          <button type="button" className="zone-secondary" onClick={onClose}>
            Annulla
          </button>
          {draft.shortcutEnter.trim() ? (
            <button
              type="button"
              className="zone-secondary"
              onClick={() => onTest(draft.shortcutEnter.trim())}
            >
              Prova
            </button>
          ) : null}
          <button
            type="button"
            className="zone-primary compact"
            onClick={() => onSave({ ...draft, name: draft.name.trim() || zone.name })}
            data-testid="button-save-zone"
          >
            Salva
          </button>
        </div>

        <button type="button" className="zone-danger" onClick={() => onDelete(zone.id)}>
          Elimina zona
        </button>
      </div>
    </div>
  );
}

function ZoneOverlay() {
  const nativeRuntime = isNativeRuntime();
  const [zones, setZones] = useState<ZoneConfig[]>([]);
  const [statuses, setStatuses] = useState<Record<string, ZoneStatus>>({});
  const [tracking, setTracking] = useState<TrackingStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [shortcutsAvailable, setShortcutsAvailable] = useState(true);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [placingId, setPlacingId] = useState<string | null>(null);

  // I listener nativi si registrano una volta sola: con lo state leggerebbero
  // per sempre il valore iniziale, quindi la lista passa da un ref.
  const zonesRef = useRef<ZoneConfig[]>([]);

  useEffect(() => {
    zonesRef.current = zones;
  }, [zones]);

  const persist = async (next: ZoneConfig[]) => {
    setZones(next);
    zonesRef.current = next;
    try {
      await arZone.setConfig({ config: JSON.stringify({ zones: next }) });
    } catch {
      setError('Impossibile salvare la configurazione.');
    }
  };

  useEffect(() => {
    if (!nativeRuntime) return;

    let disposed = false;
    let subscriptions: Array<{ remove: () => Promise<void> }> = [];

    const runFor = (id: string, pick: (zone: ZoneConfig) => string) => {
      const zone = zonesRef.current.find((entry) => entry.id === id);
      if (!zone) return;
      const name = pick(zone).trim();
      if (!name) {
        // Nessun comando ancora scelto per questa zona: si chiede al momento
        // del primo ingresso, come per la configurazione iniziale.
        if (pick === pickEnter) setEditingId(id);
        return;
      }
      void arZone.runShortcut({ name }).catch(() => {
        setError(`Comando rapido "${name}" non trovato.`);
      });
    };

    const connect = async () => {
      try {
        subscriptions = await Promise.all([
          arZone.addListener('zoneStatus', (next) => {
            if (!disposed) setStatuses((current) => ({ ...current, [next.id]: next }));
          }),
          arZone.addListener('trackingStatus', (next) => {
            if (!disposed) setTracking(next);
          }),
          arZone.addListener('zoneEnter', ({ id }) => {
            if (!disposed) runFor(id, pickEnter);
          }),
          arZone.addListener('zoneExit', ({ id }) => {
            if (!disposed) runFor(id, pickExit);
          }),
          arZone.addListener('zoneError', ({ message }) => {
            if (!disposed) setError(message);
          }),
        ]);

        const saved = await arZone.getConfig();
        if (!disposed) {
          setShortcutsAvailable(saved.shortcutsAvailable);
          if (saved.config) {
            try {
              const parsed = JSON.parse(saved.config) as StoredConfig;
              const list = Array.isArray(parsed.zones) ? parsed.zones : [];
              setZones(list);
              zonesRef.current = list;
            } catch {
              setError('Configurazione salvata illeggibile: ricomincio da zero.');
            }
          }
        }

        await arZone.startSession();
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

  const addZone = async () => {
    const zone = newZone(zonesRef.current.length);
    await persist([...zonesRef.current, zone]);
    setSettingsOpen(false);
    await startPlacing(zone);
  };

  const startPlacing = async (zone: ZoneConfig) => {
    setPlacingId(zone.id);
    try {
      await arZone.previewZone({
        color: zone.color,
        width: zone.width / CM_PER_M,
        depth: zone.depth / CM_PER_M,
        height: zone.height / CM_PER_M,
      });
    } catch {
      setError('Impossibile avviare l’anteprima.');
    }
  };

  const confirmPlacement = async () => {
    const zone = zonesRef.current.find((entry) => entry.id === placingId);
    if (!zone) return;
    setError(null);
    try {
      await arZone.placeZone({ id: zone.id, color: zone.color });
      setPlacingId(null);
    } catch (cause) {
      setError(
        cause instanceof Error ? cause.message : 'Punta la fotocamera verso una superficie.',
      );
    }
  };

  const cancelPlacement = async () => {
    setPlacingId(null);
    try {
      await arZone.cancelPreview();
    } catch {
      /* l'anteprima sparisce comunque al prossimo frame */
    }
  };

  const saveZone = async (updated: ZoneConfig) => {
    const next = zonesRef.current.map((entry) => (entry.id === updated.id ? updated : entry));
    await persist(next);
    setEditingId(null);
  };

  const deleteZone = async (id: string) => {
    await persist(zonesRef.current.filter((entry) => entry.id !== id));
    setEditingId(null);
    setStatuses((current) => {
      const next = { ...current };
      delete next[id];
      return next;
    });
    try {
      await arZone.removeZone({ id });
    } catch {
      setError('Impossibile rimuovere la zona dalla scena.');
    }
  };

  const forgetSaved = async () => {
    try {
      await arZone.clearSavedZones();
      setStatuses({});
      setSettingsOpen(false);
    } catch {
      setError('Impossibile cancellare le zone salvate.');
    }
  };

  const testShortcut = (name: string) => {
    void arZone.runShortcut({ name }).catch(() => {
      setError(`Comando rapido "${name}" non trovato.`);
    });
  };

  // Zona da mostrare nell'indicatore: quella in cui si e piu dentro.
  const active = useMemo(() => {
    let best: { zone: ZoneConfig; status: ZoneStatus } | null = null;
    for (const zone of zones) {
      const status = statuses[zone.id];
      if (!status) continue;
      if (!best || status.percent > best.status.percent) {
        best = { zone, status };
      }
    }
    return best;
  }, [zones, statuses]);

  if (!nativeRuntime) {
    return (
      <div className="zone-notice">
        <p>AR Zone Tracker richiede l&rsquo;app iPhone nativa con ARKit.</p>
      </div>
    );
  }

  const editing = zones.find((entry) => entry.id === editingId) ?? null;
  const placing = zones.find((entry) => entry.id === placingId) ?? null;
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

        {placing ? (
          <>
            <p className="zone-scan">
              {ready ? `Conferma dove mettere ${placing.name}` : scanHint(tracking)}
            </p>
            <div className="zone-place-actions">
              <button type="button" className="zone-secondary" onClick={cancelPlacement}>
                Annulla
              </button>
              <button
                type="button"
                className="zone-primary"
                onClick={confirmPlacement}
                disabled={!ready}
                data-testid="button-place-zone"
              >
                Posiziona
              </button>
            </div>
          </>
        ) : zones.length === 0 ? (
          <button type="button" className="zone-primary" onClick={addZone}>
            Crea la prima zona
          </button>
        ) : (
          <div className="zone-readout">
            <div className="zone-chips">
              {zones.map((zone) => {
                const state = statuses[zone.id]?.state ?? 'outside';
                return (
                  <button
                    key={zone.id}
                    type="button"
                    className={state === 'outside' ? 'zone-chip' : 'zone-chip is-live'}
                    onClick={() => setEditingId(zone.id)}
                  >
                    <span className="zone-dot" style={{ background: zone.color }} />
                    {zone.name}
                  </button>
                );
              })}
            </div>

            <div className="zone-track" role="presentation">
              <div
                className="zone-fill"
                style={{
                  width: `${active?.status.percent ?? 0}%`,
                  background: active?.zone.color ?? '#175394',
                }}
              />
              <div className="zone-knob" style={{ left: `${active?.status.percent ?? 0}%` }} />
            </div>
            <div className="zone-labels">
              {STATE_ORDER.map((key) => (
                <span
                  key={key}
                  className={key === (active?.status.state ?? 'outside') ? 'is-active' : undefined}
                >
                  {STATE_LABEL[key]}
                </span>
              ))}
            </div>
            <p className="zone-tip">Doppio tap su un box per le misure dei lati</p>
          </div>
        )}
      </div>

      {editing ? (
        <ZoneEditor
          zone={editing}
          onSave={saveZone}
          onDelete={deleteZone}
          onClose={() => setEditingId(null)}
          onTest={testShortcut}
        />
      ) : null}

      {settingsOpen ? (
        <div className="zone-sheet-backdrop" role="dialog" aria-modal="true">
          <div className="zone-sheet">
            <h2>Impostazioni</h2>

            <div className="zone-settings-rows">
              {zones.length === 0 ? <p className="zone-sheet-copy">Nessuna zona.</p> : null}
              {zones.map((zone) => (
                <div key={zone.id} className="zone-settings-row">
                  <span className="zone-dot" style={{ background: zone.color }} />
                  <div className="zone-settings-text">
                    <strong>{zone.name}</strong>
                    <span>{zone.shortcutEnter || 'Nessun comando'}</span>
                  </div>
                  <button
                    type="button"
                    className="zone-secondary"
                    onClick={() => {
                      setSettingsOpen(false);
                      void startPlacing(zone);
                    }}
                  >
                    Sposta
                  </button>
                  <button
                    type="button"
                    className="zone-secondary"
                    onClick={() => {
                      setSettingsOpen(false);
                      setEditingId(zone.id);
                    }}
                  >
                    Modifica
                  </button>
                </div>
              ))}
            </div>

            <p className="zone-sheet-copy">
              Comandi Rapidi: {shortcutsAvailable ? 'disponibile' : 'non raggiungibile'}
            </p>

            <div className="zone-sheet-actions">
              <button
                type="button"
                className="zone-secondary"
                onClick={() => setSettingsOpen(false)}
              >
                Chiudi
              </button>
              <button
                type="button"
                className="zone-primary compact"
                onClick={addZone}
                data-testid="button-add-zone"
              >
                Aggiungi zona
              </button>
            </div>

            {tracking?.hasSavedZones ? (
              <button type="button" className="zone-danger" onClick={forgetSaved}>
                Dimentica zone salvate
              </button>
            ) : null}
          </div>
        </div>
      ) : null}
    </>
  );
}

const pickEnter = (zone: ZoneConfig) => zone.shortcutEnter;
const pickExit = (zone: ZoneConfig) => zone.shortcutExit;

function App() {
  return <ZoneOverlay />;
}

export default App;
