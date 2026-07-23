# PROMPT MAÎTRE v2 — Refonte c-direct.ca
### Paste into Claude Code. Attach: competitor screenshots + `campagne-irremplacable.md` + `c-direct-accueil.html` + logo SVGs.

---

## CONTEXT

You are redesigning the marketing site for **C-Direct** (c-direct.ca), a Quebec platform connecting pharmacies with locum pharmacists (« pharmaciens remplaçants »). Stack: static HTML/CSS/JS on Cloudflare Pages, Supabase for auth. **Do not rename or break any existing signup/login links or auth JS.** All visitor-facing copy is in Québécois French.

## INPUT FILES — use them, don't reinvent

1. **Competitor screenshots** (attached): locum-placement platforms. Use ONLY for structural inspiration (section order, hierarchy, what they lead with) and for contrast — identify what makes each feel like a generic SaaS template, then make C-Direct feel more premium and more Québécois than all of them. **NEVER copy their text, photos, icons, logos, or color schemes.**
2. **`campagne-irremplacable.md`**: the brand campaign. The copy in it is FINAL — use it verbatim where indicated below. Do not rewrite, translate, or "improve" the French.
3. **`c-direct-accueil.html`**: the existing hero with the REMPLAÇABLE → strikethrough → IRREMPLAÇABLE animation. Keep this animation as the hero's core; refine timing/polish only.
4. **Logo SVGs**: C-DIRECT wordmark where the hyphen is a balance scale. Dark version on light backgrounds, white/amber inverse on green. If you can't find the files in the repo, ask me for paths — do not improvise a logo.

## REQUIRED FIRST STEP — before writing any code

1. Analyze each screenshot: a short table — competitor | what works | what's weak | what C-Direct does differently.
2. Propose a section map for the page (based on the hierarchy below).

**Wait for my approval. Then build section by section, showing me each before starting the next.** Never generate the whole page in one shot. Commit after each approved section.

## BRAND SYSTEM (non-negotiable)

- **Colors:** deep green `#0D2B24` (primary background), amber `#C98A2B` (accent ONLY — CTAs, highlights, the "IR"), off-white `#FAFAF7`.
- **Typography:** Anton (Google Fonts) for uppercase display headings; Inter or system sans for body. Max 2 font files.
- **Tone (campaign rules — binding):** fier, calme, ironie tranquille. Jamais quêteux, jamais corporatif, jamais France-français. Every execution carries the remplaçant/irremplaçable paradox. Real names, real faces, real stories — **zéro stock photo, zéro illustration cartoon, zéro emoji.** B&W portrait placeholders until real photos exist.
- Big type, generous whitespace, premium editorial (Nike/Apple campaign, not SaaS template).

## PAGE STRUCTURE & COPY (in this order)

**1. HERO** — the existing animation: "REMPLAÇABLE" in grey → amber strikethrough → "IRREMPLAÇABLE." with "IR" in amber. Sub-line: *« C'est drôle, pour un remplaçant. »* Support line: « C-Direct. La plateforme des pharmaciens du Québec. Tes quarts. Tes conditions. Ton nom. » CTAs: **[ Je suis pharmacien ]** **[ Je suis une pharmacie ]**. Add a `prefers-reduced-motion` fallback showing the final static state.

**2. SECTION PHARMACIENS — « Ici, t'es pas un numéro »** (copy verbatim from campaign file):
« Les agences te placent. Nous, on te reconnaît. »
- **Tu choisis.** Tes quarts, tes régions, tes taux. Pas de répartiteur, pas de pression.
- **Tu es payé direct.** L'argent va de la pharmacie à toi. On prend notre part, jamais la tienne.
- **Tu as un nom.** Ton profil montre ton expérience, tes forces, ta réputation.
- **Tu restes libre.** Pas d'exclusivité, pas de pénalités, pas de contrat qui t'attache.
Bouton : **Créer mon profil — 5 minutes**

