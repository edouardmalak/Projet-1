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
<VOTRE_WEBHOOK_SECRET — généré par vous, stocké dans votre gestionnaire de mots de passe + le secret du Worker, JAMAIS commité>
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

**Phase 5 — trois webhooks SUPPLÉMENTAIRES** (mêmes URL et header que
ci-dessus, seuls le nom, la table et les évènements changent) :

| Name | Table | Events |
|---|---|---|
| `sms-contrats-update` | `contrats` | **UPDATE** |
| `sms-candidatures` | `candidatures` | **INSERT** + **UPDATE** |
| `sms-factures` | `factures` | **UPDATE** |

Pour chacun : Database → Webhooks → Create a new hook → cocher le(s)
évènement(s) → HTTP Request POST → URL `…workers.dev/webhook` → header
`X-Webhook-Secret`. Après création, redéployer le Worker n'est PAS requis
(les webhooks pointent vers la même route).

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
| `POST /admin/purger-inscription` | `Authorization: Bearer <jeton session admin>` | `{ "courriel": "..." }` → supprime un compte Supabase Auth **jamais confirmé** (doublon d'inscription bloqué, bouton console admin « Inscription bloquée »). Revérifie `email_confirmed_at` côté serveur avant de supprimer — refuse tout compte déjà confirmé une seule fois. Journalisé dans `admin_audit_log`. |
| `POST /test-push` | header `X-Webhook-Secret` | `{ "profil_id": "..." }` → envoie une notification push de test à tous les abonnements de ce profil (voir § 6) |

Test rapide en ligne de commande :

```bash
curl -X POST "https://c-direct-sms.<sous-domaine>.workers.dev/test" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Secret: <VOTRE_WEBHOOK_SECRET — généré par vous, stocké dans votre gestionnaire de mots de passe + le secret du Worker, JAMAIS commité>" \
  -d '{"to":"+1514XXXXXXX"}'
```

## 5 · Notifications push (Web Push — sql/49, parametres.html)

Diffusée en parallèle du SMS à la publication d'un contrat (`diffuserPush`
dans `diffusionNouveauContrat`), sur un canal **indépendant** : un
pharmacien sans téléphone, ou ayant refusé le SMS, peut quand même
recevoir le push s'il l'a activé dans Paramètres → Notifications.
Chiffrement RFC 8291 + jeton RFC 8292, implémentés à la main avec l'API
Web Crypto (aucune dépendance npm, comme le reste de ce Worker) — voir
les commentaires au-dessus de `chiffrerPush`/`vapidAuthorization` dans
`src/index.js`. **Non testée de bout en bout dans l'environnement de
développement** (la clé privée n'y transite jamais) : valider avec
`/test-push` (étape 3 ci-dessous) avant de compter dessus en production.

**Étapes (terminal, une seule fois) :**

```bash
cd workers/c-direct-sms

# 1) générer la paire de clés (rien n'est envoyé nulle part — local)
node generer-vapid.js

# 2) les deux valeurs affichées :
npx wrangler secret put VAPID_PUBLIC_KEY    # collez la valeur 1/2
npx wrangler secret put VAPID_PRIVATE_KEY   # collez la valeur 3 (SECRÈTE)
npx wrangler deploy

# 3) collez CD_VAPID_PUBLIC_KEY (valeur 1) dans supabase-config.js —
#    Claude peut le faire si vous lui donnez cette valeur (pas secrète),
#    puis commit/push (déploiement automatique du site).

# 4) test réel : activez les notifications depuis Paramètres →
#    Notifications sur votre téléphone/ordinateur, notez votre profil_id
#    (Supabase → table profiles), puis :
curl -X POST "https://c-direct-sms.<sous-domaine>.workers.dev/test-push" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Secret: <VOTRE_WEBHOOK_SECRET>" \
  -d '{"profil_id":"<votre uuid profiles.id>"}'
# → une notification doit apparaître sur l'appareil dans les secondes qui suivent
```

Sans `VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY`, la diffusion push est
simplement ignorée (`push: {ok:false, skip:'VAPID non configuré'}` dans
la réponse de `/diffuser` et `/webhook`) — le SMS et le reste ne sont
jamais affectés.

## 6 · Garanties

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
