// =====================================================================
// Génère une paire de clés VAPID pour les notifications Web Push.
// À exécuter UNE FOIS, sur VOTRE machine (jamais dans le Worker ni dans
// git) : node generer-vapid.js
//
// Donne deux valeurs :
//   1. CD_VAPID_PUBLIC_KEY   → PAS secrète, va dans supabase-config.js
//      (window.CD_VAPID_PUBLIC_KEY = "...") — Claude peut coller cette
//      valeur pour vous si vous la lui donnez.
//   2. VAPID_PRIVATE_KEY     → SECRÈTE, ne la partagez avec personne,
//      pas même Claude. Collez-la directement dans la commande :
//        cd workers/c-direct-sms
//        npx wrangler secret put VAPID_PUBLIC_KEY   (collez la valeur 1)
//        npx wrangler secret put VAPID_PRIVATE_KEY  (collez la valeur 2)
//        npx wrangler deploy
// =====================================================================
const { generateKeyPairSync } = require('crypto');

function b64url(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const pubJwk = publicKey.export({ format: 'jwk' });
const privJwk = privateKey.export({ format: 'jwk' });

// clé publique en point EC non compressé (0x04 || X || Y, 65 octets) —
// c'est le format attendu à la fois par PushManager.subscribe() côté
// navigateur et par l'en-tête VAPID "k=" côté Worker.
const x = Buffer.from(pubJwk.x, 'base64url');
const y = Buffer.from(pubJwk.y, 'base64url');
const rawPub = Buffer.concat([Buffer.from([4]), x, y]);

console.log('\n1) CD_VAPID_PUBLIC_KEY — coller dans supabase-config.js (pas secret) :\n');
console.log(b64url(rawPub));

console.log('\n2) VAPID_PUBLIC_KEY — coller dans « npx wrangler secret put VAPID_PUBLIC_KEY » (même valeur que ci-dessus) :\n');
console.log(b64url(rawPub));

console.log('\n3) VAPID_PRIVATE_KEY — coller dans « npx wrangler secret put VAPID_PRIVATE_KEY » (SECRET, gardez-le en lieu sûr) :\n');
console.log(JSON.stringify(privJwk));
console.log('');