**3. LE PAIEMENT — differentiator #1.** Headline: **« La seule plateforme qui te paie. »**
- Pour les pharmaciens : la pharmacie est débitée 24 h avant le quart; tu es payé automatiquement à la confirmation. Traité par Paysafe — le même processeur que l'OPQ. Pas de facture à faire, pas de chèque à courir. Relevés de paiement et sommaire annuel générés automatiquement.
- Pour les pharmacies : « Le remplaçant est payé automatiquement. La paperasse aussi. » Confirmation et paiement automatisés — vous confirmez, c'est réglé.
- **Legal wording constraint (QCCA 587 / Martin):** the money goes **directly from the pharmacy to the pharmacist**; C-Direct charges **flat fees only** and **never holds or transits the funds**. Every sentence in this section must respect that framing. Never write anything implying C-Direct pays the locum from its own account.

**4. LE COMPARATIF** — comparison table. **Do NOT name any competitor.** Three columns:
- « Agences traditionnelles » — jusqu'à 20 $/h de frais
- « Plateformes d'affichage » — 39 $ à 395 $, paiement à organiser vous-mêmes, paperasse à votre charge
- « C-Direct » — 39 $/quart ou 179 $/mois illimité, paiement automatique inclus

**5. SECTION PORTRAITS — « Ils sont irremplaçables »** — 3 B&W portrait placeholders with name + one-line story, format:
**Marie-Ève, Rimouski.** *« Une heure et demie de route un samedi matin. Sinon, le village passait la fin de semaine sans pharmacien. »*
(Placeholders clearly marked; real portraits coming.)

**6. SECTION ENGAGEMENT — « On se mouille »** (verbatim):
« Notre engagement public : C-Direct ne négociera jamais un taux à la baisse dans le dos d'un pharmacien. Pas de majoration cachée. Pas de gruge. Le taux affiché, c'est le taux payé. *C'est écrit ici. Tenez-nous responsables.* »

**7. LE FONDATEUR** — short first-person block: propriétaire de pharmacie pendant 24 ans, remplaçant aujourd'hui. A vu les frais partir de sa poche des deux côtés du comptoir — fait qu'il a bâti la plateforme qui les redonne aux pharmaciens. B&W portrait placeholder.

**8. POUR LES PHARMACIES** — dedicated strip: « Un professionnel, pas une facture d'agence. » Pharmaciens vérifiés, membres de l'OPQ, profil complet, réputation visible. Relation directe, pas de majoration d'agence. Favoris + réservation en un clic. **« 3 premiers quarts gratuits. »** Bouton : **Publier un quart**.
*(Optional sub-block — ASK ME before including: « Garantie C-Direct » — couverture garantie dans certaines régions. Do not build unless I confirm.)*

**9. FINAL CTA + FOOTER** — « **Irremplaçable.** — C-Direct » / « Fait au Québec, par un pharmacien qui a remarqué que quelque chose était brisé. » Signature: « C-Direct — Pharmaciens irremplaçables. » Contact, mentions légales.

## TECHNICAL REQUIREMENTS

- Single responsive page, mobile-first; verify at 375px and 1440px
- No frameworks, no heavy libraries; total page < 500KB excluding logo SVGs
- Semantic HTML; WCAG AA — amber on green fails for body text, so amber is reserved for large display text and buttons with off-white labels
- `lang="fr-CA"`; SEO title/meta/OG tags using the IRREMPLAÇABLE hero line; OG image generated from the hero end-state
- All existing Supabase auth entry points functional after every commit

## ACCEPTANCE CHECKLIST (definition of done)

- [ ] Section map approved by me before any code
- [ ] Each section approved before the next was built
- [ ] Campaign copy used verbatim — no rewrites of the French
- [ ] Payment section wording respects the QCCA 587 framing above
- [ ] No competitor named anywhere on the page
- [ ] Lighthouse mobile ≥ 90 performance / ≥ 95 accessibility
- [ ] 375px and 1440px screenshots shown to me
- [ ] Signup/login flows tested and intact
- [ ] One commit per approved section, clear messages

Start with the screenshot analysis and section map. Do not start coding until I approve it.
