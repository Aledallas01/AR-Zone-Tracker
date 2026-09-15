# AR Zone Tracker

App Capacitor per iPhone che posiziona e monitora una zona AR di 20 × 10 × 5 metri.

## Run & Operate

- `pnpm --filter @workspace/api-server run dev` — run the API server (port 5000)
- `pnpm run typecheck` — full typecheck across all packages
- `pnpm run build` — typecheck + build all packages
- `pnpm --filter @workspace/api-spec run codegen` — regenerate API hooks and Zod schemas from the OpenAPI spec
- `pnpm --filter @workspace/db run push` — push DB schema changes (dev only)
- Required env: `DATABASE_URL` — Postgres connection string

## Stack

- pnpm workspaces, Node.js 24, TypeScript 5.9
- API: Express 5
- DB: PostgreSQL + Drizzle ORM
- Validation: Zod (`zod/v4`), `drizzle-zod`
- API codegen: Orval (from OpenAPI spec)
- Build: esbuild (CJS bundle)

## Where things live

- `artifacts/ar-zone-tracker/src/App.tsx` — preview UI, setup flow and simulator.
- `artifacts/ar-zone-tracker/src/native/arZone.ts` — bridge TypeScript verso ARKit.
- `artifacts/ar-zone-tracker/ios/App/App/ARZoneNative.swift` — plugin nativo per tracking, LiDAR e rilevamento della zona.
- `artifacts/ar-zone-tracker/capacitor.config.ts` — configurazione Capacitor e identificativo iOS.

## Architecture decisions

- L'app usa Capacitor + ARKit, con un plugin Swift locale, perché il rilevamento spaziale affidabile richiede API native iOS.
- La UI browser include un simulatore esplicito per verificare fuori/parzialmente/completamente dentro senza hardware.
- La percentuale indica il volume di sovrapposizione tra il piccolo volume del telefono e la zona, non una distanza arbitraria.
- LiDAR/scene depth è opzionale: ARKit world tracking continua a funzionare sui dispositivi senza LiDAR.

## Product

L'utente scansiona l'ambiente, posiziona una zona virtuale, poi vede stato, percentuale di ingresso, coordinate locali e qualità del tracking mentre si muove.

## User preferences

_Populate as you build — explicit user instructions worth remembering across sessions._

## Gotchas

- Il progetto iOS va aperto e firmato con Xcode su Mac per il sideload; l'ambiente di sviluppo web non può eseguire Xcode.
- Dopo modifiche alla UI eseguire `pnpm --filter @workspace/ar-zone-tracker run cap:sync` prima di aprire Xcode.

## Pointers

- See the `pnpm-workspace` skill for workspace structure, TypeScript setup, and package details
