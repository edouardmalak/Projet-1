# Worker « c-direct-payments » — squelette

Ce Worker recevra plus tard les routes Stripe Connect (autorisation T-24h,
capture, annulation, webhooks). Pour l'instant c'est un squelette vide —
juste assez pour se déployer et avoir un endroit où stocker la clé Stripe
en secret, en attendant la construction réelle dans une passe dédiée.

## Envoyer la clé Stripe (terminal, une seule fois)

```bash
cd "workers/c-direct-payments"

# connexion au compte Cloudflare (ouvre le navigateur, une fois —
# pas nécessaire si déjà fait pour c-direct-sms)
npx wrangler login

# coller la clé secrète du sandbox Stripe (sk_test_...) quand demandé
npx wrangler secret put STRIPE_SECRET_KEY

# déployer
npx wrangler deploy
# → note l'URL affichée : https://c-direct-payments.<sous-domaine>.workers.dev
```

Vérifier que la clé est bien reçue (sans jamais l'afficher) :

```bash
curl https://c-direct-payments.<sous-domaine>.workers.dev/health
# → {"ok":true,"worker":"c-direct-payments","stripe_key_configured":true}
```

**La clé ne doit jamais être collée dans le chat ni committée dans le
dépôt** — seulement via `wrangler secret put`, exactement comme
`TWILIO_AUTH_TOKEN` et `RESEND_API_KEY` pour `c-direct-sms`.

## Prochaine étape

Une fois `stripe_key_configured: true` confirmé, la construction réelle
commence : carte enregistrée côté pharmacie, comptes Connect Express pour
les pharmaciens, machine à états (autorisation → capture/annulation),
webhooks Connect. Chaque route est écrite en suivant la documentation
Stripe officielle au moment de l'écrire, jamais de mémoire.
