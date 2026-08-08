/* =====================================================================
   sql/59 — Défauts pharmacie : "offrir l'hébergement" et "offrir d'abord
   à mes pharmaciens de confiance" par défaut sur chaque nouveau contrat.

   Contexte (demande de Robert, 2026-08-08) : les deux cases à cocher du
   formulaire de publication (espace-pharmacie.html) sont désactivées tant
   que (a) aucune adresse d'hébergement n'est renseignée au profil, ou (b)
   aucun favori n'existe — comportement voulu, pas un bug (voir le code
   existant). Ce qui manquait : un réglage "par défaut" dans Paramètres
   pour ne pas avoir à recocher à chaque publication, ET un moyen d'ajouter
   un favori AVANT d'avoir reçu une candidature.

   Choix délibéré sur ce dernier point : PAS de recherche ouverte de
   pharmaciens par nom/courriel — la RLS de public.profiles (sql/01) ne
   permet déjà à une pharmacie de lire AUCUN profil pharmacien autre que
   le sien (`id = auth.uid() or est_admin()`), et chaque révélation de nom
   existante (get_candidats, etc.) est volontairement bornée à une relation
   déjà engagée (candidature soumise). lister_pharmaciens_deja_postules()
   respecte cette même règle : elle ne renvoie que des pharmaciens ayant
   déjà soumis une candidature à l'un des contrats de LA pharmacie
   appelante — aucune nouvelle fuite d'identité.
   ===================================================================== */

alter table public.profiles
  add column if not exists hebergement_offert_par_defaut boolean not null default false;
alter table public.profiles
  add column if not exists acces_prioritaire_par_defaut boolean not null default false;

-- Liste (dédupliquée) des pharmaciens ayant déjà soumis une candidature à
-- l'un des contrats de la pharmacie appelante, avec leur note et si déjà
-- favori — sert le sélecteur "Pharmaciens de confiance" de profil.html.
-- Même patron de sécurité que get_candidats (sql/37) : security definer,
-- borné à auth.uid() = pharmacie_id, jamais un accès plus large.
create or replace function public.lister_pharmaciens_deja_postules()
returns table (
  pharmacien_id uuid, nom text, prenom text, ville_base text,
  note_moyenne numeric, note_nombre bigint, deja_favori boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select distinct p.id, p.nom, p.prenom, p.ville_base,
           (select g.moyenne from public.get_note_profil(p.id) g),
           (select g.nombre  from public.get_note_profil(p.id) g),
           exists(select 1 from public.favoris_pharmaciens f
                   where f.pharmacie_id = auth.uid() and f.pharmacien_id = p.id)
      from public.candidatures c
      join public.contrats  k on k.id = c.contrat_id
      join public.profiles  p on p.id = c.pharmacien_id
     where k.pharmacie_id = auth.uid()
       and not public.est_exclu(c.pharmacien_id, k.pharmacie_id)
     order by 3, 2; -- prenom, nom
end;
$$;
revoke all on function public.lister_pharmaciens_deja_postules() from public, anon;
grant execute on function public.lister_pharmaciens_deja_postules() to authenticated;
