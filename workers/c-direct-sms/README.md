# Worker « c-direct-sms » — Phase 4

Pipeline SMS : **Supabase Database Webhooks → ce Worker (Cloudflare) → Twilio**.
Worker séparé du site : le déploiement Pages n'est pas touché. Aucun secret
dans le code ni dans git — tout passe par `wrangler secret put`.

## 1 · Commandes exactes (terminal, une seule fois)

```bash
cd "workers/c-direct-sms"

# connexion au compte Cloudflare (ouvre le navigateur, une fois)
npx wrangler login

# ---- les 6 secrets (coller la valeur quand demandé) ----
npx wrangler secret put TWILIO_ACCOUNT_SID        # SID du compte Twilio (ACxxxx…)
npx wrangler secret put TWILIO_AUTH_TOKEN         # Auth Token Twilio
npx wrangler secret put TWILIO_FROM_NUMBER        # +1450XXXXXXX (format E.164)
npx wrangler secret put SUPABASE_URL              # https://fenlujjozanerbzyypjt.supabase.co
npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY # Supabase → Settings → API → service_role
npx wrangler secret put WEBHOOK_SECRET            # coller la valeur ci-dessous

# ---- déployer ----
npx wrangler deploy
# → note l'URL affichée : https://c-direct-sms.<sous-domaine>.workers.dev
```

**Valeur du WEBHOOK_SECRET (générée pour ce projet — ne vit qu'ici et dans
les deux dashboards) :**

```
62fec5c4c01c77530a4c8e628f72b0e961353477a392895641b7896de27b95a4
```

Redéployer après toute modification du code : `npx wrangler deploy` (les
secrets survivent aux déploiements).

## 2 · Webhook Supabase (dashboard — configurer SEULEMENT celui-ci en Phase 4)

Supabase → **Database → Webhooks → Create a new hook** :

1. Name : `sms-nouveau-contrat`
2. Table : `contrats` · Events : **INSERT** uniquement
3. Type : **HTTP Request** · Method : **POST**
4. URL : `https://c-direct-sms.<sous-domaine>.workers.dev/webhook`
5. HTTP Headers → **Add header** :
   `X-Webhook-Secret` = la valeur ci-dessus
6. Confirm / Create.

(Les autres évènements — attribution, rappels, etc. — viennent en Phase 5.)

## 3 · Twilio — webhook entrant (opt-out ARRET/STOP)

Twilio Console → **Phone Numbers → Manage → Active numbers** → cliquer le
numéro +1450… → section **Messaging Configuration** :

1. « A message comes in » : **Webhook**
2. URL : `https://c-direct-sms.<sous-domaine>.workers.dev/twilio-inbound`
3. HTTP : **POST** → Save configuration.

Twilio gère déjà ARRET/STOP au niveau opérateur sur les longs codes
canadiens ; ce webhook synchronise EN PLUS `profiles.sms_optin=false`
et journalise tout message entrant dans `sms_log`.

## 4 · Endpoints

| Route | Auth | Rôle |
|---|---|---|
| `POST /webhook` | header `X-Webhook-Secret` | INSERT contrats → diffusion pharmaciens + confirmation pharmacie |
| `POST /twilio-inbound` | (appelé par Twilio) | ARRET/STOP/UNSUBSCRIBE/DESABONNER → opt-out ; tout le reste journalisé |
| `POST /test` | header `X-Webhook-Secret` | `{ "to": "+1XXXXXXXXXX" }` → SMS test (bouton console admin) |

Test rapide en ligne de commande :

```bash
curl -X POST "https://c-direct-sms.<sous-domaine>.workers.dev/test" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Secret: 62fec5c4c01c77530a4c8e628f72b0e961353477a392895641b7896de27b95a4" \
  -d '{"to":"+1514XXXXXXX"}'
```

## 5 · Garanties

- **Idempotence** : Supabase peut réessayer un webhook — déduplication sur
  (id du contrat + type d'évènement) dans une fenêtre de 10 minutes via
  lookup `sms_log` avant tout envoi.
- **Journal** : CHAQUE tentative (succès ou échec) est écrite dans `sms_log`
  (type, destinataire, corps, twilio_sid, statut, erreur).
- **Premier SMS** à un numéro donné : ajout automatique de
  « Rep. ARRET pour vous desabonner. » (lookup `sms_log`).
- **Concurrence** : 5 envois Twilio en parallèle, pas plus.
- **GSM-7** : gabarits sans caractères hors alphabet GSM (« août » → « aout »,
  tiret simple) pour rester à 1 segment (≤160 caractères) quand possible.
