# Worker « c-direct-payments »

Onboarding Stripe Connect : carte « garantie de paiement » côté pharmacie
(SetupIntent sur le compte plateforme) et compte connecté Express côté
pharmacien. Aucune charge, capture ni annulation encore — ça vient dans une
passe dédiée une fois l'onboarding testé de bout en bout.

## 1 · Trois secrets à envoyer (terminal)

```bash
cd "workers/c-direct-payments"
npx wrangler login   # déjà fait si vous l'avez fait pour STRIPE_SECRET_KEY

npx wrangler secret put SUPABASE_URL
# coller : https://fenlujjozanerbzyypjt.supabase.co
# (pas un secret à proprement parler, mais même méthode pour rester cohérent)

npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY
# Supabase → Settings → API → service_role → coller la valeur

npx wrangler deploy
```

(`STRIPE_SECRET_KEY` est déjà en place depuis la première passe.)

Vérifier que tout est bien reçu :

```bash
curl https://c-direct-payments.edouardmalak.workers.dev/health
# → {"ok":true,"worker":"c-direct-payments","stripe_key_configured":true,"supabase_configured":true}
```

## 2 · Routes

| Route | Rôle |
|---|---|
| `GET /health` | Diagnostic — confirme que les secrets sont bien configurés, sans jamais les afficher |
| `POST /pharmacien/onboarding-start` | Crée (ou réutilise) le compte connecté Express du pharmacien + un lien d'onboarding Stripe. Body : `{ return_url }`. En-tête `Authorization: Bearer <jeton Supabase du pharmacien>` obligatoire |
| `GET /pharmacien/onboarding-refresh` | `refresh_url` vivant — Stripe y redirige si le lien a expiré (~5 min) ou déjà été visité ; régénère un nouveau lien et redirige (302). Jamais une page statique |
| `POST /pharmacie/setup-intent` | Crée (ou réutilise) le customer Stripe plateforme de la pharmacie + un SetupIntent pour enregistrer sa carte. En-tête `Authorization: Bearer <jeton Supabase de la pharmacie>` obligatoire |
| `POST /pharmacie/setup-confirm` | Vérification légère après confirmation côté client (Stripe.js) — body `{ setup_intent_id }` |

Toutes les routes (sauf `/health` et le refresh) exigent le jeton de session
Supabase de l'utilisateur connecté — jamais un `profil_id` fourni par le
client. Les identifiants Stripe (`stripe_customer_id`, `stripe_account_id`)
sont stockés dans la table `stripe_comptes` (sql/42), en écriture
service-role seulement — le client ne peut jamais les falsifier.

## 3 · Écrit en suivant la documentation Stripe (pas de mémoire)

- Comptes connectés : paramètre `controller` (pas `type`, déprécié) —
  https://docs.stripe.com/api/accounts/create
- « Stripe handles pricing » : `controller.fees` / `controller.losses` /
  `controller.requirement_collection` volontairement omis — les valeurs par
  défaut (`account`, `stripe`, `stripe`) sont exactement celles voulues.
- Account Links à usage unique, expirent en ~5 min, `refresh_url` doit être
  un endpoint vivant — https://docs.stripe.com/api/account_links/create
- Carte enregistrée sans `on_behalf_of` (customer plateforme), pour pouvoir
  être clonée vers le compte connecté à chaque quart plus tard —
  https://docs.stripe.com/connect/direct-charges-multiple-accounts

## 4 · Prochaine étape

Une fois l'onboarding testé (créer un compte connecté de test, enregistrer
une carte de test), la construction continue avec : machine à états
(autorisation T-24h → capture/annulation), webhooks `account.updated`,
puis les écrans du site. Chaque route Stripe est écrite en lisant la
documentation officielle au moment de l'écrire.
