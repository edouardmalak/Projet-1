-- =====================================================================
-- C-DIRECT · SQL 79 — DEMANDES DE MODIFICATION / ANNULATION DE CONTRAT
-- À exécuter APRÈS 78-fix-order-by-ambigu-relations.sql (SQL Editor).
--
-- Contrat CONFIRMÉ (statut 'attribue') : chaque partie peut désormais
-- faire une DEMANDE (modification des termes, ou annulation) que
-- l'autre partie accepte ou refuse. Modèle « superposé » comme le
-- litige (sql/26) : le statut brut du contrat n'est PAS modifié tant
-- que la demande n'est pas acceptée.
--
--   · Demande de modification acceptée → les termes du contrat ET de
--     la candidature acceptée sont mis à jour (date, heures, tarif,
--     per diem, hébergement). Jalon 'modifie' journalisé.
--   · Demande d'annulation acceptée → annulation À L'AMIABLE, AUCUNE
--     pénalité, aucune facture :
--       - demande émise par la pharmacie  → contrat 'annule'
--       - demande émise par le pharmacien → candidature 'refuse',
--         contrat remis 'ouvert' (comme annuler_contrat_pharmacien)
--   · L'annulation immédiate (sql/09, avec pénalités) reste disponible.
--
-- Une seule demande 'en_attente' par contrat. Écritures uniquement via
-- les RPC security definer ci-dessous (aucune policy insert/update).
-- =====================================================================

create table if not exists public.demandes_contrat (
  id uuid primary key default gen_random_uuid(),
  contrat_id uuid not null references public.contrats(id) on delete cascade,
  type_demande text not null check (type_demande in ('modification','annulation')),
  par text not null check (par in ('pharmacie','pharmacien')),
  auteur_id uuid not null references public.profiles(id) on delete cascade,
  statut text not null check (statut in ('en_attente','acceptee','refusee','retiree')) default 'en_attente',
  champs jsonb,
  motif text not null,
  motif_reponse text,
  cree_le timestamptz not null default now(),
  traite_le timestamptz
);

create index if not exists demandes_contrat_contrat_idx
  on public.demandes_contrat(contrat_id);

-- une seule demande en attente à la fois par contrat
create unique index if not exists demandes_contrat_une_en_attente
  on public.demandes_contrat(contrat_id) where statut = 'en_attente';

alter table public.demandes_contrat enable row level security;

drop policy if exists "pharmacie lit les demandes de ses contrats" on public.demandes_contrat;
create policy "pharmacie lit les demandes de ses contrats" on public.demandes_contrat
  for select using (
    auth.uid() = (select c.pharmacie_id from public.contrats c where c.id = contrat_id)
  );

drop policy if exists "pharmacien retenu lit les demandes du contrat" on public.demandes_contrat;
create policy "pharmacien retenu lit les demandes du contrat" on public.demandes_contrat
  for select using (
    exists (select 1 from public.candidatures ca
             where ca.contrat_id = demandes_contrat.contrat_id
               and ca.pharmacien_id = auth.uid()
               and ca.statut = 'accepte')
  );

-- ---------------------------------------------------------------------
-- Aide interne : courriel best-effort (ne bloque jamais la transaction)
-- ---------------------------------------------------------------------
create or replace function public._demande_contrat_courriel(
  p_dest uuid, p_sujet text, p_html text
) returns void
language plpgsql security definer set search_path = public as $$
begin
  begin
    perform public.envoyer_email(
      (select courriel from public.profiles where id = p_dest),
      p_sujet, p_html);
  exception when others then null;  -- courriel = bonus, jamais bloquant
  end;
