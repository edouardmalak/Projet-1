# FIXLOG — Batch #1 (2026-08-12)

Un commit par tâche, message `fix(batch1): T<n> …`. Migrations sql/74-77 exécutées en production (Supabase) le 2026-08-12.

- T1 — done. /media/911/ bloqué par functions/_middleware.js + visuels promo retirés du bundle (gitignore + untrack).
- T2 — done. Cloche → /messages.html (l'écran des non-lus que la pastille compte) ; libellé « Alertes et messages ». Pas de nouvel écran construit.
- T3 — done. facture-vue : en-tête partagé cdEnteteConnecte(), chrome bilingue (data-fr/cdT), .catch() bilingue sur Copier. Le MANDAT reste français.
- T4 — done (feu vert explicite de Robert, i18n SEULEMENT). disponibilites.html entièrement bilingue ; zéro changement de logique/calendrier/sync Google.
- T5 — done. cdAujourdhui() (date locale) dans auth.js + 6 sites nommés corrigés. NOTÉ, pas touché (hors liste) : espace-pharmacie.html:689 a le même motif UTC.
- T6 — done. Session expirée : écouteur SIGNED_OUT (sorties volontaires exclues) + intercepteur 401 /rest/v1/ ; bandeau bilingue puis /acces.html?mode=conn avec cd-suite.
- T7 — done. Changement de mot de passe : mot de passe actuel requis (signInWithPassword) ; comptes Google sans mot de passe exemptés (champ masqué).
- T8 — done. Worker paiements : (a) /stripe/webhook signé (HMAC, tolérance 5 min, dédoublonnage stripe_evenements — sql/74), account.updated mis en cache, payment_intent.* journalisés, cron conservé ; (b) échec de capture → statut capture_failed (sql/74) + SMS pharmacie + courriel admin, fin de la re-tentative silencieuse ; (c) CORS '*' remplacé par l'allowlist de c-direct-chat.
- T9 — done. Tarification double : la ligne « frais de carte Stripe (2,9 % + 0,30 $) » retirée ; deux prix tout compris, texte bilingue.
- T10 — PARTIEL (raison documentée). sql/75 : les 2 RPC mortes de sql/42 supprimées + table verification_interac marquée DÉPRÉCIÉE. La table n'est PAS supprimée : la porte j du moteur d'auto-acceptation (sql/70) la lit encore — à repointer vers profiles.courriel_interac_cooldown dans une passe moteur, puis supprimer la table. (Au passage : cette porte lit une table que plus rien n'écrit — le refroidissement 72 h n'est donc PAS appliqué par l'auto-acceptation aujourd'hui.)
- T11 — done. carte.html « Calendrier » → /contrats.html?vue=calendrier (lu par contrats.html) ; chevron retiré sur carte.html (bascule en place conservée).
- T12 — done. espace-pharmacien.html supprimé (zéro référence, dupliquait contrats.html).
- T13 — done. Barre du haut : ordre nav · ♥ · 🔔 · FR/EN · compte ; ⚙ et « Aide » repliés dans le menu de compte (« Aide & FAQ » ouvre le même panneau) ; 1re entrée en pastille CTA pleine ; défilement horizontal mobile <900 px (menus déroulants admin exclus de la règle).
- T14 — done. index.html : hamburger sous 860 px, fermeture au clic/lien/extérieur, aria-expanded.
- T15 — done. nouveaux.html table dans un conteneur overflow-x:auto ; locums-confiance .rangee en flex-wrap + min-width:0 ; .f-contre .rangee passe à 1 colonne <560 px.
- T16 — done. min-height:44px : Retirer/Masquer/Bloquer (locums-confiance), œil et boutons Google/Apple (acces), Recentrer (carte). Padding/taille seulement.
- T17 — done. sql/76 : regles_reseau.dispensaire_visible + case dans admin.html (Règles) + auth.js retire Formations/Dispensaire des DEUX menus quand désactivé. Défaut : visible. admin-articles.html non touché.
- T18 — done. Descriptions FR ajoutées (nouveaux, conditions, confidentialite, locums-confiance, attente) ; og:title/description/type/locale sur les 9 pages publiques ; og:image sur index (icon-512.png — actif du kit de marque existant).
- T19 — done. robots.txt (pages publiques permises, app/admin/media exclus) + sitemap.xml (7 URL indexables — locums-confiance et attente sont noindex, les inclure serait contradictoire) référencé par robots.
- T20 — done. Mécanisme data-fr-contenu/data-en-contenu (auth.js + setLang d'index) : title + meta description suivent la bascule ; <html lang> était DÉJÀ mis à jour par les deux mécanismes. EN fournis sur index, faq, acces, attente, nouveaux, locums-confiance. NOTÉ : regles/conditions/confidentialite n'ont AUCUN mécanisme de langue (pages légales FR statiques) — rien à brancher sans décision produit.
- T21 — done. admin-login.html bilingue (libellés data-fr/en + messageErreur/cdT, patron d'acces.html).
- T22 — done. h1 Calendrier bilingue ; libellé FR admin « Clavardage » → « Messages » + commentaire périmé corrigé. BONUS OBLIGATOIRE : clé de cache auth.js → v=20260812a sur les 28 pages (règle d'en-tête d'auth.js, modifié par 8 tâches).
- T23 — done. Porte logiciel expliquée sur la carte auto-acceptation (lien profil) + bloc repliable « Rejets récents » branché sur mes_rejets_auto_acceptation(20) (portes a-k traduites).
- T24 — done. Contre-offre : bouton désactivé pendant l'appel.
- T25 — done. Commentaires périmés corrigés (sql/61 §9 → renvoie à sql/62 ; worker « pas câblé » → câblé ; sql/58 ECCC → livré) ; sql/62-lister-pharmacies-candidatees renommé 62b ; en-tête d'EXECUTER-TOUT.sql clarifié (fichier historique 13+14+15).
- T26 — done. media/a1-a4.png (~520 Ko) et irremplacable-teaser.mp4 retirés (zéro référence). NOTÉ, pas touché (hors liste) : media/a5.html semble aussi orphelin.
- T27 — done. sql/verifier-acl.sql créé (à exécuter après CHAQUE migration) + no-op d'aa_evenement_reglages documenté (option « commentaire », la plus petite). PREMIÈRE EXÉCUTION DU CONTRÔLE → fuite réelle trouvée et fermée : voir sql/77 ci-dessous.

## Hors liste — fait en suite immédiate du contrôle T27
- sql/77 (exécuté en production) : get_contrats_ouverts(), get_contrat_fiche(text) (recréées par sql/73 SANS le revoke anon qu'il applique ailleurs) et aa_horaire_libre() (sql/70, aucune ACL) étaient exécutables par le rôle anon — la liste complète des contrats ouverts était lisible sans session. Fermé avec la recette de sql/63. Vérification après coup : zéro fonction SECURITY DEFINER non-trigger accessible à anon.

## Actions restantes pour Robert (rien d'autre à faire côté code)
1. **Déployer le worker paiements** : `git pull` puis `npx wrangler deploy` depuis workers/c-direct-payments (ce worker ne se déploie PAS depuis GitHub). Sans ça, T8 n'est pas actif en production.
2. **Créer l'endpoint webhook chez Stripe** : Dashboard Stripe → Developers → Webhooks → Add endpoint → URL `https://c-direct-payments.edouardmalak.workers.dev/stripe/webhook`, événements `account.updated` + `payment_intent.*`, cocher « Listen to events on Connected accounts ». Copier le secret `whsec_…` puis, depuis workers/c-direct-payments : `npx wrangler secret put STRIPE_WEBHOOK_SECRET` (coller le secret). Le cron continue de tout couvrir en attendant.
3. Passe future (déjà notée dans sql/75) : repointer la porte j du moteur d'auto-acceptation vers profiles.courriel_interac_cooldown, puis supprimer la table verification_interac.

## Skips
Aucune tâche sautée. Deux éléments hors périmètre consignés par le mandat : badge mutuellement_favori sur contrats/contrat, seuil de maîtrise logiciels_niveaux.
