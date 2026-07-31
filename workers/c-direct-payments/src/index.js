// =====================================================================
// C-DIRECT — Worker "c-direct-payments" — squelette
//
// Rien de Stripe n'est encore appelé ici. Ce fichier existe seulement
// pour que le Worker se déploie et qu'un endroit existe pour stocker
// les secrets (STRIPE_SECRET_KEY, etc.) avant la construction réelle
// des routes de paiement (create-auth-hold, capture-auth-hold,
// void-auth-hold, webhooks Connect), qui seront ajoutées dans une passe
// dédiée en suivant la documentation Stripe officielle pour chaque
// étape (jamais de code Stripe écrit de mémoire — voir le skill
// c-direct-payments, references/stripe-docs.md).
// =====================================================================

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === '/health') {
      return new Response(
        JSON.stringify({
          ok: true,
          worker: 'c-direct-payments',
          stripe_key_configured: Boolean(env.STRIPE_SECRET_KEY),
        }),
        { headers: { 'Content-Type': 'application/json' } }
      );
    }

    return new Response('C-Direct payments worker — squelette, routes à venir.', {
      status: 200,
    });
  },
};