end;
$$;
revoke all on function public._demande_contrat_courriel(uuid, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- RPC · creer_demande_contrat — une partie d'un contrat 'attribue'
-- dépose une demande. p_champs (modification seulement) : clés admises
-- date_contrat, heure_debut, heure_fin, tarif_horaire, per_diem,
-- hebergement. Renvoie l'id de la demande.
-- ---------------------------------------------------------------------
create or replace function public.creer_demande_contrat(
  p_contrat uuid, p_type text, p_motif text, p_champs jsonb default null
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  k public.contrats%rowtype;
  c public.candidatures%rowtype;
  v_par text;
  v_autre uuid;
  v_champs jsonb := '{}'::jsonb;
  v_date date; v_hd time; v_hf time; v_tarif numeric;
  v_pd boolean; v_heb boolean;
  v_plancher numeric;
  v_id uuid;
  v_nom text;
begin
  if p_type not in ('modification','annulation') then
    raise exception 'Type de demande invalide.';
  end if;
  if p_motif is null or btrim(p_motif) = '' then
    raise exception 'Le motif est obligatoire.';
  end if;

  select * into k from public.contrats where id = p_contrat for update;
  if not found then raise exception 'Contrat introuvable.'; end if;
  if k.statut <> 'attribue' then
    raise exception 'Une demande n''est possible que sur un contrat confirmé (statut : %).', k.statut;
  end if;

  select * into c from public.candidatures
   where contrat_id = p_contrat and statut = 'accepte'
   order by updated_at desc limit 1;
  if not found then raise exception 'Candidature acceptée introuvable.'; end if;

  if k.pharmacie_id = auth.uid() then
    v_par := 'pharmacie'; v_autre := c.pharmacien_id;
  elsif c.pharmacien_id = auth.uid() then
    v_par := 'pharmacien'; v_autre := k.pharmacie_id;
  else
    raise exception 'Vous n''êtes pas partie à ce contrat.';
  end if;

  if exists (select 1 from public.demandes_contrat
              where contrat_id = p_contrat and statut = 'en_attente') then
    raise exception 'Une demande est déjà en attente pour ce contrat.';
  end if;

  if p_type = 'modification' then
    -- extraction + validation des seules clés admises
    v_date  := nullif(p_champs->>'date_contrat','')::date;
    v_hd    := nullif(p_champs->>'heure_debut','')::time;
    v_hf    := nullif(p_champs->>'heure_fin','')::time;
    v_tarif := nullif(p_champs->>'tarif_horaire','')::numeric;
    v_pd    := case when p_champs ? 'per_diem'    then (p_champs->>'per_diem')::boolean    end;
    v_heb   := case when p_champs ? 'hebergement' then (p_champs->>'hebergement')::boolean end;

    if v_date is null and v_hd is null and v_hf is null and v_tarif is null
       and v_pd is null and v_heb is null then
      raise exception 'Précisez au moins un élément à modifier.';
    end if;
    if v_date is not null and v_date < (now() at time zone 'America/Toronto')::date then
      raise exception 'La nouvelle date ne peut pas être dans le passé.';
    end if;
    if v_tarif is not null then
      select tarif_horaire_minimum into v_plancher from public.regles_reseau where id = 1;
      if v_plancher is not null and v_tarif < v_plancher then
        raise exception 'Tarif horaire sous le plancher du réseau (% $/h).', v_plancher;
      end if;
    end if;

    if v_date  is not null then v_champs := v_champs || jsonb_build_object('date_contrat',  v_date);  end if;
    if v_hd    is not null then v_champs := v_champs || jsonb_build_object('heure_debut',   v_hd);    end if;
    if v_hf    is not null then v_champs := v_champs || jsonb_build_object('heure_fin',     v_hf);    end if;
    if v_tarif is not null then v_champs := v_champs || jsonb_build_object('tarif_horaire', v_tarif); end if;
    if v_pd    is not null then v_champs := v_champs || jsonb_build_object('per_diem',      v_pd);    end if;
    if v_heb   is not null then v_champs := v_champs || jsonb_build_object('hebergement',   v_heb);   end if;
  else
    v_champs := null;
  end if;

  insert into public.demandes_contrat (contrat_id, type_demande, par, auteur_id, champs, motif)
  values (p_contrat, p_type, v_par, auth.uid(), v_champs, btrim(p_motif))
  returning id into v_id;

  select coalesce(nullif(btrim(coalesce(prenom,'') || ' ' || coalesce(nom,'')), ''), nom_pharmacie, courriel)
    into v_nom from public.profiles where id = auth.uid();

  perform public._demande_contrat_courriel(
    v_autre,
    (case when p_type = 'annulation' then 'Demande d''annulation — ' else 'Demande de modification — ' end) || k.numero_reference,
    '<p>Bonjour,</p>'
    || '<p>' || coalesce(v_nom, 'L''autre partie') || ' a déposé une <b>demande '
    || (case when p_type = 'annulation' then 'd''annulation' else 'de modification' end)
    || '</b> pour le contrat <b>' || k.numero_reference || '</b>.</p>'
    || '<p>Motif : ' || btrim(p_motif) || '</p>'
    || '<p>Connectez-vous à C-Direct et ouvrez la fiche du contrat pour accepter ou refuser : '
    || 'https://c-direct.ca/c/' || k.numero_reference || '</p>'
    || '<p>— C-Direct</p>');

  return v_id;
end;
$$;
revoke all on function public.creer_demande_contrat(uuid, text, text, jsonb) from public, anon;
grant execute on function public.creer_demande_contrat(uuid, text, text, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- RPC · repondre_demande_contrat — l'AUTRE partie accepte ou refuse.
-- Acceptée + modification → termes mis à jour (contrat + candidature).
-- Acceptée + annulation   → annulation à l'amiable, 0 pénalité.
-- ---------------------------------------------------------------------
create or replace function public.repondre_demande_contrat(
  p_demande uuid, p_accepter boolean, p_motif text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  d public.demandes_contrat%rowtype;
  k public.contrats%rowtype;
  c public.candidatures%rowtype;
  v_date date; v_hd time; v_hf time; v_tarif numeric;
  v_pd boolean; v_heb boolean;
  v_nom text;
begin
  select * into d from public.demandes_contrat where id = p_demande for update;
  if not found then raise exception 'Demande introuvable.'; end if;
  if d.statut <> 'en_attente' then
    raise exception 'Cette demande a déjà été traitée (statut : %).', d.statut;
  end if;

  select * into k from public.contrats where id = d.contrat_id for update;
  if k.statut <> 'attribue' then
    raise exception 'Le contrat n''est plus confirmé (statut : %).', k.statut;
  end if;

  select * into c from public.candidatures
   where contrat_id = d.contrat_id and statut = 'accepte'
   order by updated_at desc limit 1;
  if not found then raise exception 'Candidature acceptée introuvable.'; end if;

  -- seule l'AUTRE partie (ou l'admin) peut répondre
  if not public.est_admin() then
    if d.par = 'pharmacie' and c.pharmacien_id <> auth.uid() then
      raise exception 'Seul le pharmacien retenu peut répondre à cette demande.';
    end if;
    if d.par = 'pharmacien' and k.pharmacie_id <> auth.uid() then
      raise exception 'Seule la pharmacie peut répondre à cette demande.';
    end if;
  end if;

  if not p_accepter then
    update public.demandes_contrat
       set statut = 'refusee', motif_reponse = nullif(btrim(coalesce(p_motif,'')),''), traite_le = now()
     where id = d.id;
  else
    if d.type_demande = 'modification' then
      v_date  := nullif(d.champs->>'date_contrat','')::date;
      v_hd    := nullif(d.champs->>'heure_debut','')::time;
      v_hf    := nullif(d.champs->>'heure_fin','')::time;
      v_tarif := nullif(d.champs->>'tarif_horaire','')::numeric;
      v_pd    := case when d.champs ? 'per_diem'    then (d.champs->>'per_diem')::boolean    end;
      v_heb   := case when d.champs ? 'hebergement' then (d.champs->>'hebergement')::boolean end;

      update public.contrats
         set date_contrat  = coalesce(v_date,  date_contrat),
             heure_debut   = coalesce(v_hd,    heure_debut),
             heure_fin     = coalesce(v_hf,    heure_fin),
             tarif_horaire = coalesce(v_tarif, tarif_horaire),
             per_diem      = coalesce(v_pd,    per_diem),
             hebergement   = coalesce(v_heb,   hebergement)
       where id = k.id;

      -- la candidature acceptée porte les termes convenus (coalesce partout
      -- dans le code existant) : on l'aligne sur les nouveaux termes
      update public.candidatures
         set tarif_propose        = coalesce(v_tarif, tarif_propose),
             heure_debut_proposee = case when v_hd is not null then v_hd else heure_debut_proposee end,
             heure_fin_proposee   = case when v_hf is not null then v_hf else heure_fin_proposee end,
             message = public.ajouter_jalon(message, jsonb_build_object(
               'etape','modifie','par',d.par,
               'tarif', coalesce(v_tarif, tarif_propose, k.tarif_horaire),
               'hd', coalesce(v_hd, heure_debut_proposee, k.heure_debut),
               'hf', coalesce(v_hf, heure_fin_proposee, k.heure_fin),
               'auto', true))
       where id = c.id;

      update public.demandes_contrat set statut = 'acceptee', traite_le = now() where id = d.id;

    else  -- annulation à l'amiable, aucune pénalité, aucune facture
      if d.par = 'pharmacie' then
        update public.contrats set statut = 'annule' where id = k.id;
        update public.candidatures
           set message = public.ajouter_jalon(message, jsonb_build_object(
             'etape','annule','par','pharmacie','penalite_pct',0,'via_demande',true,'auto',true))
         where id = c.id;
      else
        update public.candidatures
           set statut = 'refuse',
               message = public.ajouter_jalon(message, jsonb_build_object(
                 'etape','annule','par','pharmacien','via_demande',true,'auto',true))
         where id = c.id;
        update public.contrats
           set statut = 'ouvert', per_diem = false, hebergement = false
         where id = k.id;
      end if;
      update public.demandes_contrat set statut = 'acceptee', traite_le = now() where id = d.id;
    end if;
  end if;

  select coalesce(nullif(btrim(coalesce(prenom,'') || ' ' || coalesce(nom,'')), ''), nom_pharmacie, courriel)
    into v_nom from public.profiles where id = auth.uid();

  perform public._demande_contrat_courriel(
    d.auteur_id,
    'Votre demande ' || (case when d.type_demande='annulation' then 'd''annulation' else 'de modification' end)
      || ' — ' || k.numero_reference || (case when p_accepter then ' : ACCEPTÉE' else ' : refusée' end),
    '<p>Bonjour,</p>'
    || '<p>' || coalesce(v_nom, 'L''autre partie') || ' a <b>'
    || (case when p_accepter then 'accepté' else 'refusé' end)
    || '</b> votre demande '
    || (case when d.type_demande='annulation' then 'd''annulation' else 'de modification' end)
    || ' pour le contrat <b>' || k.numero_reference || '</b>.</p>'
    || (case when p_motif is not null and btrim(p_motif) <> ''
             then '<p>Commentaire : ' || btrim(p_motif) || '</p>' else '' end)
    || (case when p_accepter and d.type_demande = 'annulation' and d.par = 'pharmacien'
             then '<p>Le contrat est remis en ligne pour les autres pharmaciens.</p>'
             when p_accepter and d.type_demande = 'annulation'
             then '<p>Le contrat est annulé à l''amiable — aucune pénalité.</p>'
             when p_accepter
             then '<p>Les termes du contrat ont été mis à jour.</p>'
             else '' end)
    || '<p>Fiche : https://c-direct.ca/c/' || k.numero_reference || '</p>'
    || '<p>— C-Direct</p>');

  return jsonb_build_object('accepte', p_accepter, 'type', d.type_demande, 'par', d.par);
end;
$$;
revoke all on function public.repondre_demande_contrat(uuid, boolean, text) from public, anon;
grant execute on function public.repondre_demande_contrat(uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------------------
-- RPC · retirer_demande_contrat — l'auteur retire sa demande en attente.
-- ---------------------------------------------------------------------
create or replace function public.retirer_demande_contrat(p_demande uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  d public.demandes_contrat%rowtype;
  k public.contrats%rowtype;
  c public.candidatures%rowtype;
  v_autre uuid;
begin
  select * into d from public.demandes_contrat where id = p_demande for update;
  if not found then raise exception 'Demande introuvable.'; end if;
  if d.statut <> 'en_attente' then
    raise exception 'Cette demande a déjà été traitée (statut : %).', d.statut;
  end if;
  if d.auteur_id <> auth.uid() and not public.est_admin() then
    raise exception 'Seul l''auteur de la demande peut la retirer.';
  end if;

  update public.demandes_contrat set statut = 'retiree', traite_le = now() where id = d.id;

  select * into k from public.contrats where id = d.contrat_id;
  select * into c from public.candidatures
   where contrat_id = d.contrat_id and statut = 'accepte'
   order by updated_at desc limit 1;
  v_autre := case when d.par = 'pharmacie' then c.pharmacien_id else k.pharmacie_id end;

  if v_autre is not null then
    perform public._demande_contrat_courriel(
      v_autre,
      'Demande retirée — ' || k.numero_reference,
      '<p>Bonjour,</p><p>La demande '
      || (case when d.type_demande='annulation' then 'd''annulation' else 'de modification' end)
      || ' pour le contrat <b>' || k.numero_reference || '</b> a été retirée par son auteur. '
      || 'Le contrat reste inchangé.</p><p>— C-Direct</p>');
  end if;
end;
$$;
revoke all on function public.retirer_demande_contrat(uuid) from public, anon;
grant execute on function public.retirer_demande_contrat(uuid) to authenticated;
