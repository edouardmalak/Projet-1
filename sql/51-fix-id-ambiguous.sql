-- =====================================================================
-- C-DIRECT · SQL 51 — HOTFIX : "column reference "id" is ambiguous"
-- À exécuter dans Supabase → SQL Editor, APRÈS 50-atp-profession.sql.
--
-- Bug introduit par sql/50 : get_contrats_ouverts() et get_contrat_fiche()
-- sont des fonctions plpgsql déclarées `returns table(id uuid, ...)`. Cela
-- crée implicitement un paramètre de sortie (OUT) nommé `id`, visible comme
-- identifiant nu PARTOUT dans le corps de la fonction — y compris dans les
-- sous-requêtes imbriquées. La sous-requête ajoutée par sql/50 :
--     (select profession from public.profiles where id = auth.uid())
-- référence `id` sans le qualifier : Postgres ne peut plus décider si `id`
-- désigne le paramètre de sortie de la fonction ou public.profiles.id, et
-- lève "column reference "id" is ambiguous". Résultat en production :
-- contrats.html et la fiche contrat affichaient une erreur et zéro contrat
-- pour tout compte pharmacien/ATP (repéré par Robert le 2026-08-06, connecté
-- comme pharmacien réel pour la première fois depuis le déploiement de
-- sql/50 — l'admin, seul compte testé avant mise en ligne, n'est jamais
-- passé par cette branche du filtre).
--
-- Correctif : aliaser et qualifier explicitement la table (pr.id, pr.profession)
-- au lieu d'identifiants nus. Corps des fonctions identique à sql/50 sinon.
-- Idempotent (drop-then-create, comme sql/50).
-- =====================================================================

drop function if exists public.get_contrats_ouverts();
create or replace function public.get_contrats_ouverts()
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  statut text, ville text, logiciel text, code_postal text, deja_postule boolean,
  profession_recherchee text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (public.mon_role() in ('pharmacien','admin')) then
    raise exception 'Accès refusé';
  end if;
  return query
    select k.id, k.numero_reference, k.date_contrat,
           k.heure_debut, k.heure_fin, k.tarif_horaire,
           k.statut, p.ville, p.logiciel, p.code_postal,
           exists (select 1 from public.candidatures c
                    where c.contrat_id = k.id and c.pharmacien_id = auth.uid()),
           k.profession_recherchee
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.statut = 'ouvert'
       and (
         public.est_admin()
         or (
           not public.est_exclu(auth.uid(), k.pharmacie_id)
           and k.profession_recherchee = coalesce(
             (select pr.profession from public.profiles pr where pr.id = auth.uid()), 'pharmacien')
         )
       )
     order by k.created_at desc;
end;
$$;
revoke all on function public.get_contrats_ouverts() from public, anon;
grant execute on function public.get_contrats_ouverts() to authenticated;

drop function if exists public.get_contrat_fiche(text);
create or replace function public.get_contrat_fiche(p_ref text)
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  rx_jour_semaine int, rx_jour_weekend int,
  seul_pharmacien boolean, atp_presente boolean, services text[],
  notes text, statut text, created_at timestamptz,
  ville text, logiciel text, code_postal text,
  ma_candidature_statut text, est_ma_pharmacie boolean,
  profession_recherchee text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select k.id, k.numero_reference, k.date_contrat,
           k.heure_debut, k.heure_fin, k.tarif_horaire,
           k.rx_jour_semaine, k.rx_jour_weekend,
           k.seul_pharmacien, k.atp_presente, k.services,
           k.notes, k.statut, k.created_at,
           p.ville, p.logiciel, p.code_postal,
           (select c.statut from public.candidatures c
             where c.contrat_id = k.id and c.pharmacien_id = auth.uid()),
           (k.pharmacie_id = auth.uid()),
           k.profession_recherchee
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.numero_reference = upper(trim(p_ref))
       and (
         public.est_admin()
         or k.pharmacie_id = auth.uid()
         or (public.mon_role() = 'pharmacien'
             and (
               (k.statut = 'ouvert'
                and k.profession_recherchee = coalesce(
                  (select pr.profession from public.profiles pr where pr.id = auth.uid()), 'pharmacien'))
               or public.a_postule(k.id)
             )
             and not public.est_exclu(auth.uid(), k.pharmacie_id))
       );
end;
$$;
revoke all on function public.get_contrat_fiche(text) from public, anon;
grant execute on function public.get_contrat_fiche(text) to authenticated;

-- Vérification rapide après exécution (attendu : contrats.html se recharge
-- sans "Erreur : column reference "id" is ambiguous" et affiche la liste).
