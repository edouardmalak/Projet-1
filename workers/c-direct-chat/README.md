# Worker `c-direct-chat` — assistant IA des tableaux de bord

Cerveau de l'assistant (widget 💬 sur espace-pharmacie, contrats, mes-mandats,
disponibilités). Worker **séparé** : ne touche ni le site Pages ni `c-direct-sms`.

## Sécurité (résumé)

- Le Worker ne touche **aucune donnée** : il vérifie le jeton Supabase de
  l'usager puis relaie la conversation à Claude (modèle Haiku).
- Les outils s'exécutent **dans le navigateur** avec la session de l'usager →
  la RLS Supabase s'applique intégralement (chacun ne voit que son propre monde).
- Toute **écriture** (publier un quart, disponibilités) affiche une carte
  **Confirmer / Annuler** — rien ne s'exécute sans clic de l'usager.
- Jamais de baisse de taux : consigne système + le plancher `regles_reseau`
  est re-vérifié côté client avant l'insertion.
- Limite : 60 requêtes/usager/heure.

## Activation (3 étapes, ~5 minutes)

1. **Créer la clé API** : console.anthropic.com → API Keys → *Create key*.
   Ajoutez quelques dollars de crédit (Haiku coûte des sous par conversation).
2. **Déployer le Worker** — même recette que c-direct-sms (intégration git du
   tableau de bord Cloudflare) : Workers & Pages → Create → Continue with GitHub
   → repo `Projet-1` → nom `c-direct-chat`, commande de déploiement
   `cd workers/c-direct-chat && npx wrangler deploy`, racine `/`.
   Puis Settings → Variables and Secrets → Add → **encrypted** →
   `ANTHROPIC_API_KEY` = la clé (jamais dans git). Redéployer.
   (Équivalent CLI : `npx wrangler deploy` + `npx wrangler secret put ANTHROPIC_API_KEY`.)
   URL attendue : `https://c-direct-chat.edouardmalak.workers.dev`.
3. **Brancher le site** : dans `supabase-config.js`, remplir
   `window.CD_CHAT_URL = "https://c-direct-chat.edouardmalak.workers.dev";`
   puis commit + push (ou demandez à Claude : « branche l'assistant sur <URL> »).

Vérification : ouvrir l'URL du Worker dans le navigateur →
`{"ok":true,"ia_active":true}`. Tant que `CD_CHAT_URL` est vide, le widget
reste en **mode aperçu** (interface visible, aucune IA appelée).
