/* =====================================================================
   C-Direct — Filtre d'accès public (Cloudflare Pages Functions)
   ---------------------------------------------------------------------
   POURQUOI CE FICHIER EXISTE

   Cloudflare Pages publie TOUT le dépôt, pas seulement le site. Sans ce
   filtre, n'importe qui pouvait télécharger :
     · /workers/c-direct-sms/src/index.js  → tout le code du Worker
     · /sql/03-rls.sql                     → schéma, RLS, corps des fonctions
     · /A-FAIRE-ROBERT.md, /LAUNCH.md…     → notes internes

   Aucun de ces fichiers n'est nécessaire au navigateur : le site ne les
   demande jamais. On répond donc 404 (et non 403 : inutile de confirmer
   qu'un fichier existe).

   CE QUI RESTE ACCESSIBLE : tout le reste — pages .html, /c/CD-XXXXXX,
   design.css, auth.js, supabase-config.js, images, etc. Le filtre laisse
   passer par défaut ; il ne bloque que la liste explicite ci-dessous.

   À SAVOIR : ce fichier fait passer chaque requête par Pages Functions.
   S'il devait poser problème, le supprimer suffit à revenir exactement au
   comportement précédent (le site redevient 100 % statique).
   ===================================================================== */

const PREFIXES_BLOQUES = [
  '/sql/',        // migrations : schéma + RLS + corps des fonctions
  '/workers/',    // code source des Workers (SMS, assistant)
  '/.git/',       // par précaution (Pages l'exclut déjà)
  '/.internal/',  // sources internes (refonte, specs, promo) — dossier en point : Cloudflare Pages ne le déploie jamais ; bloqué ici en défense en profondeur
];

const EXTENSIONS_BLOQUEES = [
  '.md',          // notes internes, README, checklists de lancement
  '.sql',         // au cas où un .sql traînerait hors de /sql/
  '.toml',        // wrangler.toml et consorts
  '.lock',
  '.zip',         // archives de packaging internes (c-direct-*.zip)
];

// Documents internes (stratégie, journaux d'actions, rapports de test) qui
// vivent à la racine du dépôt et ne sont liés par aucune page — publiés
// tels quels par Cloudflare Pages, donc téléchargeables par n'importe qui
// sans ce filtre. On bloque par PRÉFIXE pour couvrir les versions datées.
// (Les aperçus destinés au public — apercu-*.pdf — restent accessibles.)
const PREFIXES_FICHIERS_BLOQUES = [
  '/c-direct-actions-',
  '/c-direct-audit-',
  '/c-direct-scenarios-',
  '/phase-test-report',
  '/rapport-test-',
];

function estBloque(chemin) {
  const p = chemin.toLowerCase();
  if (PREFIXES_BLOQUES.some(prefixe => p.startsWith(prefixe))) return true;
  if (EXTENSIONS_BLOQUEES.some(ext => p.endsWith(ext))) return true;
  if (PREFIXES_FICHIERS_BLOQUES.some(prefixe => p.startsWith(prefixe))) return true;
  return false;
}

export async function onRequest(context) {
  // Toute erreur inattendue ici ne doit JAMAIS casser le site :
  // en cas de doute, on laisse passer la requête normalement.
  try {
    const chemin = new URL(context.request.url).pathname;
    if (estBloque(chemin)) {
      return new Response('Not found', {
        status: 404,
        headers: {
          'content-type': 'text/plain; charset=utf-8',
          'cache-control': 'no-store',
          'x-robots-tag': 'noindex',
        },
      });
    }
  } catch (e) {
    // on continue vers le contenu normal
  }
  return context.next();
}
